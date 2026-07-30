// Tests the CLOUD_SYNC-gated cloud sync client + settings; compiled only when the flag is set
// (StrandTests shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if CLOUD_SYNC
import XCTest
@testable import Strand

final class CloudSyncClientTests: XCTestCase {
    override func setUp() { super.setUp(); OuraURLProtocolStub.reset() }

    private let baseURL = URL(string: "https://cloud.example.com")!

    /// `retry: .immediate` keeps `CloudSyncRetryPolicy.standard`'s attempt COUNTS and drops the waits,
    /// so a test can assert on how many requests a class of failure produced without spending the real
    /// backoff. The delays themselves are pinned separately, as pure arithmetic, in `CloudSyncRetryTests`.
    private func makeClient(retry: CloudSyncRetryPolicy = .immediate) -> CloudSyncClient {
        CloudSyncClient(baseURL: baseURL, token: "tok-1", session: OuraURLProtocolStub.session(),
                        retry: retry, bulkRetry: retry)
    }

    /// One journal row. `payloadJSON`'s embedded quotes are hand-escaped at the JSON level (`\"`)
    /// inside a raw string literal, so no Swift-level escaping is needed.
    private let editFixtureJSON =
        #"{"seq":3,"editId":"e-1","kind":"adjust_sleep_bounds","payloadJSON":"{\"deviceId\":\"d1\"}","beforeJSON":null,"rationale":"user requested","appliedAt":1752300000,"undoneBySeq":null,"ackedAt":null}"#

    // MARK: - fetchEdits

    func testFetchEditsDecodesEditsAndLatestSeq() async throws {
        let body = (#"{"edits":["# + editFixtureJSON + #"],"latestSeq":3}"#).data(using: .utf8)!
        OuraURLProtocolStub.queue = [.init(status: 200, body: body)]
        let client = makeClient()

        let result = try await client.fetchEdits(since: 0)

        XCTAssertEqual(result.latestSeq, 3)
        XCTAssertEqual(result.edits.count, 1)
        let edit = result.edits[0]
        XCTAssertEqual(edit.seq, 3)
        XCTAssertEqual(edit.editId, "e-1")
        XCTAssertEqual(edit.kind, "adjust_sleep_bounds")
        XCTAssertEqual(edit.payloadJSON, #"{"deviceId":"d1"}"#)
        XCTAssertNil(edit.beforeJSON)
        XCTAssertEqual(edit.rationale, "user requested")
        XCTAssertEqual(edit.appliedAt, 1_752_300_000)
        XCTAssertNil(edit.undoneBySeq)
        XCTAssertNil(edit.ackedAt)
    }

    func testFetchEditsSendsSinceInQueryString() async throws {
        OuraURLProtocolStub.queue = [.init(status: 200,
            body: #"{"edits":[],"latestSeq":0}"#.data(using: .utf8)!)]
        let client = makeClient()

        _ = try await client.fetchEdits(since: 42)

        let url = OuraURLProtocolStub.requestedURLs.last?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/edits"))
        XCTAssertTrue(url.contains("since=42"))
    }

    func testFetchEdits401ThrowsUnauthorized() async throws {
        OuraURLProtocolStub.queue = [.init(status: 401, body: "nope".data(using: .utf8)!)]
        let client = makeClient()

        do {
            _ = try await client.fetchEdits(since: 0)
            XCTFail("expected unauthorized to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, CloudSyncError.unauthorized(status: 401, detail: "nope"))
        }
    }

    func testFetchEditsMalformedJSONThrowsDecode() async throws {
        OuraURLProtocolStub.queue = [.init(status: 200, body: "not json".data(using: .utf8)!)]
        let client = makeClient()

        do {
            _ = try await client.fetchEdits(since: 0)
            XCTFail("expected decode to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, CloudSyncError.decode)
        }
    }

    // MARK: - ack

    func testAckReturnsAckedCount() async throws {
        OuraURLProtocolStub.queue = [.init(status: 200, body: #"{"acked":2}"#.data(using: .utf8)!)]
        let client = makeClient()

        let acked = try await client.ack(seqs: [1, 2])

        XCTAssertEqual(acked, 2)
        let url = OuraURLProtocolStub.requestedURLs.last?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/edits/ack"))
    }

    func testAck401ThrowsUnauthorized() async throws {
        OuraURLProtocolStub.queue = [.init(status: 401, body: "denied".data(using: .utf8)!)]
        let client = makeClient()

        do {
            _ = try await client.ack(seqs: [1])
            XCTFail("expected unauthorized to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, CloudSyncError.unauthorized(status: 401, detail: "denied"))
        }
    }

    func testAckMalformedJSONThrowsDecode() async throws {
        OuraURLProtocolStub.queue = [.init(status: 200, body: "{".data(using: .utf8)!)]
        let client = makeClient()

        do {
            _ = try await client.ack(seqs: [1])
            XCTFail("expected decode to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, CloudSyncError.decode)
        }
    }

    // MARK: - Status code -> typed error
    //
    // The noop-cloud server answers a DIFFERENT code for each failure mode on purpose, and the client
    // used to fold every one of them into `badResponse(Int, String)` — which is how "your backup is
    // fine, retry later" (507), "never send these bytes again" (400), "an optional feature is switched
    // off" (503), and "your token is wrong" (401) all became the same sentence with a different number
    // in it. One test per code, asserting the case AND (below) whether it is retryable, so a future
    // refactor cannot quietly re-collapse them.

    func testEachServerStatusMapsToItsOwnTypedError() {
        let cases: [(Int, String, CloudSyncError)] = [
            (401, #"{"error":"unauthorized"}"#,
             .unauthorized(status: 401, detail: "")),
            (403, #"{"error":"forbidden"}"#,
             .unauthorized(status: 403, detail: "")),
            (400, #"{"error":"corrupt_sqlite","detail":"file is not a database"}"#,
             .rejected(status: 400, code: "corrupt_sqlite", detail: "file is not a database")),
            (400, #"{"error":"bad_zip"}"#,
             .rejected(status: 400, code: "bad_zip", detail: "")),
            (404, #"{"error":"not_found"}"#,
             .rejected(status: 404, code: "not_found", detail: "")),
            (413, #"{"error":"too_large"}"#,
             .rejected(status: 413, code: "too_large", detail: "")),
            (507, #"{"error":"insufficient_space","detail":"only 300 MB free"}"#,
             .serverOutOfSpace(code: "insufficient_space", detail: "only 300 MB free")),
            (507, #"{"error":"storage_unavailable","detail":"EIO"}"#,
             .serverOutOfSpace(code: "storage_unavailable", detail: "EIO")),
            (500, #"{"error":"ingest_failed"}"#,
             .serverFault(status: 500, code: "ingest_failed", detail: "")),
            (502, "<html>bad gateway</html>",
             .serverFault(status: 502, code: "server_error", detail: "<html>bad gateway</html>")),
        ]
        for (status, body, expected) in cases {
            XCTAssertEqual(CloudSyncError.from(status: status, body: Data(body.utf8), lane: "ingest"),
                           expected, "status \(status) body \(body)")
        }
    }

    /// The deep-buffer 503 is the one status whose meaning depends on the body: `storage_not_configured`
    /// is "this optional lane was never switched on", which is not a failure. Any OTHER 503 is a genuine
    /// server fault and must still read as one.
    func test503IsOnlyNotConfiguredWhenTheServerSaysSo() {
        let notConfigured = #"{"error":"storage_not_configured","configured":false,"feature":"deepbuf"}"#
        XCTAssertEqual(CloudSyncError.from(status: 503, body: Data(notConfigured.utf8), lane: "deep-buffer"),
                       .featureNotConfigured(feature: "deepbuf", detail: ""))

        XCTAssertEqual(CloudSyncError.from(status: 503, body: Data(#"{"error":"overloaded"}"#.utf8),
                                            lane: "deep-buffer"),
                       .serverFault(status: 503, code: "overloaded", detail: ""))
    }

    /// The classification the retry engine actually reads. Stated as one table so "which of these does
    /// the phone try again" is answerable by reading a single test.
    func testOnlyTransientClassesAreRetryable() {
        XCTAssertTrue(CloudSyncError.serverOutOfSpace(code: "insufficient_space", detail: "").isRetryable)
        XCTAssertTrue(CloudSyncError.serverFault(status: 500, code: "x", detail: "").isRetryable)
        XCTAssertTrue(CloudSyncError.network("offline").isRetryable)

        XCTAssertFalse(CloudSyncError.unauthorized(status: 401, detail: "").isRetryable)
        XCTAssertFalse(CloudSyncError.rejected(status: 400, code: "corrupt_sqlite", detail: "").isRetryable)
        XCTAssertFalse(CloudSyncError.featureNotConfigured(feature: "deepbuf", detail: "").isRetryable)
        XCTAssertFalse(CloudSyncError.cancelled.isRetryable)
        XCTAssertFalse(CloudSyncError.decode.isRetryable)
    }

    /// Cancellation reaches this code in two different shapes depending on where it was observed — the
    /// concurrency runtime's `CancellationError` and the transport's `URLError.cancelled` — and BOTH have
    /// to land on `.cancelled`. If either fell through to `.network` it would be retryable, so a
    /// `BGAppRefreshTask` whose expiration handler just fired would sit out a backoff it cannot survive.
    func testCancellationIsNeverMistakenForANetworkFault() {
        XCTAssertEqual(CloudSyncError.from(transport: CancellationError()), .cancelled)
        XCTAssertEqual(CloudSyncError.from(transport: URLError(.cancelled)), .cancelled)
        XCTAssertEqual(CloudSyncError.from(transport: URLError(.timedOut)),
                       .network(URLError(.timedOut).localizedDescription))
    }

    /// The whole point of the taxonomy is the sentence a human ends up reading in
    /// `cloudsync.lastStatus`. Pin the two that mattered during the outage: 507 must say the data is
    /// safe and will be retried, 401 must say retrying won't help.
    func testMessagesTellTheUserWhatHappensNext() throws {
        let outOfSpace = try XCTUnwrap(
            CloudSyncError.serverOutOfSpace(code: "insufficient_space", detail: "").errorDescription)
        XCTAssertTrue(outOfSpace.contains("Nothing was lost"), outOfSpace)
        XCTAssertTrue(outOfSpace.contains("try again"), outOfSpace)

        let auth = try XCTUnwrap(CloudSyncError.unauthorized(status: 401, detail: "").errorDescription)
        XCTAssertTrue(auth.contains("Re-enter"), auth)
        XCTAssertTrue(auth.contains("won't help"), auth)

        let corrupt = try XCTUnwrap(
            CloudSyncError.rejected(status: 400, code: "corrupt_sqlite", detail: "").errorDescription)
        XCTAssertTrue(corrupt.contains("fresh backup"), corrupt)

        // Never leak an unbounded server body into a user-facing string.
        let huge = String(repeating: "x", count: 5000)
        guard case .serverFault(_, _, let detail) =
                CloudSyncError.from(status: 500, body: Data(huge.utf8), lane: "ingest") else {
            return XCTFail("expected serverFault")
        }
        XCTAssertEqual(detail.count, 200)
    }

    // MARK: - Retry behaviour through the real client

    /// A transient 500 followed by a 200: one sync, two requests, and the user never sees a failure.
    /// Before this, that first 500 ended the sync and the next attempt was the next launch.
    func testRetryableFailureIsRetriedAndCanSucceed() async throws {
        OuraURLProtocolStub.queue = [
            .init(status: 500, body: Data(#"{"error":"internal"}"#.utf8)),
            .init(status: 200, body: Data(#"{"edits":[],"latestSeq":7}"#.utf8)),
        ]
        let client = makeClient()

        let result = try await client.fetchEdits(since: 0)

        XCTAssertEqual(result.latestSeq, 7)
        XCTAssertEqual(OuraURLProtocolStub.requestedURLs.count, 2)
    }

    /// The budget is bounded: `standard` is three attempts, not "keep going". A server that is down
    /// stays down, and a sync that hangs on retries is the failure mode this whole PR exists to remove.
    func testRetryableFailureStopsAtTheAttemptLimit() async throws {
        OuraURLProtocolStub.queue = (0..<5).map { _ in
            .init(status: 503, body: Data(#"{"error":"overloaded"}"#.utf8))
        }
        let client = makeClient()

        do {
            _ = try await client.fetchEdits(since: 0)
            XCTFail("expected serverFault to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, .serverFault(status: 503, code: "overloaded", detail: ""))
        }
        XCTAssertEqual(OuraURLProtocolStub.requestedURLs.count, CloudSyncRetryPolicy.standard.maxAttempts)
    }

    /// A terminal class costs exactly one request. Retrying a 401 re-sends a credential the server has
    /// already refused; retrying a 400 re-sends bytes it has already said it cannot read.
    func testTerminalFailureIsNeverRetried() async throws {
        OuraURLProtocolStub.queue = [
            .init(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8)),
            .init(status: 200, body: Data(#"{"edits":[],"latestSeq":1}"#.utf8)),
        ]
        let client = makeClient()

        do {
            _ = try await client.fetchEdits(since: 0)
            XCTFail("expected unauthorized to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, .unauthorized(status: 401, detail: ""))
        }
        XCTAssertEqual(OuraURLProtocolStub.requestedURLs.count, 1)
    }

    /// A 2xx body the client can't parse is a contract mismatch, not a transient fault — re-running the
    /// same parse over the same endpoint cannot help, so it must not burn attempts either.
    func testDecodeFailureIsNotRetried() async throws {
        OuraURLProtocolStub.queue = [
            .init(status: 200, body: Data("not json".utf8)),
            .init(status: 200, body: Data(#"{"edits":[],"latestSeq":1}"#.utf8)),
        ]
        let client = makeClient()

        do {
            _ = try await client.fetchEdits(since: 0)
            XCTFail("expected decode to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, .decode)
        }
        XCTAssertEqual(OuraURLProtocolStub.requestedURLs.count, 1)
    }

    /// `/deepbuf`'s not-configured answer reaches the caller as `featureNotConfigured` — the case
    /// `DeepBufferUploader.drain` skips on — and is not retried, because a server with no bucket
    /// configured will answer identically for as long as that stays true.
    func testDeepBufferNotConfiguredSurfacesAsFeatureNotConfiguredAndIsNotRetried() async throws {
        let body = #"{"error":"storage_not_configured","configured":false,"feature":"deepbuf"}"#
        OuraURLProtocolStub.queue = [.init(status: 503, body: Data(body.utf8)),
                                     .init(status: 503, body: Data(body.utf8))]
        let client = makeClient()

        do {
            _ = try await client.uploadDeepBuffer(generation: "g1", byteStart: 0, byteEnd: 10,
                                                    compressed: Data([1, 2, 3]))
            XCTFail("expected featureNotConfigured to be thrown")
        } catch {
            XCTAssertEqual((error as? CloudSyncError)?.isFeatureNotConfigured, true)
        }
        XCTAssertEqual(OuraURLProtocolStub.requestedURLs.count, 1)
    }
}

final class CloudSyncSettingsTests: XCTestCase {
    override func setUp() { super.setUp(); CloudSyncSettings.clear() }
    override func tearDown() { CloudSyncSettings.clear(); super.tearDown() }

    /// Uses `isConfigured(info:)` — the pure, dict-driven seam — with an explicit EMPTY info dict
    /// rather than the live, no-arg `isConfigured` (which falls back to `Bundle.main`). This machine's
    /// `OuraSecrets.xcconfig` carries real CLOUDSYNC_URL/CLOUDSYNC_TOKEN values, so the live property
    /// would read true even with the Keychain cleared, defeating the "Keychain-only" round trip this
    /// test is actually checking. `serverURL`/`token`/`clear()` (the Keychain side) don't need a seam
    /// — they're already fully controllable in a test.
    func testSaveLoadClearRoundTrip() {
        XCTAssertFalse(CloudSyncSettings.isConfigured(info: [:]))
        XCTAssertNil(CloudSyncSettings.serverURL)
        XCTAssertNil(CloudSyncSettings.token)

        CloudSyncSettings.serverURL = "https://vk-noop-cloud.fly.dev"
        CloudSyncSettings.token = "rw-secret"
        XCTAssertEqual(CloudSyncSettings.serverURL, "https://vk-noop-cloud.fly.dev")
        XCTAssertEqual(CloudSyncSettings.token, "rw-secret")
        XCTAssertTrue(CloudSyncSettings.isConfigured(info: [:]))

        CloudSyncSettings.clear()
        XCTAssertNil(CloudSyncSettings.serverURL)
        XCTAssertNil(CloudSyncSettings.token)
        XCTAssertFalse(CloudSyncSettings.isConfigured(info: [:]))
    }

    /// Same pure-seam reasoning as `testSaveLoadClearRoundTrip` above: `info: [:]` so a real bundle
    /// CLOUDSYNC_TOKEN on this machine can't make the URL-only state read as already-configured.
    func testIsConfiguredRequiresBothValues() {
        CloudSyncSettings.serverURL = "https://vk-noop-cloud.fly.dev"
        XCTAssertFalse(CloudSyncSettings.isConfigured(info: [:]))

        CloudSyncSettings.token = "rw-secret"
        XCTAssertTrue(CloudSyncSettings.isConfigured(info: [:]))
    }

    func testEmptyStringClearsValue() {
        CloudSyncSettings.serverURL = "https://vk-noop-cloud.fly.dev"
        XCTAssertNotNil(CloudSyncSettings.serverURL)

        CloudSyncSettings.serverURL = "   "
        XCTAssertNil(CloudSyncSettings.serverURL)
    }

    // MARK: - Bundle fallback (Phase 3.5: zero-touch — bundle-injected CLOUDSYNC_URL/CLOUDSYNC_TOKEN)

    /// Pure precedence logic, driven with synthetic dicts — mirrors how `OuraCredentialsTests` tests
    /// `OuraCredentials.from(_:)` directly rather than `fromBundle` (which reads the real
    /// `Bundle.main.infoDictionary` and can't be redirected in a unit test).
    func testEffectiveValuePrefersKeychainOverBundle() {
        let v = CloudSyncSettings.effectiveValue(keychain: "from-keychain", infoKey: "CLOUDSYNC_URL",
                                                  info: ["CLOUDSYNC_URL": "from-bundle"])
        XCTAssertEqual(v, "from-keychain")
    }

    func testEffectiveValueFallsBackToBundleWhenKeychainNil() {
        let v = CloudSyncSettings.effectiveValue(keychain: nil, infoKey: "CLOUDSYNC_URL",
                                                  info: ["CLOUDSYNC_URL": "from-bundle"])
        XCTAssertEqual(v, "from-bundle")
    }

    func testEffectiveValueTrimsBundleValueAndTreatsBlankAsAbsent() {
        XCTAssertNil(CloudSyncSettings.effectiveValue(keychain: nil, infoKey: "CLOUDSYNC_URL",
                                                        info: ["CLOUDSYNC_URL": "   "]))
        XCTAssertEqual(CloudSyncSettings.effectiveValue(keychain: nil, infoKey: "CLOUDSYNC_URL",
                                                          info: ["CLOUDSYNC_URL": "  https://x  "]), "https://x")
    }

    func testEffectiveValueNilWhenNeitherKeychainNorBundlePresent() {
        XCTAssertNil(CloudSyncSettings.effectiveValue(keychain: nil, infoKey: "CLOUDSYNC_URL", info: [:]))
    }

    func testEffectiveURLAndTokenReturnKeychainValuesWhenSet() {
        CloudSyncSettings.serverURL = "https://from-keychain.example.com"
        CloudSyncSettings.token = "keychain-token"
        XCTAssertEqual(CloudSyncSettings.effectiveURL, "https://from-keychain.example.com")
        XCTAssertEqual(CloudSyncSettings.effectiveToken, "keychain-token")
        XCTAssertTrue(CloudSyncSettings.isConfigured)
    }

    /// No Keychain override present: `isBundleConfigured` must be false regardless of whatever the
    /// test runner's own bundle happens to carry for CLOUDSYNC_URL/CLOUDSYNC_TOKEN (never set in the
    /// StrandTests bundle in practice), because a real Keychain override always wins the UI's
    /// collapsed-vs-manual-fields decision.
    func testIsBundleConfiguredFalseWhenKeychainOverridePresent() {
        CloudSyncSettings.serverURL = "https://from-keychain.example.com"
        CloudSyncSettings.token = "keychain-token"
        XCTAssertFalse(CloudSyncSettings.isBundleConfigured)
    }

    /// Uses `isBundleConfigured(info:)` with an explicit EMPTY info dict — the pure seam — rather than
    /// the live, no-arg `isBundleConfigured`. This machine's `OuraSecrets.xcconfig` carries real
    /// CLOUDSYNC_URL/CLOUDSYNC_TOKEN values, which reach `Bundle.main.infoDictionary` at test-run
    /// time, so the live property now genuinely reads true here — asserting against it directly would
    /// make this test fail specifically BECAUSE the zero-touch bundle credentials are configured
    /// correctly. `info: [:]` tests the "no bundle creds" branch deterministically instead.
    func testIsBundleConfiguredFalseWithNoKeychainAndNoBundleCreds() {
        // Fresh state (clear()'d in setUp): no Keychain values, and a synthetic empty info dict, so
        // this must read false, not silently true.
        XCTAssertFalse(CloudSyncSettings.isBundleConfigured(info: [:]))
    }

    // MARK: - Bundle URL validation (fold-in: a malformed CLOUDSYNC_URL is treated as absent)

    /// Pure, no `Bundle`/Keychain dependency — the same shape check `CloudSyncModel.saveSettings`
    /// runs before a manually-entered URL is ever written to the Keychain.
    func testIsValidServerURLAcceptsAbsoluteURLWithSchemeAndHost() {
        XCTAssertTrue(CloudSyncSettings.isValidServerURL("https://vk-noop-cloud.fly.dev"))
        XCTAssertTrue(CloudSyncSettings.isValidServerURL("http://localhost:8080"))
    }

    func testIsValidServerURLRejectsMissingSchemeOrHost() {
        XCTAssertFalse(CloudSyncSettings.isValidServerURL("not a url"))
        XCTAssertFalse(CloudSyncSettings.isValidServerURL(""))
        XCTAssertFalse(CloudSyncSettings.isValidServerURL("justapath"))
        XCTAssertFalse(CloudSyncSettings.isValidServerURL("vk-noop-cloud.fly.dev"))   // no scheme
        XCTAssertFalse(CloudSyncSettings.isValidServerURL("https://"))                // no host
    }

    /// A malformed bundle URL must be treated as absent by BOTH `effectiveURL` and `isConfigured` —
    /// not just the former. `isConfigured(info:)` derives its URL half from the same `effectiveValue`
    /// call as `effectiveURL`, so this pins the two together: a build never ends up with the "Sync
    /// now" button enabled (`isConfigured` true) while `effectiveURL` itself reads nil and the button
    /// would immediately fail with "Add your noop-cloud server URL and token first."
    func testIsConfiguredFalseWhenBundleURLIsMalformedEvenWithATokenPresent() {
        XCTAssertFalse(CloudSyncSettings.isConfigured(info: ["CLOUDSYNC_URL": "not a url",
                                                              "CLOUDSYNC_TOKEN": "some-token"]))
    }
}
#endif // CLOUD_SYNC
