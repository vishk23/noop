// Tests the CLOUD_SYNC-gated cloud sync uploader (Phase 3.5: zero-touch); compiled only when the flag
// is set (StrandTests shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if CLOUD_SYNC
import XCTest
import WhoopStore
@testable import Strand

final class CloudSyncUploaderTests: XCTestCase {
    override func setUp() { super.setUp(); OuraURLProtocolStub.reset() }

    private let baseURL = URL(string: "https://cloud.example.com")!

    private func makeClient() -> CloudSyncClient {
        CloudSyncClient(baseURL: baseURL, token: "tok-upload", session: OuraURLProtocolStub.session())
    }

    /// A fake exporter that writes canned bytes to `dest` without touching the real on-disk database or
    /// `StorePaths.defaultDatabasePath()` — see `CloudSyncUploader.Exporter`'s doc comment for why the
    /// real `DataBackup.writeBackup` can't run against a `WhoopStore.inMemory()` test store. `capture`
    /// lets a test observe exactly which temp URL the uploader chose (to assert on its location and
    /// that it's gone afterward).
    private func fakeExporter(bytes: Data = Data("fake-noopbak-bytes".utf8),
                               capture: @escaping (URL) -> Void = { _ in }) -> CloudSyncUploader.Exporter {
        { _, dest in
            capture(dest)
            try? bytes.write(to: dest)
            return .exported(dest)
        }
    }

    // MARK: - Happy path

    func testUploadHappyPathSendsBearerAndOctetStreamAndParsesResponse() async throws {
        OuraURLProtocolStub.queue = [.init(status: 200,
            body: #"{"ok":true,"bytes":12345,"latestDay":"2026-07-11"}"#.data(using: .utf8)!)]
        let store = try await WhoopStore.inMemory()
        let client = makeClient()
        var capturedDest: URL?

        let result = try await CloudSyncUploader.upload(store: store, client: client,
                                                          exporter: fakeExporter(capture: { capturedDest = $0 }))

        XCTAssertEqual(result.bytes, 12345)
        XCTAssertEqual(result.latestDay, "2026-07-11")

        let req = try XCTUnwrap(OuraURLProtocolStub.requestedRequests.last)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-upload")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertTrue(req.url?.absoluteString.contains("/ingest") ?? false)

        // The temp file lived in Caches (never Documents) and was cleaned up afterward.
        let dest = try XCTUnwrap(capturedDest)
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        XCTAssertTrue(dest.path.hasPrefix(cachesDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    // MARK: - Network failure

    func testUploadNon2xxThrowsBadResponse() async throws {
        OuraURLProtocolStub.queue = [.init(status: 401, body: "nope".data(using: .utf8)!)]
        let store = try await WhoopStore.inMemory()
        let client = makeClient()

        do {
            _ = try await CloudSyncUploader.upload(store: store, client: client, exporter: fakeExporter())
            XCTFail("expected badResponse to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, CloudSyncError.badResponse(401, "nope"))
        }
    }

    func testUploadCleansUpTempFileEvenOnNetworkFailure() async throws {
        OuraURLProtocolStub.queue = [.init(status: 500, body: Data())]
        let store = try await WhoopStore.inMemory()
        let client = makeClient()
        var capturedDest: URL?

        do {
            _ = try await CloudSyncUploader.upload(store: store, client: client,
                                                     exporter: fakeExporter(capture: { capturedDest = $0 }))
            XCTFail("expected badResponse to be thrown")
        } catch {
            // expected — asserted below via the cleaned-up temp file
        }
        let dest = try XCTUnwrap(capturedDest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    // MARK: - Export failure (never reaches the network)

    func testUploadExportFailurePropagatesAsTypedErrorAndNeverPosts() async throws {
        let store = try await WhoopStore.inMemory()
        let client = makeClient()
        let failingExporter: CloudSyncUploader.Exporter = { _, _ in .failure("disk full") }

        do {
            _ = try await CloudSyncUploader.upload(store: store, client: client, exporter: failingExporter)
            XCTFail("expected exportFailed to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncUploadError, CloudSyncUploadError.exportFailed("disk full"))
        }
        XCTAssertTrue(OuraURLProtocolStub.requestedRequests.isEmpty)   // never reached the network
    }
}

/// The 20h auto-sync gate, extracted as a pure `(lastRun, now) -> Bool` function so the threshold is
/// unit-testable without UserDefaults, a store, or a network. Mirrors `BackupSyncTests`' coverage of
/// `FolderBackup`'s pure day-gate helpers.
final class CloudSyncModelAutoSyncGateTests: XCTestCase {
    func testIsAutoSyncDueNeverRunBefore() {
        XCTAssertTrue(CloudSyncModel.isAutoSyncDue(lastRun: 0, now: 1_752_300_000))
    }

    func testIsAutoSyncDueRespectsTwentyHourThreshold() {
        let now: TimeInterval = 1_752_300_000
        XCTAssertFalse(CloudSyncModel.isAutoSyncDue(lastRun: now - 19 * 3600, now: now))  // too soon
        XCTAssertTrue(CloudSyncModel.isAutoSyncDue(lastRun: now - 20 * 3600, now: now))   // exactly due (>=)
        XCTAssertTrue(CloudSyncModel.isAutoSyncDue(lastRun: now - 21 * 3600, now: now))   // overdue
    }
}
#endif // CLOUD_SYNC
