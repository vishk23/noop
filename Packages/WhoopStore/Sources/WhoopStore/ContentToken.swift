import Foundation
import GRDB

extension WhoopStore {
    /// Cheap composite fingerprint of the store's DATA tables — deliberately excluding `cursors` (see
    /// below) — that changes if and only if something an upload would actually ship has changed.
    /// `CloudSyncModel.performSync` (Cloud Sync v2) compares this against the token it saved after the
    /// last successful upload FROM THIS DEVICE (`UserDefaults["cloudsync.lastUploadToken"]`) to skip a
    /// redundant re-export + POST of an unchanged 100-300MB `.noopbak`.
    ///
    /// Format: `"hr:<count>:<maxTs>|sleep:<count>:<maxEndTs>|daily:<count>:<maxDay>|workout:<count>|series:<count>"`
    /// — opaque, comparable only to itself, never parsed back apart. The `hr`/`sleep`/`daily` segments
    /// mirror `hrFingerprint`'s (count, max) change-detector shape (Reads.swift): a SQL `COUNT(*)` plus a
    /// `COALESCE(MAX(…), default)` aggregate over one table, computed entirely in SQLite with no row
    /// materialized into Swift. `workout` and `metricSeries` use `COUNT` alone: `workout` rows are
    /// rewritten IN PLACE by `fix_workout`/`delete_workout` (no column is a safe append-only max to key
    /// on) and `metricSeries.day` is written far out of order by design.
    ///
    /// KNOWN RESIDUE — this token does NOT detect every equal-count in-place correction, and a caller
    /// that already knows an edit landed must not read "token unchanged" as "nothing changed". An
    /// earlier version of this comment claimed such a correction "still moves the `hrSample`/`dailyMetric`
    /// segments in the same edit"; that is false. Two confirmed counterexamples, both routine:
    /// - `fix_workout` tombstones the original row, upserts the corrected copy under the `noop-cloud`
    ///   device, then deletes the original — +1 then -1, so `COUNT(*) FROM workout` is unchanged, and it
    ///   writes to no other table this token reads.
    /// - `adjust_sleep_bounds` / `edit_sleep_stages` UPDATE a `sleepSession` row in place; restaging any
    ///   night that is not the most recent leaves both `COUNT(*)` and `MAX(endTs)` exactly as they were.
    ///
    /// Closing this at the fingerprint would mean content-hashing whole tables here, and would change the
    /// token's format — forcing every device one full re-upload. The consumer instead treats a pull that
    /// applied edits as unconditionally dirty: see `CloudSyncModel.performSync`'s `mustUpload`. This token
    /// stays what it is good at — cheaply proving that a device with no new samples and no applied edits
    /// has nothing to ship.
    ///
    /// Deliberately EXCLUDES `cursors`: that table is sync BOOKKEEPING (`cloud_edits`,
    /// `cloud_edits_recomputed`, `stagelock:…`, the `highwater:`/`read:` cursors) rather than user data.
    /// A cursor write must never dirty the token — a pull that applies zero edits can still advance
    /// `cloud_edits`, and an unrelated stream's highwater bump happens on nearly every sync; if either
    /// counted, the token would read "changed" on almost every sync regardless of whether any actual
    /// data moved, defeating the whole point of skipping the upload. (The saved comparison value itself,
    /// `cloudsync.lastUploadToken`, lives in `UserDefaults` on `CloudSyncModel`, not in this store at
    /// all — so writing it can never feed back into this computation either.)
    public func contentToken() async throws -> String {
        try syncRead { db in
            let hrCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample") ?? 0
            let hrMaxTs = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(ts), 0) FROM hrSample") ?? 0

            let sleepCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sleepSession") ?? 0
            let sleepMaxEndTs = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(endTs), 0) FROM sleepSession") ?? 0

            let dailyCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dailyMetric") ?? 0
            let dailyMaxDay = try String.fetchOne(db, sql: "SELECT COALESCE(MAX(day), '') FROM dailyMetric") ?? ""

            let workoutCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout") ?? 0
            let seriesCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metricSeries") ?? 0

            return "hr:\(hrCount):\(hrMaxTs)|sleep:\(sleepCount):\(sleepMaxEndTs)|daily:\(dailyCount):\(dailyMaxDay)"
                 + "|workout:\(workoutCount)|series:\(seriesCount)"
        }
    }
}
