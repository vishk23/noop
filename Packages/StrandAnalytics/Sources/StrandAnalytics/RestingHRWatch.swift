import Foundation

// RestingHRWatch.swift — the SINGLE-SIGNAL resting-HR tier of the illness heads-up. Pure,
// deterministic, DB-free. Mirrors the Kotlin twin exactly.
//
// WHY THIS EXISTS ALONGSIDE `IllnessSignalEngine`
//
// `IllnessSignalEngine` is the CORROBORATED tier: four signals, a ≥2-signal corroboration gate, a
// Winsorized-EWMA personal baseline, a spread-relative z ≥ 2.0 threshold, and no temporal state. That
// shape is deliberately conservative and it is kept — but it is measurably slow, and on a short history
// it is silent. Three properties make it so:
//
//   1. It needs a TRUSTED baseline (14 valid nights inside a window that already drops the 3 most recent
//      days), so ~17 nights of history must accumulate before it may raise at all.
//   2. Corroboration means a lone, unambiguous signal cannot raise on its own.
//   3. Its EWMA spread widens as an anomaly folds into it (`Baselines.update` tracks the spread against
//      the UNCLAMPED value), so a SUSTAINED multi-day elevation progressively suppresses its own z — the
//      longer you stay ill, the weaker the evidence looks.
//
// This tier is the published NightSignal-shaped complement, and it makes the opposite choice on every
// axis: ONE signal (overnight resting HR), a STREAMING MEDIAN baseline (immune to (3) — a median does not
// widen when an outlier lands), an ABSOLUTE bpm threshold rather than a spread-relative one, and explicit
// TEMPORAL PERSISTENCE (two consecutive elevated nights) doing the false-positive suppression that
// corroboration does in the other tier. It reaches a verdict on ~9 nights of history instead of ~17.
//
// It NEVER replaces the corroborated tier and never downgrades it: a caller runs both and takes the
// louder verdict. Two independent shapes agreeing is stronger evidence than either alone; either one
// firing is enough to say "look at this".
//
// STRICTLY ONE-SIDED. Only an ELEVATED resting HR can fire. A resting HR well BELOW the personal median
// is the healthy direction (a well-rested, well-trained night) and must never raise — the same asymmetry
// the corroborated tier gets from orienting every z illness-ward.
//
// SAME-DEVICE-ERA INPUT IS THE CALLER'S CONTRACT. The absolute bpm threshold is only meaningful within
// one device's measurement scale; a brand switch shifts resting HR by a device-dependent offset that is
// indistinguishable from a real elevation. Callers must pass one era's nights (see
// `Baselines.deviceEraEpoch`).
//
// WELLNESS ONLY — APPROXIMATE, NOT A DIAGNOSIS. Never names a condition.
public enum RestingHRWatch {

    // MARK: - Tuning constants (pinned by test; mirror the Kotlin twin exactly)

    /// Absolute elevation over the personal streaming median that counts a night as elevated. An
    /// ABSOLUTE bpm offset, not a spread-relative z — that is the whole point of this tier.
    public static let offsetBPM: Double = 4.0
    /// How many prior nights the streaming median is taken over.
    public static let medianWindowNights: Int = 20
    /// Minimum prior nights with a value before a median is trustworthy enough to compare against.
    /// Deliberately far below the corroborated tier's ~17 — this is the cold-start tier.
    public static let minHistoryNights: Int = 7
    /// Consecutive elevated nights required to raise. This is the false-positive suppressor: a single
    /// hard workout, a late meal or one poor night reads as elevated, but rarely twice running.
    public static let persistenceNights: Int = 2

    // MARK: - Output

    public enum Level: String, Equatable, Sendable, Codable {
        case quiet     // not enough history, or the most recent nights are not consistently elevated
        case raised    // `persistenceNights` consecutive elevated nights
    }

    public struct Result: Equatable, Sendable {
        public let level: Level
        /// Most recent night's bpm over the streaming median (may be negative — reported, never fires).
        public let deltaBPM: Double?
        /// The streaming median the most recent night was compared against.
        public let medianBPM: Double?
        /// How many consecutive elevated nights end the series (0 when the last night is not elevated).
        public let consecutiveElevatedNights: Int

        public init(level: Level, deltaBPM: Double?, medianBPM: Double?,
                    consecutiveElevatedNights: Int) {
            self.level = level
            self.deltaBPM = deltaBPM
            self.medianBPM = medianBPM
            self.consecutiveElevatedNights = consecutiveElevatedNights
        }
    }

    // MARK: - Evaluate

    /// Evaluate the most recent night of `nightlyRHR` (ordered OLDEST→NEWEST; `nil` = a night with no
    /// reading, which is skipped rather than treated as zero).
    ///
    /// A night is ELEVATED when its value is at least `offsetBPM` over the median of the up-to
    /// `medianWindowNights` valued nights BEFORE it (that night itself excluded, so an elevation never
    /// props up its own baseline). Raises when the last `persistenceNights` valued nights are all
    /// elevated.
    public static func evaluate(_ nightlyRHR: [Double?]) -> Result {
        // Index the valued nights so missing nights neither break a run nor pad the median window.
        let valued: [(index: Int, value: Double)] = nightlyRHR.enumerated().compactMap { i, v in
            v.map { (index: i, value: $0) }
        }
        guard let last = valued.last else {
            return Result(level: .quiet, deltaBPM: nil, medianBPM: nil, consecutiveElevatedNights: 0)
        }

        /// Median of the up-to-`medianWindowNights` valued nights strictly BEFORE position `pos` in
        /// `valued`, or nil when there are fewer than `minHistoryNights` of them.
        func medianBefore(_ pos: Int) -> Double? {
            let lo = max(0, pos - medianWindowNights)
            let window = valued[lo..<pos].map(\.value)
            guard window.count >= minHistoryNights else { return nil }
            let sorted = window.sorted()
            let mid = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
        }

        /// True when the valued night at `pos` sits at least `offsetBPM` over its own prior median.
        /// ONE-SIDED by construction: a value below the median can never satisfy `>=  +offset`.
        func isElevated(_ pos: Int) -> Bool {
            guard let med = medianBefore(pos) else { return false }
            return valued[pos].value - med >= offsetBPM
        }

        let lastPos = valued.count - 1
        let median = medianBefore(lastPos)
        let delta = median.map { last.value - $0 }

        // Count the consecutive elevated run ending at the most recent valued night.
        var streak = 0
        var pos = lastPos
        while pos >= 0, isElevated(pos) {
            streak += 1
            pos -= 1
        }

        let level: Level = streak >= persistenceNights ? .raised : .quiet
        return Result(level: level, deltaBPM: delta, medianBPM: median,
                      consecutiveElevatedNights: streak)
    }

    /// Non-clinical copy for a raised verdict, matching the corroborated tier's register (never names a
    /// condition, always carries the not-a-diagnosis tail).
    public static func copy(for result: Result) -> String? {
        guard result.level == .raised, let delta = result.deltaBPM else { return nil }
        let rounded = Int(delta.rounded())
        return "Heads-up - your resting heart rate has been about \(rounded) bpm above your usual for "
            + "\(result.consecutiveElevatedNights) nights running. Consider taking it easy. "
            + IllnessSignalEngine.disclaimerTail
    }
}
