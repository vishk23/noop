import Foundation
import GRDB

// MARK: - Cloud edit deletes: physical DELETEs paired with a CloudTombstoneStore.addTombstone call.
// A server-side journal delete must remove the local row(s) AND record a tombstone (else the next
// sync/backfill/live-BLE write resurrects them) — a caller applies both, in either order. Plain
// DELETEs, no upsert semantics; each returns the number of rows actually removed.

extension WhoopStore {

    /// Physically delete HR samples for a device with `ts` in `[fromTs, toTs]` inclusive.
    /// Returns rows deleted. Pair with `addTombstone(kind: "hrRange", ...)` so a later re-sync
    /// (backfill replay, or the strap re-streaming an already-deleted window) can't resurrect them.
    @discardableResult
    public func deleteHrRange(deviceId: String, fromTs: Int, toTs: Int) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM hrSample WHERE deviceId = ? AND ts >= ? AND ts <= ?
                """, arguments: [deviceId, fromTs, toTs])
            return db.changesCount
        }
    }

    /// Physically delete one metric point by natural key (deviceId, day, key). Returns rows deleted.
    /// Pair with `addTombstone(kind: "metricPoint", ...)` so a later re-derive/re-upsert can't
    /// resurrect it.
    @discardableResult
    public func deleteMetricPoint(deviceId: String, day: String, key: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM metricSeries WHERE deviceId = ? AND day = ? AND key = ?
                """, arguments: [deviceId, day, key])
            return db.changesCount
        }
    }
}
