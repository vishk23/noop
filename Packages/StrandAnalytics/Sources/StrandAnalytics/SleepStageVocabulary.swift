import Foundation

/// The stage-label vocabulary of a `[StageSegment]` hypnogram, and the one place that folds wake's two
/// spellings together.
///
/// `sleepSession.stagesJSON` has more than one producer, and they do NOT agree on how to spell wake:
///
///   • `SleepStager` / `SleepStagerV2` (on device)  → `"wake"`  (V2 renames its internal `"awake"` on the
///     way out — see `SleepStagerV2.stageSegments`)
///   • `OuraHypnogram.decode`                       → `"wake"`
///   • `FitbitExportParser`                         → `"wake"`
///   • the noop-cloud server's `sleepStage` enum    → `"awake"` — normalized to `"wake"` on arrival by
///     `CloudEditApplier.mapServerStage`, so a cloud stage edit lands on device in the device spelling
///
/// So a database written by the app carries `"wake"`, but the SAME night read back from the cloud mirror
/// carries `"awake"`, and `SleepStageTotals`' own doc puts it plainly: "the on-device stager calls awake
/// `wake`; the importer `awake`". Any code that compares a stage against a bare `"wake"` literal is
/// therefore correct only for whichever producer it happened to be written against, and silently
/// misclassifies the other — counting wake as SLEEP, which biases wake down and sleep up.
///
/// Consumers that already fold the two spellings, each with its own copy of the rule: `SleepStageTotals`
/// and `HealthWriteback` (Swift), `SleepStageTotals.kt` and `canonicalStage` in `SleepStageTimelineLogic.kt`
/// (Kotlin). This type is the shared definition for new callers.
///
/// NOTE — deliberately NOT retrofitted onto `SleepStageTotals.minutes` / `HealthWriteback`. Those match
/// exactly (`case "wake", "awake":`), their Kotlin twins match exactly too, and the minutes they produce
/// are stored and cross the `.noopbak` boundary. Folding case there would start counting a `"Wake"` that
/// today falls through to `default` and contributes nothing — a silent change to stored values on one
/// platform only. Leave them exact-match unless the Kotlin twin moves in the same PR.
///
/// Mirrors Kotlin `canonicalStage` (`SleepStageTimelineLogic.kt`) in intent, but canonicalises to the
/// OPPOSITE token: Kotlin folds `"wake"` → `"awake"` for UI row-keying, Swift folds `"awake"` → `"wake"`
/// because `"wake"` is what `StageSegment` is documented to carry and what every Swift writer emits. The
/// canonical token is never stored or hashed on either side, so the two may differ; do not "fix" this into
/// agreement without checking every caller.
public enum SleepStageVocabulary {

    /// The closed set of canonical stage labels a hypnogram may use. A token outside this set is a decode
    /// bug or a new producer, not a stage — callers that classify by "everything that is not wake is sleep"
    /// are only sound while this set holds, so it is asserted in tests rather than left implicit.
    public static let canonicalStages: Set<String> = ["wake", "light", "deep", "rem"]

    /// The canonical spelling of `raw`: trimmed, lowercased, with `"awake"` folded to `"wake"`.
    ///
    /// Case folding is intentional here (this is a comparison helper, not a stored value) so a hand-built
    /// or hand-edited hypnogram spelling it `"Awake"` cannot slip through as sleep. A label that is neither
    /// spelling of wake is returned trimmed + lowercased and otherwise unchanged, so an unrecognised token
    /// stays visible to the caller instead of being coerced into a stage it is not.
    public static func canonical(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s == "awake" ? "wake" : s
    }

    /// Whether `raw` is wake, in either spelling and any case. The replacement for a bare `== "wake"`.
    public static func isWake(_ raw: String) -> Bool { canonical(raw) == "wake" }
}
