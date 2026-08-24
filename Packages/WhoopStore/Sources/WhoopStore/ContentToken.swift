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
    /// on) and `metricSeries.day` is written far out of order by design — for both, a changed COUNT
    /// already catches every insert/delete/tombstone, and an in-place correction that leaves a table's
    /// own row count unchanged (e.g. `fix_workout`'s patch) still moves the `hrSample`/`dailyMetric`
    /// segments in the same edit, so the composite token still changes.
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
