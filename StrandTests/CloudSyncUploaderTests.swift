// Tests the CLOUD_SYNC-gated cloud sync uploader (Phase 3.5: zero-touch); compiled only when the flag
// is set (StrandTests shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if CLOUD_SYNC
import XCTest
import WhoopStore
@testable import Strand

/// A spy conforming to `CloudIngesting` that records how many times `ingest` was invoked — used by
/// the empty-store guard test to assert the network is never reached, without needing a real
/// `CloudSyncClient`/`OuraURLProtocolStub` at all (mirrors `StubCloudEditFetcher` in
/// `CloudSyncCoordinatorTests.swift`).
private final class SpyCloudIngester: CloudIngesting {
    private(set) var ingestCallCount = 0
    func ingest(fileURL: URL) async throws -> (bytes: Int, latestDay: String?) {
        ingestCallCount += 1
        return (0, nil)
    }
}

final class CloudSyncUploaderTests: XCTestCase {
    override func setUp() { super.setUp(); OuraURLProtocolStub.reset() }

    private let baseURL = URL(string: "https://cloud.example.com")!

    /// `retry: .immediate` keeps `CloudSyncRetryPolicy`'s attempt COUNTS while removing the waits, so a
    /// test that provokes a retryable failure doesn't spend real seconds in backoff. Tests that care
    /// about the retry behaviour itself live in `CloudSyncRetryTests`/`CloudSyncClientTests`.
    private func makeClient() -> CloudSyncClient {
        CloudSyncClient(baseURL: baseURL, token: "tok-upload", session: OuraURLProtocolStub.session(),
                        retry: .immediate,
                        bulkRetry: CloudSyncRetryPolicy(maxAttempts: 2, baseDelayS: 0, multiplier: 1,
                                                         maxDelayS: 0, jitterFraction: 0))
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

    /// An in-memory store seeded with one `dailyMetric` row, so it clears the empty-store guard added
    /// to `CloudSyncUploader.upload` (see the "Empty store guard" section below, which tests that guard
    /// directly against an UNSEEDED store) and these pre-existing tests keep exercising what they
    /// actually test — network/export behavior beyond that guard — instead of being short-circuited by it.
    private func nonEmptyStore() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDailyMetrics([
            DailyMetric(day: "2026-07-11", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                        strain: nil, exerciseCount: nil),
        ], deviceId: "devA")
        return store
    }

    // MARK: - Happy path

    func testUploadHappyPathSendsBearerAndOctetStreamAndParsesResponse() async throws {
        OuraURLProtocolStub.queue = [.init(status: 200,
            body: #"{"ok":true,"bytes":12345,"latestDay":"2026-07-11"}"#.data(using: .utf8)!)]
        let store = try await nonEmptyStore()
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

    /// A 401 is TERMINAL, so it must surface as `unauthorized` and must NOT be retried — the same
    /// rejected token would be sent again for nothing. The request count is the assertion that matters.
    func testUploadNon2xxThrowsTypedErrorAndDoesNotRetryATerminalOne() async throws {
        OuraURLProtocolStub.queue = [.init(status: 401, body: "nope".data(using: .utf8)!)]
        let store = try await nonEmptyStore()
        let client = makeClient()

        do {
            _ = try await CloudSyncUploader.upload(store: store, client: client, exporter: fakeExporter())
            XCTFail("expected unauthorized to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, CloudSyncError.unauthorized(status: 401, detail: "nope"))
        }
        XCTAssertEqual(OuraURLProtocolStub.requestedURLs.count, 1)
    }

    /// The 507 the server answers when its volume is full. This is the case the flat `badResponse`
    /// collapse got most wrong: the backup was VALID and the right response is to keep it and try again,
    /// which is the opposite of what a 4xx means. Pinned as its own typed case, and as retryable.
    func testUpload507SurfacesAsOutOfSpaceAndIsRetried() async throws {
        let body = #"{"error":"insufficient_space","detail":"need 1.2 GB, only 300 MB free"}"#
        OuraURLProtocolStub.queue = [.init(status: 507, body: Data(body.utf8)),
                                     .init(status: 507, body: Data(body.utf8))]
        let store = try await nonEmptyStore()
        let client = makeClient()

        do {
            _ = try await CloudSyncUploader.upload(store: store, client: client, exporter: fakeExporter())
            XCTFail("expected serverOutOfSpace to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncError,
                           .serverOutOfSpace(code: "insufficient_space",
                                             detail: "need 1.2 GB, only 300 MB free"))
        }
        // bulkUpload's budget: the first attempt plus exactly one retry — never more, because this body
        // is the whole database.
        XCTAssertEqual(OuraURLProtocolStub.requestedURLs.count, 2)
    }

    /// `400 corrupt_sqlite` means "these bytes are unreadable, don't send them again". Resending a
    /// 100-300MB body that the server already told us it cannot parse is the one thing that must not
    /// happen, so this pins exactly one request.
    func testUploadCorruptSqliteIsTerminalAndNeverResendsTheBody() async throws {
        OuraURLProtocolStub.queue = [
            .init(status: 400, body: Data(#"{"error":"corrupt_sqlite"}"#.utf8)),
            .init(status: 200, body: Data(#"{"ok":true,"bytes":10,"latestDay":"2026-07-26"}"#.utf8)),
        ]
        let store = try await nonEmptyStore()
        let client = makeClient()

        do {
            _ = try await CloudSyncUploader.upload(store: store, client: client, exporter: fakeExporter())
            XCTFail("expected rejected to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncError,
                           .rejected(status: 400, code: "corrupt_sqlite", detail: ""))
        }
        XCTAssertEqual(OuraURLProtocolStub.requestedURLs.count, 1)
    }

    /// The payoff of retrying at all: a server that faults once and recovers costs the user nothing,
    /// where before it cost a whole sync — and the next attempt was the next launch, not seconds later.
    func testUploadRetriesAFiveHundredAndSucceedsOnTheSecondAttempt() async throws {
        OuraURLProtocolStub.queue = [
            .init(status: 500, body: Data(#"{"error":"ingest_failed"}"#.utf8)),
            .init(status: 200, body: Data(#"{"ok":true,"bytes":4242,"latestDay":"2026-07-26"}"#.utf8)),
        ]
        let store = try await nonEmptyStore()
        let client = makeClient()

        let result = try await CloudSyncUploader.upload(store: store, client: client,
                                                          exporter: fakeExporter())

        XCTAssertEqual(result.bytes, 4242)
        XCTAssertEqual(OuraURLProtocolStub.requestedURLs.count, 2)
    }

    func testUploadCleansUpTempFileEvenOnNetworkFailure() async throws {
        OuraURLProtocolStub.queue = [.init(status: 500, body: Data())]
        let store = try await nonEmptyStore()
        let client = makeClient()
        var capturedDest: URL?

        do {
            _ = try await CloudSyncUploader.upload(store: store, client: client,
                                                     exporter: fakeExporter(capture: { capturedDest = $0 }))
            XCTFail("expected a server error to be thrown")
        } catch {
            // expected — asserted below via the cleaned-up temp file
        }
        let dest = try XCTUnwrap(capturedDest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    // MARK: - Export failure (never reaches the network)

    func testUploadExportFailurePropagatesAsTypedErrorAndNeverPosts() async throws {
        let store = try await nonEmptyStore()
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

    // MARK: - Empty store guard (incident: a test-host's empty DB must never upload)

    /// Reproduces the production incident: an empty store (a fresh `WhoopStore.inMemory()` has zero
    /// `dailyMetric` rows, same shape as the macOS TEST HOST's never-populated database) must be
    /// refused BEFORE export, BEFORE the network — proven here with no real `CloudSyncClient` at all,
    /// just a `SpyCloudIngester` that would record a call if `upload` ever reached it.
    func testUploadRefusesEmptyStoreAndNeverExportsOrIngests() async throws {
        let store = try await WhoopStore.inMemory()
        let ingester = SpyCloudIngester()
        var exporterCallCount = 0
        let countingExporter: CloudSyncUploader.Exporter = { _, dest in
            exporterCallCount += 1
            return .exported(dest)
        }

        do {
            _ = try await CloudSyncUploader.upload(store: store, client: ingester, exporter: countingExporter)
            XCTFail("expected emptyStore to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncUploadError, CloudSyncUploadError.emptyStore)
        }
        XCTAssertEqual(exporterCallCount, 0, "the export step must never run for an empty store")
        XCTAssertEqual(ingester.ingestCallCount, 0, "ingest must never be called for an empty store")
    }

    /// The mirror-image case: once the store has at least one `dailyMetric` row, upload proceeds
    /// exactly as before (happy-path regression guard for the new empty-store check).
    func testUploadProceedsWhenStoreHasData() async throws {
        OuraURLProtocolStub.queue = [.init(status: 200,
            body: #"{"ok":true,"bytes":99,"latestDay":"2026-07-11"}"#.data(using: .utf8)!)]
        let store = try await nonEmptyStore()
        let client = makeClient()

        let result = try await CloudSyncUploader.upload(store: store, client: client, exporter: fakeExporter())
        XCTAssertEqual(result.bytes, 99)
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

    /// Incident guard: `autoSyncIfDue` must never fire inside an XCTest runner (the macOS TEST HOST
    /// runs `StrandTests` inside the full `Staging.app` via `TEST_HOST`, so `RootView`'s launch `.task`
    /// executes for real — see `CloudSyncModel.isRunningUnderXCTest`'s doc comment). This is
    /// inherently env-dependent and can only be pinned from the TRUE side: every `StrandTests` run,
    /// including this one, IS an XCTest run, so the helper reading true here is exactly what "detects
    /// the test runner" means. There is no way to assert the false branch from inside XCTest itself.
    func testIsRunningUnderXCTestIsTrueInThisTestRunner() {
        XCTAssertTrue(CloudSyncModel.isRunningUnderXCTest)
    }
}
#endif // CLOUD_SYNC
