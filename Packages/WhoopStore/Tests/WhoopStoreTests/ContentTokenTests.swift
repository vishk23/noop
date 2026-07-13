import XCTest
import WhoopProtocol
@testable import WhoopStore

final class ContentTokenTests: XCTestCase {
    func testTokenIsStableAndDeterministicOnAnEmptyStore() async throws {
        let store = try await WhoopStore.inMemory()
        let a = try await store.contentToken()
        let b = try await store.contentToken()
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "hr:0:0|sleep:0:0|daily:0:|workout:0|series:0")
    }

    func testInsertingHrSampleChangesToken() async throws {
        let store = try await WhoopStore.inMemory()
        let before = try await store.contentToken()
        _ = try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 60)]), deviceId: "dev1")
        let after = try await store.contentToken()
        XCTAssertNotEqual(before, after)
    }

    func testInsertingSleepSessionChangesToken() async throws {
        let store = try await WhoopStore.inMemory()
        let before = try await store.contentToken()
        _ = try await store.upsertSleepSessions(
            [CachedSleepSession(startTs: 1000, endTs: 5000, efficiency: nil, restingHr: nil,
                                 avgHrv: nil, stagesJSON: nil)], deviceId: "dev1")
        let after = try await store.contentToken()
        XCTAssertNotEqual(before, after)
    }

    func testInsertingDailyMetricChangesToken() async throws {
        let store = try await WhoopStore.inMemory()
        let before = try await store.contentToken()
        _ = try await store.upsertDailyMetrics(
            [DailyMetric(day: "2026-05-23", totalSleepMin: 420, efficiency: 0.9, deepMin: nil,
                         remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                         recovery: nil, strain: nil, exerciseCount: nil)], deviceId: "dev1")
        let after = try await store.contentToken()
        XCTAssertNotEqual(before, after)
    }

    func testInsertingWorkoutChangesToken() async throws {
        let store = try await WhoopStore.inMemory()
        let before = try await store.contentToken()
        _ = try await store.upsertWorkouts(
            [WorkoutRow(startTs: 100, endTs: 200, sport: "running", source: "whoop", durationS: 100,
                        energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                        zonesJSON: nil, notes: nil)], deviceId: "dev1")
        let after = try await store.contentToken()
        XCTAssertNotEqual(before, after)
    }

    func testInsertingMetricSeriesPointChangesToken() async throws {
        let store = try await WhoopStore.inMemory()
        let before = try await store.contentToken()
        _ = try await store.upsertMetricSeries(
            [MetricPoint(day: "2026-05-20", key: "restingHr", value: 54)], deviceId: "dev1")
        let after = try await store.contentToken()
        XCTAssertNotEqual(before, after)
    }

    // The whole point of this token: sync bookkeeping (cursors) must never look like a data change,
    // or every pull/highwater bump would force a full re-upload regardless of whether anything a
    // backup actually carries moved.
    func testCursorWriteDoesNotChangeToken() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 60)]), deviceId: "dev1")
        let before = try await store.contentToken()
        try await store.setCursor("cloud_edits", 42)
        try await store.setCursor("highwater:hr", 999)
        let after = try await store.contentToken()
        XCTAssertEqual(before, after)
    }
}
