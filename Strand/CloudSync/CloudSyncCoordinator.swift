// Compiled ONLY when the CLOUD_SYNC compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if CLOUD_SYNC
import Foundation
import WhoopStore

/// Abstracts the edit-journal fetch/ack calls so the coordinator is testable without a live network
/// (CloudSyncClient conforms below) — mirrors OuraSyncCoordinator's `OuraPageFetching` seam.
protocol CloudEditFetching {
    func fetchEdits(since: Int) async throws -> (edits: [CloudEdit], latestSeq: Int)
    func ack(seqs: [Int]) async throws -> Int
}
extension CloudSyncClient: CloudEditFetching {}

/// Pulls confirmed noop-cloud edit-journal rows since this device's last cursor, applies them through
/// `CloudEditApplier`, and acknowledges what it processed. A pure coordination step — no state of its
/// own, so (like `CloudEditApplier`) it's a namespace of static functions rather than an instance.
enum CloudSyncCoordinator {
    /// The `cursors` table name this lane's pull position is stored under.
    static let cursorName = "cloud_edits"

    /// since = this device's stored cursor (0 if never synced) → fetch the page after it → apply
    /// every row through `CloudEditApplier` → ack every seq the applier processed (applied, skipped,
    /// AND needsAttention alike — see `CloudApplySummary.appliedSeqs`'s doc) → ONLY THEN advance the
    /// cursor to the server's latest seq.
    ///
    /// The ack-then-cursor ordering is load-bearing: if `ack` throws (a transient network failure),
    /// the cursor must stay at `since` so the NEXT pull re-fetches and re-applies the same batch —
    /// safe only because `CloudEditApplier`'s writes are idempotent upserts/tombstones, never raw
    /// appends. Advancing the cursor first would risk acknowledging-by-implication a batch the server
    /// never actually heard back from us about, silently losing it forever.
    ///
    /// An empty page (nothing new since `since`) is a no-op: `appliedSeqs` is empty, so neither `ack`
    /// nor the cursor write happens — there is nothing to acknowledge and the cursor is already correct.
    static func pull(store: WhoopStore, client: any CloudEditFetching) async throws -> CloudApplySummary {
        let since = try await store.cursor(cursorName) ?? 0
        let (edits, latestSeq) = try await client.fetchEdits(since: since)
        let summary = await CloudEditApplier.apply(edits, store: store)
        guard !summary.appliedSeqs.isEmpty else { return summary }
        _ = try await client.ack(seqs: summary.appliedSeqs)
        try await store.setCursor(cursorName, latestSeq)
        return summary
    }
}
#endif // CLOUD_SYNC
