// Tests the CLOUD_SYNC-gated cloud sync client + settings; compiled only when the flag is set
// (StrandTests shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if CLOUD_SYNC
import XCTest
@testable import Strand

final class CloudSyncClientTests: XCTestCase {
    override func setUp() { super.setUp(); OuraURLProtocolStub.reset() }

    private let baseURL = URL(string: "https://cloud.example.com")!

    private func makeClient() -> CloudSyncClient {
        CloudSyncClient(baseURL: baseURL, token: "tok-1", session: OuraURLProtocolStub.session())
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

    func testFetchEdits401ThrowsBadResponse() async throws {
        OuraURLProtocolStub.queue = [.init(status: 401, body: "nope".data(using: .utf8)!)]
        let client = makeClient()

        do {
            _ = try await client.fetchEdits(since: 0)
            XCTFail("expected badResponse to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, CloudSyncError.badResponse(401, "nope"))
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

    func testAck401ThrowsBadResponse() async throws {
        OuraURLProtocolStub.queue = [.init(status: 401, body: "denied".data(using: .utf8)!)]
        let client = makeClient()

        do {
            _ = try await client.ack(seqs: [1])
            XCTFail("expected badResponse to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, CloudSyncError.badResponse(401, "denied"))
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
