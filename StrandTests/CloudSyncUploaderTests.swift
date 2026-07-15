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

    func testUploadNon2xxThrowsBadResponse() async throws {
        OuraURLProtocolStub.queue = [.init(status: 401, body: "nope".data(using: .utf8)!)]
        let store = try await nonEmptyStore()
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
        let store = try await nonEmptyStore()
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

/// The lastStatus/lastAutoSync/lastUploadToken contract as honoured by a background upload that
/// finished with NO in-process awaiter — the app was suspended or killed mid-transfer and iOS carried
/// the upload to completion on its own (`CloudSyncBackgroundSession`'s detached branch).
///
/// This is the half of the fix that is decidable without a device: `recordDetachedUploadCompletion` is
/// a pure UserDefaults transform, and it is the ONLY other writer of keys whose contract `performSync`
/// has always owned. The transfer itself (a real background `URLSession`) is iOS-owned and can only be
/// proven on hardware — but the rule it must obey is pinned right here.
///
/// The original bug's signature was `lastStatus` FROZEN while syncs silently died, so the load-bearing
/// assertion in every case below is simply: something truthful got written.
final class CloudSyncDetachedUploadContractTests: XCTestCase {
    private let statusKey = "cloudsync.lastStatus"
    private let autoSyncKey = "cloudsync.lastAutoSync"
    private let uploadTokenKey = "cloudsync.lastUploadToken"
    private let inFlightKey = "cloudsync.inFlightUpload"

    override func setUp() {
        super.setUp()
        for k in [statusKey, autoSyncKey, uploadTokenKey, inFlightKey] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDown() {
        for k in [statusKey, autoSyncKey, uploadTokenKey, inFlightKey] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        super.tearDown()
    }

    // MARK: - Success stamps everything

    func testDetachedSuccessWritesStatusStampsAutoSyncAndSavesUploadToken() {
        CloudSyncModel.recordDetachedUploadCompletion(
            statusPrefix: "Applied 0 · skipped 0",
            outcome: .success(bytes: 85_458_944),
            contentToken: "tok-content-1")

        let status = try! XCTUnwrap(UserDefaults.standard.string(forKey: statusKey))
        // The prefix survives, and the size is formatted exactly as performSync formats it.
        XCTAssertTrue(status.hasPrefix("Applied 0 · skipped 0 · Uploaded 81.5 MB"), status)
        XCTAssertNotEqual(UserDefaults.standard.double(forKey: autoSyncKey), 0, "success must stamp lastAutoSync")
        XCTAssertEqual(UserDefaults.standard.string(forKey: uploadTokenKey), "tok-content-1")
    }

    // MARK: - Failure writes a status but must NOT stamp success

    /// The contract's sharpest edge: a failed upload that stamped `lastAutoSync` would silence the
    /// >20h retry gate for another 20h — turning one failure into a day of silence.
    func testDetachedFailureWritesStatusButNeverStampsAutoSyncOrToken() {
        CloudSyncModel.recordDetachedUploadCompletion(
            statusPrefix: "Applied 2 · skipped 1",
            outcome: .failure("Network problem talking to the cloud sync server: lost connection"),
            contentToken: "tok-content-2")

        let status = try! XCTUnwrap(UserDefaults.standard.string(forKey: statusKey))
        XCTAssertTrue(status.contains("Applied 2 · skipped 1"), status)
        XCTAssertTrue(status.contains("lost connection"), status)
        XCTAssertEqual(UserDefaults.standard.double(forKey: autoSyncKey), 0,
                       "a failed upload must NOT stamp the success clock")
        XCTAssertNil(UserDefaults.standard.string(forKey: uploadTokenKey),
                     "a failed upload never shipped its content, so lastUploadToken must not advance")
    }

    /// A success whose content token couldn't be computed still stamps the clock — mirroring
    /// `performSync`'s `if let freshToken` (a token failure must not fail an otherwise-good sync).
    func testDetachedSuccessWithoutTokenStillStampsAutoSync() {
        CloudSyncModel.recordDetachedUploadCompletion(
            statusPrefix: "Applied 0 · skipped 0", outcome: .success(bytes: 1_048_576), contentToken: nil)

        XCTAssertNotEqual(UserDefaults.standard.double(forKey: autoSyncKey), 0)
        XCTAssertNil(UserDefaults.standard.string(forKey: uploadTokenKey))
    }

    /// A relaunch may find no in-flight record at all (force-quit, or an upgrade across the record
    /// format). The status line must still be written — degraded, never absent, because a frozen
    /// `lastStatus` is the exact symptom this whole change exists to eliminate.
    func testDetachedCompletionWithEmptyPrefixStillWritesALegibleStatus() {
        CloudSyncModel.recordDetachedUploadCompletion(
            statusPrefix: "", outcome: .success(bytes: 2_097_152), contentToken: nil)

        let status = try! XCTUnwrap(UserDefaults.standard.string(forKey: statusKey))
        XCTAssertTrue(status.hasPrefix("Uploaded 2.0 MB"), status)
        XCTAssertFalse(status.hasPrefix(" · "), "an empty prefix must not leave a dangling separator")
    }

    // MARK: - The in-flight record round-trips

    func testInFlightUploadRecordRoundTripsAndClears() {
        let record = CloudSyncInFlightUpload(filePath: "/tmp/cloudsync-upload-abc.noopbak",
                                             statusPrefix: "Applied 0 · skipped 0",
                                             contentToken: "tok-9",
                                             startedAt: 1_784_056_874)
        CloudSyncModel.saveInFlightUpload(record)
        XCTAssertEqual(CloudSyncModel.loadInFlightUpload(), record)

        // Surfaced to the user while iOS carries the upload (Data Sources → Cloud Sync).
        XCTAssertNotNil(CloudSyncModel.inFlightUploadDescription)

        CloudSyncModel.clearInFlightUpload()
        XCTAssertNil(CloudSyncModel.loadInFlightUpload())
        XCTAssertNil(CloudSyncModel.inFlightUploadDescription)
    }
}
#endif // CLOUD_SYNC
