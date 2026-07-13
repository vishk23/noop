import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class MigrationTests: XCTestCase {
    func testInMemoryRunsMigrations() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "event", "battery", "rawBatch"] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
        }
    }

    func testFileInitRunsMigrations() async throws {
        let path = NSTemporaryDirectory() + "whoopstore-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try await WhoopStore(path: path)
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("hrSample"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testHrSamplePrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("hrSample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    /// v24 widens the R-R key with a `seq` tiebreaker so two EQUAL successive intervals in the same
    /// second both survive (the old value-only key dropped the 2nd, biasing RMSSD/HRV high). #163.
    func testRrIntervalPrimaryKeyIncludesSeq() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("rrInterval")
        XCTAssertEqual(cols, ["deviceId", "ts", "rrMs", "seq"])
    }

    func testV24AddsSeqColumnToRrInterval() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "rrInterval")
        XCTAssertTrue(cols.contains("seq"), "rrInterval missing v24 seq column")
    }

    func testV24KeepsEqualSameSecondBeats() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // Two EQUAL R-R intervals in the same second: the old value-only key dropped the 2nd; v24 keeps both.
        let n = try await store.insert(
            Streams(rr: [RRInterval(ts: 100, rrMs: 812), RRInterval(ts: 100, rrMs: 812)]),
            deviceId: "dev1")
        XCTAssertEqual(n.rr, 2)
        let read = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        XCTAssertEqual(read.count, 2)
        XCTAssertTrue(read.allSatisfy { $0.ts == 100 && $0.rrMs == 812 })
    }

    func testV24DistinctBeatsAllKept() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // Distinct (ts, rrMs) beats — incl. two values in the same second — each keep seq 0 and their slot.
        let n = try await store.insert(
            Streams(rr: [RRInterval(ts: 100, rrMs: 602), RRInterval(ts: 100, rrMs: 613),
                         RRInterval(ts: 101, rrMs: 602)]),
            deviceId: "dev1")
        XCTAssertEqual(n.rr, 3)
    }

    /// v5 adds a `synced` column to all 8 decoded tables.
    func testV5AddsSyncedColumnToDecodedTables() async throws {
        let store = try await WhoopStore.inMemory()
        for table in ["hrSample", "rrInterval", "event", "battery",
                      "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
            let cols = try await store.columnNamesForTest(table: table)
            XCTAssertTrue(cols.contains("synced"), "\(table) missing synced column")
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 18)
    }

    /// v13 adds the `userEdited` flag to sleepSession (user-corrected wake times survive re-sync).
    func testV13AddsUserEditedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("userEdited"), "sleepSession missing v13 userEdited column")
    }

    /// v14 adds `startTsAdjusted` (the user-corrected sleep onset; detected startTs stays the key).
    func testV14AddsStartTsAdjustedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("startTsAdjusted"), "sleepSession missing v14 startTsAdjusted column")
    }

    /// v16 adds `peripheralId` to pairedDevice (stable per-strap BLE identity for multi-WHOOP support).
    func testV16AddsPeripheralIdColumnToPairedDevice() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "pairedDevice")
        XCTAssertTrue(cols.contains("peripheralId"), "pairedDevice missing v16 peripheralId column")
    }

    /// v26 heals `deviceId = 'oura-api'` rows written with Oura's native 0-100 `efficiency` (before the
    /// OuraApiParser fix) back to NOOP's 0-1 fraction convention. UPDATE-only: seed rows at the v25
    /// schema (i.e. BEFORE v26 has run), then apply the rest of the migrator and confirm the heal.
    func testV26HealsOuraEfficiencyPercentToFraction() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v25-oura-raw")
        try await dbQueue.write { db in
            // oura-api, bad (percent) → must be healed to a fraction.
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency) VALUES ('oura-api', 100, 200, 90)
                """)
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, efficiency) VALUES ('oura-api', '2026-01-01', 90)
                """)
            // oura-api, already a fraction → must be left unchanged (idempotent predicate: efficiency > 1.5).
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency) VALUES ('oura-api', 300, 400, 0.9)
                """)
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, efficiency) VALUES ('oura-api', '2026-01-02', 0.9)
                """)
            // A non-Oura row above the threshold must be left alone — the heal is deviceId-scoped.
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency) VALUES ('my-whoop', 500, 600, 90)
                """)
        }

        // Apply the FULL migrator: GRDB resumes from the already-applied v25, so only v26 runs here.
        try WhoopStore.makeMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 100"), 0.9)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 300"), 0.9)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 500"), 90,
                           "a non-oura-api row must not be touched by the deviceId-scoped heal")
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM dailyMetric WHERE day = '2026-01-01'"), 0.9)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM dailyMetric WHERE day = '2026-01-02'"), 0.9)
        }
    }
}
