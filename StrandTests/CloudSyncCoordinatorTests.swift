// Tests the CLOUD_SYNC-gated cloud sync coordinator; compiled only when the flag is set
// (StrandTests shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if CLOUD_SYNC
import XCTest
import WhoopStore
@testable import Strand

/// A fetcher that serves canned edits + a latest seq, and can simulate an ack failure. Mirrors
/// OuraSyncCoordinatorTests's StubFetcher.
private final class StubCloudEditFetcher: CloudEditFetching {
    var edits: [CloudEdit] = []
    var latestSeq = 0
    var failAck = false
    private(set) var fetchSinceCalls: [Int] = []
    private(set) var ackedSeqs: [[Int]] = []

    func fetchEdits(since: Int) async throws -> (edits: [CloudEdit], latestSeq: Int) {
        fetchSinceCalls.append(since)
        return (edits, latestSeq)
    }
    func ack(seqs: [Int]) async throws -> Int {
        if failAck { throw StubAckError() }
        ackedSeqs.append(seqs)
        return seqs.count
    }
}

private struct StubAckError: Error {}

/// Builds a minimal CloudEdit for a given kind + payload, with the rest of the envelope defaulted.
private func makeEdit(seq: Int, kind: String, payloadJSON: String, beforeJSON: String? = nil) -> CloudEdit {
    CloudEdit(seq: seq, editId: "e\(seq)", kind: kind, payloadJSON: payloadJSON, beforeJSON: beforeJSON,
              rationale: nil, appliedAt: 0, undoneBySeq: nil, ackedAt: nil)
}

final class CloudSyncCoordinatorTests: XCTestCase {
    func testAppliesEditsAcksAndAdvancesCursorOnlyAfterAck() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = StubCloudEditFetcher()
        // delete_metric_point applies cleanly even with nothing to delete (tombstone insert + a
        // no-op DELETE both succeed), so this is a deterministic "applied" outcome.
        fetcher.edits = [makeEdit(seq: 1, kind: "delete_metric_point",
                                   payloadJSON: #"{"deviceId":"my-whoop","day":"2026-01-01","key":"steps"}"#)]
        fetcher.latestSeq = 1

        let before = try await store.cursor("cloud_edits")
        XCTAssertNil(before)

        let summary = try await CloudSyncCoordinator.pull(store: store, client: fetcher)

        XCTAssertEqual(summary.applied, 1)
        XCTAssertEqual(summary.appliedSeqs, [1])
        XCTAssertEqual(fetcher.ackedSeqs, [[1]])
        let after = try await store.cursor("cloud_edits")
        XCTAssertEqual(after, 1)

        // A second pull starts from the advanced cursor, not from 0 again.
        fetcher.edits = []
        fetcher.latestSeq = 1
        _ = try await CloudSyncCoordinator.pull(store: store, client: fetcher)
        XCTAssertEqual(fetcher.fetchSinceCalls, [0, 1])
    }

    func testAckFailureKeepsCursorUnchanged() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = StubCloudEditFetcher()
        fetcher.edits = [makeEdit(seq: 5, kind: "delete_metric_point",
                                   payloadJSON: #"{"deviceId":"my-whoop","day":"2026-01-01","key":"steps"}"#)]
        fetcher.latestSeq = 5
        fetcher.failAck = true

        do {
            _ = try await CloudSyncCoordinator.pull(store: store, client: fetcher)
            XCTFail("expected the ack failure to propagate")
        } catch {
            // expected — ack threw, so pull() must throw rather than silently swallow it.
        }

        // Cursor must stay unset: re-applying the same batch on retry is idempotent, but only if the
        // cursor never advanced past an edit that was never actually acked.
        let cursor = try await store.cursor("cloud_edits")
        XCTAssertNil(cursor)
    }

    func testNeedsAttentionSurfacesInSummaryAndStillAdvancesCursor() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = StubCloudEditFetcher()
        // adjust_sleep_bounds against a session that doesn't exist in the (empty) store —
        // CloudEditApplier can't find it, so this lands in needsAttention, not applied.
        fetcher.edits = [makeEdit(seq: 9, kind: "adjust_sleep_bounds",
                                   payloadJSON: #"{"deviceId":"my-whoop","startTs":1700000000,"newStartTs":null,"newEndTs":null}"#)]
        fetcher.latestSeq = 9

        let summary = try await CloudSyncCoordinator.pull(store: store, client: fetcher)

        XCTAssertEqual(summary.needsAttention, 1)
        XCTAssertEqual(summary.applied, 0)
        // needsAttention rows are still "processed" — acked and cursor-advanced like any other seq.
        XCTAssertEqual(fetcher.ackedSeqs, [[9]])
        let cursor = try await store.cursor("cloud_edits")
        XCTAssertEqual(cursor, 9)
    }

    func testEmptyFetchNoOps() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = StubCloudEditFetcher()
        fetcher.edits = []
        fetcher.latestSeq = 42   // server is ahead, but there's nothing THIS device hasn't seen

        let summary = try await CloudSyncCoordinator.pull(store: store, client: fetcher)

        XCTAssertEqual(summary.applied, 0)
        XCTAssertEqual(summary.skipped, 0)
        XCTAssertEqual(summary.needsAttention, 0)
        XCTAssertTrue(summary.appliedSeqs.isEmpty)
        XCTAssertTrue(fetcher.ackedSeqs.isEmpty)   // no ack call at all
        let cursor = try await store.cursor("cloud_edits")
        XCTAssertNil(cursor)   // nothing processed, so the cursor is left alone
    }
}
#endif // CLOUD_SYNC
