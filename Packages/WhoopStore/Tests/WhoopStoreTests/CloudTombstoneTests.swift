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

    // Finding 1: LabMarkerStore.reprojectCells wrote metricSeries directly, bypassing the
    // metricPoint tombstone guard every other writer (upsertMetricSeries) respects. A lab-marker
    // upsert that reprojects a tombstoned (day, key) cell must NOT resurrect it.
    func testLabMarkerReprojectionRespectsMetricPointTombstone() async throws {
        let store = try await WhoopStore.inMemory()
        // The lab-book projection always lands under the constant `labBookSourceId`, not the
        // marker's own deviceId (see LabMarkerStore) — the tombstone must be recorded against that
        // same id to guard the cell that reprojectCells actually writes.
        try await store.addTombstone(kind: "metricPoint", deviceId: WhoopStore.labBookSourceId,
                                      startTs: nil, endTs: nil, sport: nil,
                                      day: "2026-01-10", key: "ldl", editSeq: 11)
        // Upserting a numeric reading for that exact (day, key) triggers reprojectCells — the guard
        // must drop the cell instead of resurrecting it into metricSeries.
        _ = try await store.upsertLabMarkers([
            LabMarkerRow(id: "a", deviceId: "my-whoop", markerKey: "ldl", category: "bloodPanel",
                         day: "2026-01-10", takenAt: 1_736_500_000, value: 3.4, valueText: nil,
                         unit: "mmol/L", source: "manual", note: nil, referenceText: nil),
        ])
        let proj = try await store.metricSeries(deviceId: WhoopStore.labBookSourceId,
                                                key: "ldl", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(proj.count, 0, "tombstoned cell must stay absent from metricSeries")
        // The marker row itself is untouched — only the metricSeries projection is guarded.
        let markers = try await store.labMarkers(deviceId: "my-whoop", markerKey: "ldl")
        XCTAssertEqual(markers.count, 1)
    }

    // Finding 2: cloudTombstone must survive "Delete this device's data" (DeviceRegistryStore
    // .deleteAllData, reachable from DevicesView's keep-paired wipe) or the guard's memory is erased
    // and a later BLE backfill/cloud re-sync can resurrect data the user deleted on the cloud side.
    func testDeviceDataWipePreservesTombstoneUntilExplicitlyDeleted() async throws {
        let store = try await WhoopStore.inMemory()
        let workout = WorkoutRow(startTs: 100, endTs: 200, sport: "running", source: "whoop",
                                  durationS: 100, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                                  distanceM: nil, zonesJSON: nil, notes: nil)
        _ = try await store.upsertWorkouts([workout], deviceId: "d1")
        try await store.addTombstone(kind: "workout", deviceId: "d1", startTs: 100, endTs: nil,
                                      sport: "running", day: nil, key: nil, editSeq: 21)

        try await store.deleteAllData(deviceId: "d1")

        let workoutsAfterWipe = try await store.workouts(deviceId: "d1", from: 0, to: 1000, limit: 10)
        XCTAssertEqual(workoutsAfterWipe.count, 0, "device-data wipe clears the workout")
        let tombstonesAfterWipe = try await store.workoutTombstones(deviceId: "d1")
        XCTAssertEqual(tombstonesAfterWipe.count, 1, "device-data wipe must NOT erase the tombstone")

        // A later re-sync/backfill re-importing the same workout must still be blocked.
        let resurrected = try await store.upsertWorkouts([workout], deviceId: "d1")
        XCTAssertEqual(resurrected, 0, "tombstone still blocks resurrection after a device-data wipe")

        // A dedicated full-disconnect flow (not deleteAllData) can forget the tombstone.
        let deletedCount = try await store.deleteCloudTombstones(deviceId: "d1")
        XCTAssertEqual(deletedCount, 1)
        let tombstonesAfterDelete = try await store.workoutTombstones(deviceId: "d1")
        XCTAssertEqual(tombstonesAfterDelete.count, 0)
    }
}
