import Foundation
import GRDB

// MARK: - v28 store: the phone's IANA timezone, one row per local day
// Every timestamp in the DB is epoch-UTC and nothing else records which zone the phone was in when a
// day was lived, so a wall-clock reading of a historical night is guesswork once the user crosses time
// zones. This table stamps each local calendar day with `TimeZone.current.identifier` so downstream
// analysis can localise that specific day. Idempotent upsert keyed by `day`: recording the same day
// again overwrites the identifier in place rather than duplicating.

extension WhoopStore {

    /// Upsert the phone's IANA timezone identifier for a local calendar day. Idempotent by `day`:
    /// re-recording the same day overwrites its identifier rather than inserting a duplicate. Returns
    /// rows changed.
    @discardableResult
    public func upsertPhoneTimezone(day: String, tzId: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO phoneTimezone (day, tzId)
                VALUES (?, ?)
                ON CONFLICT(day) DO UPDATE SET
                    tzId = excluded.tzId
                """, arguments: [day, tzId])
            return db.changesCount
        }
    }

    /// The phone's recorded IANA timezone identifier for a local calendar day, or nil if none stored.
    public func phoneTimezone(day: String) async throws -> String? {
        try syncRead { db in
            try String.fetchOne(db, sql: """
                SELECT tzId FROM phoneTimezone WHERE day = ?
                """, arguments: [day])
        }
    }
}
