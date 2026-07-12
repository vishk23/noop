// Compiled ONLY when the CLOUD_SYNC compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if CLOUD_SYNC
import Foundation
import WhoopStore

/// Outcome of applying one batch of `CloudEdit` journal rows to the local store.
///
/// `appliedSeqs` collects EVERY processed seq — applied, skipped, AND needsAttention alike, never
/// just the successful ones: the sync cursor must advance past whatever this device has SEEN, not
/// just what it acted on, or an edit this device can never act on (an unknown forward-compat kind, a
/// permanently malformed payload) would wedge the cursor forever. `needsAttention` is a SUBSET of
/// processed edits that made no store change and need a human look (see `CloudEditApplier`'s per-kind
/// rules below); it is reported separately so the sync status can say so, but its seq is still acked.
struct CloudApplySummary: Equatable {
    var applied = 0
    var skipped = 0
    var needsAttention = 0
    var touchedSleep = false
    var touchedWorkouts = false
    var touchedHr = false
    var appliedSeqs: [Int] = []
}

/// Applies confirmed noop-cloud edit-journal rows to the on-device `WhoopStore` through the SAME
/// recompute-safe entry points a human on-device correction uses — `applySleepEdit`/
/// `updateSleepStages` (which set `userEdited = 1`), never a raw UPDATE — so a later strap re-sync or
/// nightly recompute can't silently revert a cloud correction (`upsertSleepSessions`'s ON CONFLICT
/// preserves an edited row's bounds/stages exactly because that flag is set). Deletions pair a
/// physical DELETE with a `cloudTombstone` row (`CloudTombstoneStore`) so a later re-import/backfill
/// can't resurrect them either. Corrections/additions with no natural "my-whoop" identity (a
/// manually-added workout, a fixed workout's replacement copy) land under the synthetic
/// `"noop-cloud"` source, registered in the device registry once per batch, the first time it's
/// actually needed (mirrors `OuraSyncWriter.persist`'s step 0).
///
/// Never throws: a malformed payload, an unknown (forward-compat) kind, or a store-level failure are
/// all folded into the summary (`skipped`/`needsAttention`) rather than propagated — one bad journal
/// row must never abort the whole batch.
enum CloudEditApplier {
    /// The synthetic paired-device id every "no natural home" write (an add, a fix's replacement
    /// copy) lands under — distinct from any real strap/import source id.
    static let cloudDeviceId = "noop-cloud"

    static func apply(_ edits: [CloudEdit], store: WhoopStore) async -> CloudApplySummary {
        var summary = CloudApplySummary()
        var registeredCloudDevice = false

        for edit in edits.sorted(by: { $0.seq < $1.seq }) {
            // Every processed row is acked, whatever happened to it — see the type doc above.
            summary.appliedSeqs.append(edit.seq)

            // An undo marker, an edit some LATER row already undid, or the server-only baseline note
            // all need no on-device action.
            if edit.kind == "undo" || edit.undoneBySeq != nil || edit.kind == "set_baseline_note" {
                summary.skipped += 1
                continue
            }

            let payload = Data(edit.payloadJSON.utf8)
            switch edit.kind {
            case "adjust_sleep_bounds":
                await applyAdjustSleepBounds(payload, store: store, summary: &summary)
            case "edit_sleep_stages":
                await applyEditSleepStages(payload, store: store, summary: &summary)
            case "delete_workout":
                await applyDeleteWorkout(payload, seq: edit.seq, store: store, summary: &summary)
            case "fix_workout":
                await applyFixWorkout(payload, beforeJSON: edit.beforeJSON, seq: edit.seq, store: store,
                                       summary: &summary, registeredCloudDevice: &registeredCloudDevice)
            case "add_workout":
                await applyAddWorkout(payload, store: store, summary: &summary,
                                       registeredCloudDevice: &registeredCloudDevice)
            case "delete_hr_range":
                await applyDeleteHrRange(payload, seq: edit.seq, store: store, summary: &summary)
            case "delete_metric_point":
                await applyDeleteMetricPoint(payload, seq: edit.seq, store: store, summary: &summary)
            default:
                summary.skipped += 1   // unknown kind: forward-compat, not an error
            }
        }
        return summary
    }

    // MARK: - adjust_sleep_bounds

    private struct AdjustSleepBoundsPayload: Decodable {
        let deviceId: String
        let startTs: Int
        let newStartTs: Int?
        let newEndTs: Int?
    }

    private static func applyAdjustSleepBounds(_ data: Data, store: WhoopStore,
                                                summary: inout CloudApplySummary) async {
        guard let p = try? JSONDecoder().decode(AdjustSleepBoundsPayload.self, from: data) else {
            summary.skipped += 1
            return
        }
        do {
            guard let current = try await store.sleepSessions(deviceId: p.deviceId, from: p.startTs,
                                                                to: p.startTs, limit: 1).first else {
                summary.needsAttention += 1   // session absent — nothing to adjust
                return
            }
            _ = try await store.applySleepEdit(
                deviceId: p.deviceId, detectedStartTs: p.startTs,
                newStartTs: p.newStartTs ?? current.effectiveStartTs,
                newEndTs: p.newEndTs ?? current.endTs)
            summary.applied += 1
            summary.touchedSleep = true
        } catch {
            summary.needsAttention += 1
        }
    }

    // MARK: - edit_sleep_stages

    private struct SleepStagePayload: Decodable {
        let start: Int
        let end: Int
        let stage: String
    }

    private struct EditSleepStagesPayload: Decodable {
        let deviceId: String
        let startTs: Int
        let stages: [SleepStagePayload]
    }

    /// The noop-cloud server's stage vocabulary is "awake"/"light"/"deep"/"rem" (its `sleepStage` zod
    /// enum, `noop-cloud/src/edits/kinds.ts`). The on-device stagesJSON legend uses "wake" for the
    /// same concept — see `WearableSleepStageInterval`'s doc comment ("Normalized stage name written
    /// into the stage JSON: 'deep' / 'light' / 'rem' / 'wake'") and `SleepStagerV2`'s own
    /// `labels[i] == "awake" ? "wake" : labels[i]` conversion when it writes a detected session's
    /// stages. "light"/"deep"/"rem" already match verbatim; only "awake" needs remapping so a
    /// re-encoded edit reads identically to every other stage source (e.g.
    /// `WearableImporter.efficiency`'s `stage != "wake"` check, `WhoopCsvExporter`'s
    /// `("wake" == awake)` doc note).
    private static func mapServerStage(_ stage: String) -> String {
        stage == "awake" ? "wake" : stage
    }

    /// Re-encode to the on-device `[{start,end,stage}]` shape (same JSON layout `OuraSyncWriter`
    /// writes), mapping the stage vocabulary. nil for an empty list — a stage edit must carry at
    /// least one segment; an empty array is treated as a malformed payload upstream.
    private static func encodeStagesJSON(_ stages: [SleepStagePayload]) -> String? {
        guard !stages.isEmpty else { return nil }
        let segs = stages.map {
            ["start": $0.start, "end": $0.end, "stage": mapServerStage($0.stage)] as [String: Any]
        }
        return (try? JSONSerialization.data(withJSONObject: segs)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func applyEditSleepStages(_ data: Data, store: WhoopStore,
                                              summary: inout CloudApplySummary) async {
        guard let p = try? JSONDecoder().decode(EditSleepStagesPayload.self, from: data),
              let stagesJSON = encodeStagesJSON(p.stages) else {
            summary.skipped += 1
            return
        }
        do {
            guard let current = try await store.sleepSessions(deviceId: p.deviceId, from: p.startTs,
                                                                to: p.startTs, limit: 1).first else {
                summary.needsAttention += 1   // session absent — nothing to restage
                return
            }
            // updateSleepStages only touches userEdited=1 rows; promote first (CURRENT bounds,
            // stages left untouched by this call) so an un-edited night can still receive a stage
            // correction — see the brief's explicit two-step note.
            if !current.userEdited {
                _ = try await store.applySleepEdit(deviceId: p.deviceId, detectedStartTs: p.startTs,
                                                    newStartTs: current.effectiveStartTs,
                                                    newEndTs: current.endTs)
            }
            _ = try await store.updateSleepStages(deviceId: p.deviceId, detectedStartTs: p.startTs,
                                                   stagesJSON: stagesJSON)
            summary.applied += 1
            summary.touchedSleep = true
        } catch {
            summary.needsAttention += 1
        }
    }

    // MARK: - delete_workout

    private struct WorkoutKeyPayload: Decodable {
        let deviceId: String
        let startTs: Int
        let sport: String
    }

    private static func applyDeleteWorkout(_ data: Data, seq: Int, store: WhoopStore,
                                            summary: inout CloudApplySummary) async {
        guard let p = try? JSONDecoder().decode(WorkoutKeyPayload.self, from: data) else {
            summary.skipped += 1
            return
        }
        do {
            _ = try await store.deleteWorkouts(deviceId: p.deviceId, sport: p.sport, from: p.startTs, to: p.startTs)
            try await store.addTombstone(kind: "workout", deviceId: p.deviceId, startTs: p.startTs, endTs: nil,
                                          sport: p.sport, day: nil, key: nil, editSeq: seq)
            summary.applied += 1
            summary.touchedWorkouts = true
        } catch {
            summary.needsAttention += 1
        }
    }

    // MARK: - fix_workout

    private struct FixWorkoutPatch: Decodable {
        let sport: String?
        let startTs: Int?
        let endTs: Int?
        let energyKcal: Double?
        let distanceM: Double?
    }

    private struct FixWorkoutPayload: Decodable {
        let deviceId: String
        let startTs: Int
        let sport: String
        let patch: FixWorkoutPatch
    }

    /// Lenient snapshot of the server mirror's workout row (the `beforeJSON` the journal carries for
    /// `fix_workout`). Every field optional: the mirror's exact row shape isn't this applier's
    /// contract to enforce, and only `endTs` (when `patch` doesn't supply its own) is actually
    /// load-bearing — everything else has a sane fallback or is itself optional on `WorkoutRow`.
    private struct FixWorkoutBefore: Decodable {
        let source: String?
        let endTs: Int?
        let energyKcal: Double?
        let distanceM: Double?
    }

    private static func applyFixWorkout(_ data: Data, beforeJSON: String?, seq: Int, store: WhoopStore,
                                         summary: inout CloudApplySummary,
                                         registeredCloudDevice: inout Bool) async {
        guard let p = try? JSONDecoder().decode(FixWorkoutPayload.self, from: data) else {
            summary.skipped += 1
            return
        }
        guard let beforeJSON,
              let before = try? JSONDecoder().decode(FixWorkoutBefore.self, from: Data(beforeJSON.utf8)) else {
            summary.needsAttention += 1   // no server snapshot to reconstruct the corrected copy from
            return
        }
        let finalStartTs = p.patch.startTs ?? p.startTs
        guard let finalEndTs = p.patch.endTs ?? before.endTs else {
            summary.needsAttention += 1   // neither the patch nor the snapshot carries an end time
            return
        }
        do {
            _ = try await store.deleteWorkouts(deviceId: p.deviceId, sport: p.sport, from: p.startTs, to: p.startTs)
            try await store.addTombstone(kind: "workout", deviceId: p.deviceId, startTs: p.startTs, endTs: nil,
                                          sport: p.sport, day: nil, key: nil, editSeq: seq)

            try await registerCloudDeviceIfNeeded(store: store, registeredCloudDevice: &registeredCloudDevice)
            let corrected = WorkoutRow(
                startTs: finalStartTs, endTs: finalEndTs, sport: p.patch.sport ?? p.sport,
                source: before.source ?? "manual", durationS: Double(finalEndTs - finalStartTs),
                energyKcal: p.patch.energyKcal ?? before.energyKcal, avgHr: nil, maxHr: nil, strain: nil,
                distanceM: p.patch.distanceM ?? before.distanceM, zonesJSON: nil, notes: nil)
            _ = try await store.upsertWorkouts([corrected], deviceId: cloudDeviceId)

            summary.applied += 1
            summary.touchedWorkouts = true
        } catch {
            summary.needsAttention += 1
        }
    }

    // MARK: - add_workout

    private struct AddWorkoutPayload: Decodable {
        let startTs: Int
        let endTs: Int
        let sport: String
        let energyKcal: Double?
        let distanceM: Double?
        let notes: String?
    }

    private static func applyAddWorkout(_ data: Data, store: WhoopStore, summary: inout CloudApplySummary,
                                         registeredCloudDevice: inout Bool) async {
        guard let p = try? JSONDecoder().decode(AddWorkoutPayload.self, from: data) else {
            summary.skipped += 1
            return
        }
        do {
            try await registerCloudDeviceIfNeeded(store: store, registeredCloudDevice: &registeredCloudDevice)
            let row = WorkoutRow(startTs: p.startTs, endTs: p.endTs, sport: p.sport, source: "manual",
                                  durationS: Double(p.endTs - p.startTs), energyKcal: p.energyKcal,
                                  avgHr: nil, maxHr: nil, strain: nil, distanceM: p.distanceM,
                                  zonesJSON: nil, notes: p.notes)
            _ = try await store.upsertWorkouts([row], deviceId: cloudDeviceId)
            summary.applied += 1
            summary.touchedWorkouts = true
        } catch {
            summary.needsAttention += 1
        }
    }

    // MARK: - delete_hr_range

    private struct DeleteHrRangePayload: Decodable {
        let deviceId: String
        let fromTs: Int
        let toTs: Int
    }

    private static func applyDeleteHrRange(_ data: Data, seq: Int, store: WhoopStore,
                                            summary: inout CloudApplySummary) async {
        guard let p = try? JSONDecoder().decode(DeleteHrRangePayload.self, from: data) else {
            summary.skipped += 1
            return
        }
        do {
            _ = try await store.deleteHrRange(deviceId: p.deviceId, fromTs: p.fromTs, toTs: p.toTs)
            try await store.addTombstone(kind: "hrRange", deviceId: p.deviceId, startTs: p.fromTs, endTs: p.toTs,
                                          sport: nil, day: nil, key: nil, editSeq: seq)
            summary.applied += 1
            summary.touchedHr = true
        } catch {
            summary.needsAttention += 1
        }
    }

    // MARK: - delete_metric_point

    private struct DeleteMetricPointPayload: Decodable {
        let deviceId: String
        let day: String
        let key: String
    }

    private static func applyDeleteMetricPoint(_ data: Data, seq: Int, store: WhoopStore,
                                                summary: inout CloudApplySummary) async {
        guard let p = try? JSONDecoder().decode(DeleteMetricPointPayload.self, from: data) else {
            summary.skipped += 1
            return
        }
        do {
            _ = try await store.deleteMetricPoint(deviceId: p.deviceId, day: p.day, key: p.key)
            try await store.addTombstone(kind: "metricPoint", deviceId: p.deviceId, startTs: nil, endTs: nil,
                                          sport: nil, day: p.day, key: p.key, editSeq: seq)
            summary.applied += 1
            // No sleep/workouts/hr flag applies to a generic metric point.
        } catch {
            summary.needsAttention += 1
        }
    }

    // MARK: - noop-cloud device registration

    /// Registers the synthetic `"noop-cloud"` paired-device row the first time this batch actually
    /// writes under it — mirrors `OuraSyncWriter.persist`'s step 0. `DeviceRegistryStore.add` is an
    /// upsert (`ON CONFLICT(id) DO UPDATE`), so re-registering across separate batches/runs is
    /// harmless; `registeredCloudDevice` only avoids repeat writes WITHIN one `apply` call.
    private static func registerCloudDeviceIfNeeded(store: WhoopStore, registeredCloudDevice: inout Bool) async throws {
        guard !registeredCloudDevice else { return }
        let now = Int(Date().timeIntervalSince1970)
        let device = PairedDevice(id: cloudDeviceId, brand: cloudDeviceId, model: "Cloud edits",
                                   sourceKind: .cloudImport, capabilities: [], status: .paired,
                                   addedAt: now, lastSeenAt: now)
        try DeviceRegistryStore(dbQueue: store.registryWriter).add(device)
        registeredCloudDevice = true
    }
}
#endif // CLOUD_SYNC
