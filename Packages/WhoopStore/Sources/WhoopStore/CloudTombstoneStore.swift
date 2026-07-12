import Foundation
import GRDB

// MARK: - v26 store: cloud edit tombstones (resurrection guards)
// A server-side journal delete (workout / HR range / metric point) is applied locally as a
// physical DELETE (see CloudEditDeletes) plus a tombstone row here, so a LATER re-sync/backfill/
// live-BLE write can never silently resurrect the same data. Mirrors OuraRawStore/MetricSeriesStore:
// idempotent inserts, range/set reads, all GRDB work via the actor's syncWrite/syncRead helpers.
//
// The three `*TombstoneRows` helpers take an already-open `Database` connection rather than going
// through `syncRead`, so a guard running INSIDE another store's `syncWrite` block (upsertWorkouts,
// upsertMetricSeries, StreamStore.insert) queries on the SAME connection/transaction instead of
// opening a second one. The public `workoutTombstones`/etc. accessors below simply wrap them in
// `syncRead` for callers outside a write.

extension WhoopStore {

    /// Workout tombstones for a device: `(startTs, sport)` pairs a resurrection guard must drop.
    /// Shared by the public `workoutTombstones` read and the `upsertWorkouts` guard.
    static func workoutTombstoneRows(_ db: Database, deviceId: String) throws -> [(startTs: Int, sport: String)] {
        try Row.fetchAll(db, sql: """
            SELECT startTs, sport FROM cloudTombstone WHERE kind = 'workout' AND deviceId = ?
            """, arguments: [deviceId])
            .map { (startTs: $0["startTs"], sport: $0["sport"]) }
    }

    /// HR-range tombstones for a device: `(fromTs, toTs)` ranges a live/backfill insert must filter.
    /// Shared by the public `hrTombstoneRanges` read and the `StreamStore.insert` guard.
    static func hrTombstoneRangeRows(_ db: Database, deviceId: String) throws -> [(fromTs: Int, toTs: Int)] {
        try Row.fetchAll(db, sql: """
            SELECT startTs, endTs FROM cloudTombstone WHERE kind = 'hrRange' AND deviceId = ?
            """, arguments: [deviceId])
            .map { (fromTs: $0["startTs"], toTs: $0["endTs"]) }
    }

    /// Metric-point tombstones for a device: `(day, key)` pairs a resurrection guard must drop.
    /// Shared by the public `metricPointTombstones` read and the `upsertMetricSeries` guard.
    static func metricPointTombstoneRows(_ db: Database, deviceId: String) throws -> [(day: String, key: String)] {
        try Row.fetchAll(db, sql: """
            SELECT day, key FROM cloudTombstone WHERE kind = 'metricPoint' AND deviceId = ?
            """, arguments: [deviceId])
            .map { (day: $0["day"], key: $0["key"]) }
    }

    /// Record a cloud-edit tombstone. Idempotent by (kind, editSeq) — INSERT OR IGNORE, so replaying
    /// the same journal entry (e.g. after a reconnect) is a no-op rather than a duplicate row.
    /// `startTs`/`endTs`/`sport` apply to "workout"/"hrRange" kinds; `day`/`key` to "metricPoint" —
    /// the caller passes nil for whichever fields don't apply to `kind`.
    public func addTombstone(kind: String, deviceId: String, startTs: Int?, endTs: Int?,
                              sport: String?, day: String?, key: String?, editSeq: Int) async throws {
        let now = Int(Date().timeIntervalSince1970)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO cloudTombstone
                    (kind, deviceId, startTs, endTs, sport, day, key, editSeq, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [kind, deviceId, startTs, endTs, sport, day, key, editSeq, now])
        }
    }

    /// Workout tombstones for a device (unordered). See `workoutTombstoneRows` for the guard-side use.
    public func workoutTombstones(deviceId: String) async throws -> [(startTs: Int, sport: String)] {
        try syncRead { db in try WhoopStore.workoutTombstoneRows(db, deviceId: deviceId) }
    }

    /// HR-range tombstones for a device (unordered). See `hrTombstoneRangeRows` for the guard-side use.
    public func hrTombstoneRanges(deviceId: String) async throws -> [(fromTs: Int, toTs: Int)] {
        try syncRead { db in try WhoopStore.hrTombstoneRangeRows(db, deviceId: deviceId) }
    }

    /// Metric-point tombstones for a device (unordered). See `metricPointTombstoneRows` for the guard-side use.
    public func metricPointTombstones(deviceId: String) async throws -> [(day: String, key: String)] {
        try syncRead { db in try WhoopStore.metricPointTombstoneRows(db, deviceId: deviceId) }
    }

    /// Remove every cloud-edit tombstone for a device (used by a future full-disconnect flow —
    /// `deleteAllData` deliberately does NOT cover `cloudTombstone`, see
    /// `DeviceRegistryStore.deviceScopedTableExemptions`). Mirrors `deleteOuraRaw`. Returns rows deleted.
    @discardableResult
    public func deleteCloudTombstones(deviceId: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM cloudTombstone WHERE deviceId = ?", arguments: [deviceId])
            return db.changesCount
        }
    }
}

/// Hashable natural key for the `upsertWorkouts` resurrection guard's pre-loaded tombstone Set.
struct WorkoutTombstoneKey: Hashable {
    let startTs: Int
    let sport: String
}

/// Hashable natural key for the `upsertMetricSeries` resurrection guard's pre-loaded tombstone Set.
struct MetricPointTombstoneKey: Hashable {
    let day: String
    let key: String
}
