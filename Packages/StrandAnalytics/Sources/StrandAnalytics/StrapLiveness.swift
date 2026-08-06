import Foundation
import WhoopProtocol
import WhoopStore

/// Three-state strap liveness read off the strap's own `STRAP_CONDITION_REPORT(29)` heartbeat, crossed with
/// HR presence. INSTRUMENTATION ONLY — nothing scores this, and it never writes a stored metric.
///
/// WHY IT EXISTS. "No data for this window" currently collapses three different facts into one:
///
///   1. the strap was worn and collecting,
///   2. the strap was alive but OFF THE WRIST (so there is genuinely nothing to collect),
///   3. the strap was dead, out of range, or its buffer was never offloaded (data may still exist).
///
/// Only (3) is a reason to go looking for missing data; (2) is the correct absence of it. The heartbeat
/// separates them because it keeps beating when HR stops: across the 2026-08-01T22:53:30Z→08-02T01:40:18Z
/// off-wrist episode (167 min) the strap logged 16 reports and 1 HR sample, while across the
/// 2026-07-05→07-09 dead span (114 h 52 m) it logged 10 reports where the ~600 s cadence predicts ~689.
///
/// THE CADENCE IS ~600 s, NOT EXACTLY 600 s. Over a 39-day corpus (5,079 reports, 5,078 inter-arrivals)
/// 5,056 fell in 595–605 s, but only 1,766 were exactly 600. `binSeconds` is therefore 1.5× the cadence
/// rather than 1×, so ordinary jitter cannot make a live strap look silent: measured against that corpus,
/// 900 s bins misclassify 0.13 % of bins as `.silent` while HR is flowing, against 0.40 % at 600 s.
public enum StrapLiveness {

    /// The strap's own liveness report. Name matched by prefix — kinds are formatted "NAME(n)".
    public static let heartbeatKindPrefix = "STRAP_CONDITION_REPORT"

    /// Nominal heartbeat cadence in seconds, as observed on a WHOOP 5/MG.
    public static let heartbeatCadenceSeconds = 600

    /// Default bin width: 1.5× the cadence. See the type doc for the measurement behind the 1.5.
    public static let defaultBinSeconds = 900

    /// A bin counts as worn when HR covers at least this fraction of it. HR is nominally 1 Hz, so a worn bin
    /// carries ~`binSeconds` samples and coverage sits at ~1.0.
    ///
    /// WHY A FRACTION AND NOT "ANY HR AT ALL". Presence is far too weak a test. Across the real 167-minute
    /// off-wrist episode of 2026-08-01 the strap emitted exactly ONE HR sample in 10,008 s — under a
    /// presence rule that single stray sample flips the whole episode to `.collecting` and the state is
    /// worthless.
    ///
    /// WHY 0.10. Measured over the 39-day corpus, per-bin HR coverage is sharply bimodal: of 3,396 bins
    /// carrying a heartbeat, 3,370 (99.2 %) sit at ≥90 % coverage and 17 sit at <5 %, with **not one bin
    /// anywhere between 5 % and 20 %**. 0.10 is the middle of that empty gap, so the classification is
    /// insensitive to the exact value — any threshold in [0.05, 0.20) yields identical output on the corpus.
    public static let wornHRCoverage = 0.10

    public enum State: String, Sendable, CaseIterable {
        /// Heartbeat present AND HR covering at least `wornHRCoverage` of the bin — worn and collecting.
        case collecting
        /// Heartbeat present, HR essentially absent — the strap is alive and simply not on a wrist. An
        /// honest absence, not a gap to go hunting for.
        case aliveNotWorn
        /// No heartbeat — dead, out of range, or never offloaded. The only state worth investigating.
        case silent
    }

    public struct Bin: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public let state: State
        public let heartbeats: Int
        public let hrSamples: Int

        public init(start: Int, end: Int, state: State, heartbeats: Int, hrSamples: Int) {
            self.start = start; self.end = end; self.state = state
            self.heartbeats = heartbeats; self.hrSamples = hrSamples
        }
    }

    /// Bin `[windowStart, windowEnd)` and classify each bin. Bins are half-open, contiguous, and tile the
    /// window exactly, so their durations always sum to it.
    ///
    /// THE LAST BIN ABSORBS THE REMAINDER rather than being clipped short. A window is rarely a whole
    /// multiple of `binSeconds`, and a clipped tail bin is biased toward `.silent` for a purely arithmetic
    /// reason: a 108 s tail cannot be expected to contain a beat that arrives every ~600 s, so it reports a
    /// dead strap at the end of every otherwise-healthy window. Absorbing keeps every bin at least
    /// `binSeconds` wide, which is the property the 1.5×-cadence choice rests on. The final bin is therefore
    /// in `[binSeconds, 2 × binSeconds)`, and a window shorter than `binSeconds` is a single bin.
    ///
    /// Pure + deterministic. Inputs need not be sorted. Empty when the window is empty or inverted.
    public static func timeline(events: [WhoopEvent],
                                hr: [HRSample],
                                windowStart: Int,
                                windowEnd: Int,
                                binSeconds: Int = defaultBinSeconds) -> [Bin] {
        guard windowEnd > windowStart, binSeconds > 0 else { return [] }
        let beats = events.filter { $0.kind.hasPrefix(heartbeatKindPrefix) }.map { $0.ts }.sorted()
        // HR presence, not HR plausibility: this asks "did the strap emit anything here", which is a
        // different question from "is this beat usable". A bpm gate belongs in the analytics that score HR,
        // not in a liveness read — gating here would report a strap as not-worn during a stretch of
        // implausible-but-real emission, which is exactly the confusion this type exists to remove.
        let hrTs = hr.map { $0.ts }.sorted()

        var out: [Bin] = []
        var t = windowStart
        while t < windowEnd {
            // Absorb the remainder into this bin when what would follow is shorter than a full bin.
            let e = (windowEnd - (t + binSeconds)) < binSeconds ? windowEnd : t + binSeconds
            let h = countInRange(beats, from: t, to: e)
            let r = countInRange(hrTs, from: t, to: e)
            let coverage = Double(r) / Double(e - t)
            let state: State = h == 0 ? .silent : (coverage < wornHRCoverage ? .aliveNotWorn : .collecting)
            out.append(Bin(start: t, end: e, state: state, heartbeats: h, hrSamples: r))
            t = e
        }
        return out
    }

    /// Count of `sorted` in the half-open range `[from, to)`, by binary search on both edges.
    static func countInRange(_ sorted: [Int], from: Int, to: Int) -> Int {
        func lowerBound(_ v: Int) -> Int {
            var lo = 0, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sorted[mid] < v { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        guard to > from else { return 0 }
        return lowerBound(to) - lowerBound(from)
    }

    /// Rolled-up seconds per state over a timeline, plus the counts behind them, for a diagnostic line.
    public struct Summary: Equatable, Sendable {
        public let collectingSeconds: Int
        public let aliveNotWornSeconds: Int
        public let silentSeconds: Int
        public let heartbeats: Int
        public let bins: Int
        public let binSeconds: Int

        public var totalSeconds: Int { collectingSeconds + aliveNotWornSeconds + silentSeconds }

        /// Expected heartbeats if the strap had beaten at its nominal cadence for the whole window. The
        /// observed/expected ratio is what makes a dead span legible: the 114 h span read 10 vs ~689.
        public var expectedHeartbeats: Int { totalSeconds / heartbeatCadenceSeconds }

        public var summary: String {
            func hm(_ s: Int) -> String { String(format: "%dh%02dm", s / 3600, (s % 3600) / 60) }
            return "strap-liveness: bins=\(bins)×\(binSeconds)s "
                + "collecting=\(hm(collectingSeconds)) aliveNotWorn=\(hm(aliveNotWornSeconds)) "
                + "silent=\(hm(silentSeconds)); heartbeats=\(heartbeats)/\(expectedHeartbeats) expected "
                + "(~\(heartbeatCadenceSeconds)s cadence). Diagnostic only — nothing is scored from this."
        }
    }

    public static func summarize(_ bins: [Bin], binSeconds: Int = defaultBinSeconds) -> Summary {
        var c = 0, a = 0, s = 0, beats = 0
        for b in bins {
            let d = b.end - b.start
            switch b.state {
            case .collecting: c += d
            case .aliveNotWorn: a += d
            case .silent: s += d
            }
            beats += b.heartbeats
        }
        return Summary(collectingSeconds: c, aliveNotWornSeconds: a, silentSeconds: s,
                       heartbeats: beats, bins: bins.count, binSeconds: binSeconds)
    }
}
