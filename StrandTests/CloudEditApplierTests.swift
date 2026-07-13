// Tests the CLOUD_SYNC-gated journal → store applier; compiled only when the flag is set
// (StrandTests shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if CLOUD_SYNC
import XCTest
import WhoopStore
import WhoopProtocol
@testable import Strand

final class CloudEditApplierTests: XCTestCase {

    // MARK: - Fixture helpers

    private func json(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func edit(seq: Int, kind: String, payload: [String: Any], beforeJSON: String? = nil,
                       undoneBySeq: Int? = nil) -> CloudEdit {
        CloudEdit(seq: seq, editId: "e\(seq)", kind: kind, payloadJSON: json(payload), beforeJSON: beforeJSON,
                   rationale: nil, appliedAt: 1_752_300_000, undoneBySeq: undoneBySeq, ackedAt: nil)
    }

    // MARK: - adjust_sleep_bounds

    func testAdjustSleepBoundsSurvivesRecompute() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(startTs: 1000, endTs: 29000, efficiency: 90, restingHr: 50, avgHrv: 60, stagesJSON: nil),
        ], deviceId: "my-whoop")

        let e = edit(seq: 1, kind: "adjust_sleep_bounds",
                     payload: ["deviceId": "my-whoop", "startTs": 1000, "newEndTs": 30000])
        let summary = await CloudEditApplier.apply([e], store: store)

        XCTAssertEqual(summary.applied, 1)
        XCTAssertEqual(summary.skipped, 0)
        XCTAssertEqual(summary.needsAttention, 0)
        XCTAssertTrue(summary.touchedSleep)
        XCTAssertEqual(summary.appliedSeqs, [1])

        let edited = try await store.sleepSessions(deviceId: "my-whoop", from: 1000, to: 1000, limit: 1).first
        XCTAssertEqual(edited?.endTs, 30000)
        XCTAssertTrue(edited?.userEdited ?? false)

        // Recompute simulation: a later strap/import upsert tries to overwrite with DETECTED (un-edited)
        // values — the userEdited flag set by applySleepEdit must survive it.
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(startTs: 1000, endTs: 29000, efficiency: 91, restingHr: 51, avgHrv: 61, stagesJSON: nil),
        ], deviceId: "my-whoop")
        let survived = try await store.sleepSessions(deviceId: "my-whoop", from: 1000, to: 1000, limit: 1).first
        XCTAssertEqual(survived?.endTs, 30000, "userEdited protection must survive a recompute upsert")
        XCTAssertTrue(survived?.userEdited ?? false)
    }

    func testAdjustSleepBoundsNeedsAttentionWhenSessionAbsent() async throws {
        let store = try await WhoopStore.inMemory()
        let e = edit(seq: 5, kind: "adjust_sleep_bounds",
                     payload: ["deviceId": "my-whoop", "startTs": 9999, "newEndTs": 30000])
        let summary = await CloudEditApplier.apply([e], store: store)
        XCTAssertEqual(summary.applied, 0)
        XCTAssertEqual(summary.needsAttention, 1)
        XCTAssertEqual(summary.appliedSeqs, [5])
    }

    func testAdjustSleepBoundsRejectsInvertedWindow() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(startTs: 1000, endTs: 29000, efficiency: 90, restingHr: 50, avgHrv: 60, stagesJSON: nil),
        ], deviceId: "my-whoop")

        // newEndTs (500) is BEFORE the session's own startTs (1000) — an inverted window that
        // SleepEditGuard.clampedEditWindow (#940 belt-and-braces) must refuse outright, exactly as
        // Repository.editSleepTimes refuses one from a misbehaving client UI.
        let e = edit(seq: 17, kind: "adjust_sleep_bounds",
                     payload: ["deviceId": "my-whoop", "startTs": 1000, "newEndTs": 500])
        let summary = await CloudEditApplier.apply([e], store: store)

        XCTAssertEqual(summary.applied, 0)
        XCTAssertEqual(summary.needsAttention, 1, "an inverted window must be refused, not silently clamped")
        XCTAssertEqual(summary.appliedSeqs, [17])

        let untouched = try await store.sleepSessions(deviceId: "my-whoop", from: 1000, to: 1000, limit: 1).first
        XCTAssertEqual(untouched?.endTs, 29000, "a rejected edit must leave the stored bounds unchanged")
        XCTAssertFalse(untouched?.userEdited ?? true, "a rejected edit must not set userEdited")
    }

    // MARK: - edit_sleep_stages

    func testEditSleepStagesPromotesUnEditedRowAndMapsStageVocabulary() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(startTs: 2000, endTs: 5000, efficiency: 90, restingHr: 50, avgHrv: 60, stagesJSON: nil),
        ], deviceId: "my-whoop")
        let before = try await store.sleepSessions(deviceId: "my-whoop", from: 2000, to: 2000, limit: 1).first
        XCTAssertFalse(before?.userEdited ?? true, "fixture must start un-edited to exercise the promotion path")

        // Server vocabulary is "awake"/"light"/"deep"/"rem" — "awake" must map to the app's "wake" token.
        let stages: [[String: Any]] = [
            ["start": 2000, "end": 3000, "stage": "awake"],
            ["start": 3000, "end": 5000, "stage": "deep"],
        ]
        let e = edit(seq: 9, kind: "edit_sleep_stages",
                     payload: ["deviceId": "my-whoop", "startTs": 2000, "stages": stages])
        let summary = await CloudEditApplier.apply([e], store: store)

        XCTAssertEqual(summary.applied, 1)
        XCTAssertEqual(summary.needsAttention, 0)
        XCTAssertTrue(summary.touchedSleep)

        let after = try await store.sleepSessions(deviceId: "my-whoop", from: 2000, to: 2000, limit: 1).first
        XCTAssertTrue(after?.userEdited ?? false, "promotion must set userEdited")
        XCTAssertEqual(after?.endTs, 5000, "promotion must keep the CURRENT bounds, not reset them")

        let stagesJSON = try XCTUnwrap(after?.stagesJSON)
        let decodedAny = try JSONSerialization.jsonObject(with: Data(stagesJSON.utf8))
        let decoded = try XCTUnwrap(decodedAny as? [[String: Any]])
        XCTAssertEqual(decoded.first?["stage"] as? String, "wake", "server 'awake' must map to the app's 'wake' token")
        XCTAssertEqual(decoded.last?["stage"] as? String, "deep", "non-awake stages pass through verbatim")
    }

    func testEditSleepStagesNeedsAttentionWhenSessionAbsent() async throws {
        let store = try await WhoopStore.inMemory()
        let stages: [[String: Any]] = [["start": 2000, "end": 3000, "stage": "light"]]
        let e = edit(seq: 3, kind: "edit_sleep_stages",
                     payload: ["deviceId": "my-whoop", "startTs": 2000, "stages": stages])
        let summary = await CloudEditApplier.apply([e], store: store)
        XCTAssertEqual(summary.needsAttention, 1)
        XCTAssertEqual(summary.applied, 0)
    }

    func testEditSleepStagesPromotionRejectsInvertedCurrentBounds() async throws {
        let store = try await WhoopStore.inMemory()
        // Seed a corrupted (inverted) session directly via upsertSleepSessions, which does NOT route
        // through SleepEditGuard (only applySleepEdit does) — simulates a bad import/server mirror
        // reaching the store with bounds no on-device edit path could ever produce.
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(startTs: 5000, endTs: 4000, efficiency: 90, restingHr: 50, avgHrv: 60, stagesJSON: nil),
        ], deviceId: "my-whoop")
        let before = try await store.sleepSessions(deviceId: "my-whoop", from: 5000, to: 5000, limit: 1).first
        XCTAssertFalse(before?.userEdited ?? true, "fixture must start un-edited to exercise the promotion path")

        let stages: [[String: Any]] = [["start": 4000, "end": 5000, "stage": "light"]]
        let e = edit(seq: 18, kind: "edit_sleep_stages",
                     payload: ["deviceId": "my-whoop", "startTs": 5000, "stages": stages])
        let summary = await CloudEditApplier.apply([e], store: store)

        XCTAssertEqual(summary.needsAttention, 1, "promoting an inverted stored window must be refused")
        XCTAssertEqual(summary.applied, 0)

        let untouched = try await store.sleepSessions(deviceId: "my-whoop", from: 5000, to: 5000, limit: 1).first
        XCTAssertEqual(untouched?.endTs, 4000, "rejected promotion must leave stored bounds unchanged")
        XCTAssertFalse(untouched?.userEdited ?? true, "rejected promotion must not set userEdited")
    }

    // MARK: - delete_workout

    func testDeleteWorkoutTombstonesAndBlocksResurrection() async throws {
        let store = try await WhoopStore.inMemory()
        let workout = WorkoutRow(startTs: 100, endTs: 700, sport: "running", source: "whoop", durationS: 600,
                                  energyKcal: 400, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                                  zonesJSON: nil, notes: nil)
        _ = try await store.upsertWorkouts([workout], deviceId: "my-whoop")

        let e = edit(seq: 4, kind: "delete_workout", payload: ["deviceId": "my-whoop", "startTs": 100, "sport": "running"])
        let summary = await CloudEditApplier.apply([e], store: store)

        XCTAssertEqual(summary.applied, 1)
        XCTAssertTrue(summary.touchedWorkouts)
        let remaining = try await store.workouts(deviceId: "my-whoop", from: 0, to: 1000, limit: 10)
        XCTAssertEqual(remaining.count, 0)

        // Resurrection guard: a later re-import of the exact same workout must be dropped.
        let resurrected = try await store.upsertWorkouts([workout], deviceId: "my-whoop")
        XCTAssertEqual(resurrected, 0)
    }

    // MARK: - fix_workout

    func testFixWorkoutTombstonesOriginalAndUpsertsCloudCopy() async throws {
        let store = try await WhoopStore.inMemory()
        let original = WorkoutRow(startTs: 100, endTs: 700, sport: "running", source: "whoop", durationS: 600,
                                   energyKcal: 400, avgHr: 140, maxHr: 170, strain: 8.5, distanceM: 5000,
                                   zonesJSON: nil, notes: nil)
        _ = try await store.upsertWorkouts([original], deviceId: "my-whoop")

        let beforeJSON = json(["deviceId": "my-whoop", "startTs": 100, "endTs": 700, "sport": "running",
                                "source": "whoop", "durationS": 600, "energyKcal": 400, "distanceM": 5000])
        let e = edit(seq: 6, kind: "fix_workout",
                     payload: ["deviceId": "my-whoop", "startTs": 100, "sport": "running",
                               "patch": ["energyKcal": 450]],
                     beforeJSON: beforeJSON)
        let summary = await CloudEditApplier.apply([e], store: store)

        XCTAssertEqual(summary.applied, 1)
        XCTAssertTrue(summary.touchedWorkouts)

        let originalGone = try await store.workouts(deviceId: "my-whoop", from: 0, to: 1000, limit: 10)
        XCTAssertEqual(originalGone.count, 0)
        let tombstones = try await store.workoutTombstones(deviceId: "my-whoop")
        XCTAssertEqual(tombstones.count, 1)

        let copies = try await store.workouts(deviceId: "noop-cloud", from: 0, to: 1000, limit: 10)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(copies.first?.energyKcal, 450, "patch overlay must win over the snapshot")
        XCTAssertEqual(copies.first?.distanceM, 5000, "un-patched fields carry over from the snapshot")
        XCTAssertEqual(copies.first?.source, "whoop", "original detection source carries over")

        let devices = try DeviceRegistryStore(dbQueue: store.registryWriter).all()
        let cloudDevice = devices.first { $0.id == "noop-cloud" }
        XCTAssertEqual(cloudDevice?.brand, "noop-cloud")
        XCTAssertEqual(cloudDevice?.model, "Cloud edits")
        XCTAssertEqual(cloudDevice?.sourceKind, .cloudImport)
        XCTAssertEqual(cloudDevice?.status, .paired)
    }

    func testFixWorkoutNeedsAttentionWhenBeforeJSONMissing() async throws {
        let store = try await WhoopStore.inMemory()
        let e = edit(seq: 7, kind: "fix_workout",
                     payload: ["deviceId": "my-whoop", "startTs": 100, "sport": "running",
                               "patch": ["energyKcal": 450]])
        let summary = await CloudEditApplier.apply([e], store: store)
        XCTAssertEqual(summary.needsAttention, 1)
        XCTAssertEqual(summary.applied, 0)
    }

    func testFixWorkoutNeedsAttentionWhenNoUsableEndTs() async throws {
        // beforeJSON IS present (unlike testFixWorkoutNeedsAttentionWhenBeforeJSONMissing above) but
        // carries no endTs, and the patch doesn't supply one either — the previously-untested branch
        // of the `finalEndTs` guard.
        let store = try await WhoopStore.inMemory()
        let beforeJSON = json(["deviceId": "my-whoop", "startTs": 100, "sport": "running", "source": "whoop"])
        let e = edit(seq: 15, kind: "fix_workout",
                     payload: ["deviceId": "my-whoop", "startTs": 100, "sport": "running",
                               "patch": ["energyKcal": 450]],
                     beforeJSON: beforeJSON)
        let summary = await CloudEditApplier.apply([e], store: store)
        XCTAssertEqual(summary.needsAttention, 1)
        XCTAssertEqual(summary.applied, 0)
        XCTAssertEqual(summary.skipped, 0)
    }

    func testFixWorkoutSkippedWhenSameBatchDeleteAlreadyWon() async throws {
        // delete_workout(seq1) then fix_workout(seq2) targeting the SAME (deviceId, startTs, sport) in
        // one batch: the delete must win outright — the fix must not resurrect a noop-cloud copy of a
        // workout the same batch just deleted.
        let store = try await WhoopStore.inMemory()
        let workout = WorkoutRow(startTs: 100, endTs: 700, sport: "running", source: "whoop", durationS: 600,
                                  energyKcal: 400, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                                  zonesJSON: nil, notes: nil)
        _ = try await store.upsertWorkouts([workout], deviceId: "my-whoop")

        let beforeJSON = json(["deviceId": "my-whoop", "startTs": 100, "endTs": 700, "sport": "running",
                                "source": "whoop", "durationS": 600, "energyKcal": 400, "distanceM": 5000])
        let edits = [
            edit(seq: 1, kind: "delete_workout", payload: ["deviceId": "my-whoop", "startTs": 100, "sport": "running"]),
            edit(seq: 2, kind: "fix_workout",
                 payload: ["deviceId": "my-whoop", "startTs": 100, "sport": "running", "patch": ["energyKcal": 450]],
                 beforeJSON: beforeJSON),
        ]
        let summary = await CloudEditApplier.apply(edits, store: store)

        XCTAssertEqual(summary.applied, 1, "only the delete applies")
        XCTAssertEqual(summary.skipped, 1, "the same-batch fix must be skipped, not applied")
        XCTAssertEqual(summary.needsAttention, 0)
        XCTAssertEqual(summary.appliedSeqs, [1, 2])

        let copies = try await store.workouts(deviceId: "noop-cloud", from: 0, to: 1000, limit: 10)
        XCTAssertEqual(copies.count, 0, "the delete already won — fix must not resurrect a noop-cloud copy")
        let originalGone = try await store.workouts(deviceId: "my-whoop", from: 0, to: 1000, limit: 10)
        XCTAssertEqual(originalGone.count, 0)
    }

    func testFixWorkoutNeedsAttentionWhenOriginalAbsentWithNoTombstone() async throws {
        // The original is gone but there is no tombstone for it (no same-batch delete either) — a
        // stale server mirror, not a resolved delete. This must surface for a human look, not silently
        // fabricate a noop-cloud copy of a workout the store never actually held.
        let store = try await WhoopStore.inMemory()
        let beforeJSON = json(["deviceId": "my-whoop", "startTs": 100, "endTs": 700, "sport": "running",
                                "source": "whoop", "durationS": 600, "energyKcal": 400, "distanceM": 5000])
        let e = edit(seq: 16, kind: "fix_workout",
                     payload: ["deviceId": "my-whoop", "startTs": 100, "sport": "running",
                               "patch": ["energyKcal": 450]],
                     beforeJSON: beforeJSON)
        let summary = await CloudEditApplier.apply([e], store: store)

        XCTAssertEqual(summary.needsAttention, 1)
        XCTAssertEqual(summary.applied, 0)
        XCTAssertEqual(summary.skipped, 0)
        let copies = try await store.workouts(deviceId: "noop-cloud", from: 0, to: 1000, limit: 10)
        XCTAssertEqual(copies.count, 0, "no noop-cloud copy must be created for a stale server mirror")
    }

    // MARK: - add_workout

    func testAddWorkoutUpsertsUnderCloudDevice() async throws {
        let store = try await WhoopStore.inMemory()
        let e = edit(seq: 8, kind: "add_workout",
                     payload: ["startTs": 1000, "endTs": 2800, "sport": "cycling", "energyKcal": 300,
                               "notes": "morning ride"])
        let summary = await CloudEditApplier.apply([e], store: store)

        XCTAssertEqual(summary.applied, 1)
        XCTAssertTrue(summary.touchedWorkouts)
        let added = try await store.workouts(deviceId: "noop-cloud", from: 0, to: 3000, limit: 10)
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.durationS, 1800, "durationS must be derived as endTs - startTs")
        XCTAssertEqual(added.first?.sport, "cycling")
        XCTAssertEqual(added.first?.notes, "morning ride")
    }

    // MARK: - delete_hr_range

    func testDeleteHrRangeTombstonesAndBlocksResurrection() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(Streams(hr: [HRSample(ts: 1500, bpm: 60), HRSample(ts: 2500, bpm: 61)]), deviceId: "my-whoop")

        let e = edit(seq: 10, kind: "delete_hr_range", payload: ["deviceId": "my-whoop", "fromTs": 1000, "toTs": 2000])
        let summary = await CloudEditApplier.apply([e], store: store)

        XCTAssertEqual(summary.applied, 1)
        XCTAssertTrue(summary.touchedHr)
        let survivors = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: 10_000, limit: 10)
        XCTAssertEqual(survivors.map(\.ts), [2500])

        // Resurrection guard: re-streaming into the deleted range must be filtered.
        try await store.insert(Streams(hr: [HRSample(ts: 1500, bpm: 60)]), deviceId: "my-whoop")
        let stillGone = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: 10_000, limit: 10)
        XCTAssertEqual(stillGone.map(\.ts), [2500])
    }

    // MARK: - delete_metric_point

    func testDeleteMetricPointTombstonesAndBlocksResurrection() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-07-01", key: "vo2max", value: 44)], deviceId: "my-whoop")

        let e = edit(seq: 11, kind: "delete_metric_point",
                     payload: ["deviceId": "my-whoop", "day": "2026-07-01", "key": "vo2max"])
        let summary = await CloudEditApplier.apply([e], store: store)

        XCTAssertEqual(summary.applied, 1)
        XCTAssertFalse(summary.touchedSleep)
        XCTAssertFalse(summary.touchedWorkouts)
        XCTAssertFalse(summary.touchedHr)

        let remaining = try await store.metricSeries(deviceId: "my-whoop", key: "vo2max", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(remaining.count, 0)

        let resurrected = try await store.upsertMetricSeries([MetricPoint(day: "2026-07-01", key: "vo2max", value: 45)], deviceId: "my-whoop")
        XCTAssertEqual(resurrected, 0)
    }

    // MARK: - Skip rules

    func testMalformedPayloadSkipsWithoutThrowing() async throws {
        let store = try await WhoopStore.inMemory()
        let e = CloudEdit(seq: 12, editId: "bad", kind: "adjust_sleep_bounds", payloadJSON: "not json at all",
                           beforeJSON: nil, rationale: nil, appliedAt: 1_752_300_000, undoneBySeq: nil, ackedAt: nil)
        let summary = await CloudEditApplier.apply([e], store: store)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(summary.applied, 0)
        XCTAssertEqual(summary.needsAttention, 0)
        XCTAssertEqual(summary.appliedSeqs, [12], "a malformed row is still acked so the cursor can advance")
    }

    func testUndoneRowSkipped() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(startTs: 1000, endTs: 29000, efficiency: 90, restingHr: 50, avgHrv: 60, stagesJSON: nil),
        ], deviceId: "my-whoop")
        let e = edit(seq: 13, kind: "adjust_sleep_bounds",
                     payload: ["deviceId": "my-whoop", "startTs": 1000, "newEndTs": 99999], undoneBySeq: 14)
        let summary = await CloudEditApplier.apply([e], store: store)

        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(summary.applied, 0)
        let untouched = try await store.sleepSessions(deviceId: "my-whoop", from: 1000, to: 1000, limit: 1).first
        XCTAssertEqual(untouched?.endTs, 29000, "an edit undone by a later row must never be applied")
    }

    func testUndoAndSetBaselineNoteAndUnknownKindAllSkip() async throws {
        let store = try await WhoopStore.inMemory()
        let edits = [
            CloudEdit(seq: 20, editId: "u1", kind: "undo", payloadJSON: #"{"targetSeq":1}"#, beforeJSON: nil,
                      rationale: nil, appliedAt: 1, undoneBySeq: nil, ackedAt: nil),
            edit(seq: 21, kind: "set_baseline_note", payload: ["note": "felt great"]),
            edit(seq: 22, kind: "some_future_kind", payload: [:]),
        ]
        let summary = await CloudEditApplier.apply(edits, store: store)
        XCTAssertEqual(summary.skipped, 3)
        XCTAssertEqual(summary.applied, 0)
        XCTAssertEqual(summary.appliedSeqs, [20, 21, 22])
    }

    // MARK: - Ordering / summary bookkeeping

    func testProcessesInSeqOrderRegardlessOfArrayOrder() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(startTs: 1000, endTs: 29000, efficiency: 90, restingHr: 50, avgHrv: 60, stagesJSON: nil),
        ], deviceId: "my-whoop")
        // Fed out of array order (seq 2 before seq 1) — the HIGHER seq must win, proving the internal sort.
        let edits = [
            edit(seq: 2, kind: "adjust_sleep_bounds", payload: ["deviceId": "my-whoop", "startTs": 1000, "newEndTs": 40000]),
            edit(seq: 1, kind: "adjust_sleep_bounds", payload: ["deviceId": "my-whoop", "startTs": 1000, "newEndTs": 30000]),
        ]
        let summary = await CloudEditApplier.apply(edits, store: store)
        XCTAssertEqual(summary.applied, 2)
        XCTAssertEqual(summary.appliedSeqs, [1, 2], "appliedSeqs must reflect seq order, not array order")

        let finalState = try await store.sleepSessions(deviceId: "my-whoop", from: 1000, to: 1000, limit: 1).first
        XCTAssertEqual(finalState?.endTs, 40000, "the higher-seq edit, applied last, must win")
    }
}
#endif // CLOUD_SYNC
