import XCTest
import GRDB
@testable import WhoopStore

final class PhoneTimezoneStoreTests: XCTestCase {

    /// v28 creates the phoneTimezone table with `day` as the sole primary key.
    func testV28CreatesPhoneTimezoneTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("phoneTimezone"), "missing v28 phoneTimezone table")
        let cols = try await store.primaryKeyColumns("phoneTimezone")
        XCTAssertEqual(cols, ["day"])
    }

    func testUpsertIsIdempotentByDay() async throws {
        let store = try await WhoopStore.inMemory()
        let n1 = try await store.upsertPhoneTimezone(day: "2026-07-14", tzId: "America/Los_Angeles")
        XCTAssertEqual(n1, 1)

        // Same day, phone now on Eastern → overwrite in place, still one row.
        let n2 = try await store.upsertPhoneTimezone(day: "2026-07-14", tzId: "America/New_York")
        XCTAssertEqual(n2, 1)

        let tz = try await store.phoneTimezone(day: "2026-07-14")
        XCTAssertEqual(tz, "America/New_York")
    }

    func testDistinctDaysCoexist() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertPhoneTimezone(day: "2026-07-13", tzId: "America/Los_Angeles")
        _ = try await store.upsertPhoneTimezone(day: "2026-07-14", tzId: "America/New_York")

        let d13 = try await store.phoneTimezone(day: "2026-07-13")
        let d14 = try await store.phoneTimezone(day: "2026-07-14")
        XCTAssertEqual(d13, "America/Los_Angeles")
        XCTAssertEqual(d14, "America/New_York")
    }

    func testMissingDayReturnsNil() async throws {
        let store = try await WhoopStore.inMemory()
        let tz = try await store.phoneTimezone(day: "1999-01-01")
        XCTAssertNil(tz)
    }
}
