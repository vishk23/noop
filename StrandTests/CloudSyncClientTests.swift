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

    func testSaveLoadClearRoundTrip() {
        XCTAssertFalse(CloudSyncSettings.isConfigured)
        XCTAssertNil(CloudSyncSettings.serverURL)
        XCTAssertNil(CloudSyncSettings.token)

        CloudSyncSettings.serverURL = "https://vk-noop-cloud.fly.dev"
        CloudSyncSettings.token = "rw-secret"
        XCTAssertEqual(CloudSyncSettings.serverURL, "https://vk-noop-cloud.fly.dev")
        XCTAssertEqual(CloudSyncSettings.token, "rw-secret")
        XCTAssertTrue(CloudSyncSettings.isConfigured)

        CloudSyncSettings.clear()
        XCTAssertNil(CloudSyncSettings.serverURL)
        XCTAssertNil(CloudSyncSettings.token)
        XCTAssertFalse(CloudSyncSettings.isConfigured)
    }

    func testIsConfiguredRequiresBothValues() {
        CloudSyncSettings.serverURL = "https://vk-noop-cloud.fly.dev"
        XCTAssertFalse(CloudSyncSettings.isConfigured)

        CloudSyncSettings.token = "rw-secret"
        XCTAssertTrue(CloudSyncSettings.isConfigured)
    }

    func testEmptyStringClearsValue() {
        CloudSyncSettings.serverURL = "https://vk-noop-cloud.fly.dev"
        XCTAssertNotNil(CloudSyncSettings.serverURL)

        CloudSyncSettings.serverURL = "   "
        XCTAssertNil(CloudSyncSettings.serverURL)
    }
}
#endif // CLOUD_SYNC
