import XCTest
@testable import WhoopStore
import WhoopProtocol

final class CloudTombstoneTests: XCTestCase {
    func testWorkoutTombstoneBlocksResurrection() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertWorkouts([WorkoutRow(startTs: 100, endTs: 200, sport: "running", source: "whoop", durationS: 100, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)], deviceId: "d1")
        try await store.addTombstone(kind: "workout", deviceId: "d1", startTs: 100, endTs: nil, sport: "running", day: nil, key: nil, editSeq: 7)
        _ = try await store.deleteWorkouts(deviceId: "d1", sport: "running", from: 100, to: 100)
        // Re-import attempts to resurrect — the guard must drop it.
        let n = try await store.upsertWorkouts([WorkoutRow(startTs: 100, endTs: 200, sport: "running", source: "whoop", durationS: 100, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)], deviceId: "d1")
        XCTAssertEqual(n, 0)
        // Idempotent tombstone insert (same kind+editSeq).
        try await store.addTombstone(kind: "workout", deviceId: "d1", startTs: 100, endTs: nil, sport: "running", day: nil, key: nil, editSeq: 7)
    }
    func testHrRangeTombstoneFiltersInserts() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.addTombstone(kind: "hrRange", deviceId: "d1", startTs: 1000, endTs: 2000, sport: nil, day: nil, key: nil, editSeq: 8)
        try await store.insert(Streams(hr: [HRSample(ts: 1500, bpm: 60), HRSample(ts: 2500, bpm: 61)]), deviceId: "d1")
        let survivors = try await store.hrSamples(deviceId: "d1", from: 0, to: 10_000, limit: 10)
        XCTAssertEqual(survivors.map(\.ts), [2500])
    }
    func testDeleteHelpersAndMetricGuard() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(Streams(hr: [HRSample(ts: 1200, bpm: 60)]), deviceId: "d1")
        // Hoisted out of XCTAssertEqual's autoclosure: this toolchain rejects `await` inside it.
        let deletedHr = try await store.deleteHrRange(deviceId: "d1", fromTs: 1000, toTs: 2000)
        XCTAssertEqual(deletedHr, 1)
        _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-07-01", key: "ref_sleep_score", value: 80)], deviceId: "d1")
        try await store.addTombstone(kind: "metricPoint", deviceId: "d1", startTs: nil, endTs: nil, sport: nil, day: "2026-07-01", key: "ref_sleep_score", editSeq: 9)
        let deletedMetric = try await store.deleteMetricPoint(deviceId: "d1", day: "2026-07-01", key: "ref_sleep_score")
        XCTAssertEqual(deletedMetric, 1)
        let n = try await store.upsertMetricSeries([MetricPoint(day: "2026-07-01", key: "ref_sleep_score", value: 81)], deviceId: "d1")
        XCTAssertEqual(n, 0)   // guard drops the tombstoned point
    }
}
