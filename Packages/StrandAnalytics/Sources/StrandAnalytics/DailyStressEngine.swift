import Foundation
import WhoopStore

/// Daily autonomic-stress score (0–3) from overnight resting HRV + resting HR, redesigned around the
/// sports-science / wearable-HRV literature (Plews, Buchheit 2014, Altini, Hopkins) rather than a naive
/// mean+SD on raw milliseconds. Pure, deterministic, DB-free.
///
/// Four evidence-backed departures from the old inline `StressMath`:
///  1. **Log domain.** HRV (RMSSD) is right-skewed; a symmetric z on raw ms is statistically invalid and
///     outlier-dominated. Everything here z-scores lnRMSSD (Plews/Altini; WHOOP does the same).
///  2. **Dual baselines.** A SHORT (14-night) adaptive baseline drives today's 0–3, so a sustained shift
///     (a supplement, a training block, altitude) is absorbed into "my recent normal" within ~2 weeks and
///     the daily number self-normalizes instead of reading "high stress" forever. A LONG (60-night)
///     reference powers a SEPARATE `ChronicShift` readout — "your baseline itself has moved down N% for D
///     days" — so the sustained load stays visible instead of being silently defined away. Neither Oura
///     nor WHOOP publicly does this; it is the only clean resolution of the adapt-vs-hide tradeoff.
///  3. **Coupled RHR+HRV (Buchheit 2014 quadrant).** Low HRV is only "stress" when RHR is ALSO elevated
///     above its own baseline (sympathetic overactivity). Low HRV with LOW RHR is benign parasympathetic
///     saturation (fit / deeply relaxed), not stress — so the HRV penalty is damped there, the exact
///     mirror of the RecoveryScorer's parasympathetic-saturation guard. HRV is the primary weight; RHR
///     confirms. This is what stops a saturated fit night (or a low-HRV-but-calm night) reading as stress.
///  4. **Smallest-worthwhile-change dead-zone.** A combined deviation under 0.5σ (Hopkins SWC) reads as
///     noise, not stress, so sub-threshold wobble doesn't jitter the daily number.
///
/// Honest by construction: HRV suppression is *sensitive but not specific* (Altini 2021, n≈9M) — the
/// physiology cannot name the cause (stress vs supplement vs training vs illness). This engine therefore
/// scores the autonomic STATE truthfully and surfaces context (quadrant + chronic shift) rather than
/// pretending to diagnose why. Not medical advice.
public enum DailyStressEngine {

    // MARK: - Tunables (named + auditable; grounded in the design doc / cited literature)

    /// Short adaptive baseline (nights) — drives today's 0–3. 14 sits in the literature's 7–14d "acute"
    /// range (ithlete/Plews 7d; a touch longer here to steady a noisy nocturnal wearable signal).
    public static let shortWindowDays = 14
    /// Long chronic reference (nights) — powers the sustained-shift readout. 60 matches HRV4Training's
    /// normal-values window.
    public static let longWindowDays = 60
    /// Minimum baseline nights before the short baseline is trusted enough to score.
    public static let minBaselineNights = 7

    /// HRV carries most of the weight (more sensitive to day-to-day autonomic change — Altini/WHOOP);
    /// RHR confirms and, via the coupling below, is decisive when it DIVERGES from HRV.
    public static let hrvWeight = 0.6
    public static let rhrWeight = 0.4

    /// Coupled saturation damp (Buchheit quadrant; mirrors `RecoveryScorer.parasympatheticSaturation`).
    /// When HRV is suppressed (zHRV ≥ satEnterZ) but RHR is NOT elevated (zRHR < 0), the low HRV is
    /// benign parasympathetic saturation, not stress — damp the HRV term, ramping from no damp at the
    /// entry to `satMaxDamp` at `satFullZ` of RHR-below-baseline. Never flips the sign; only reduces.
    public static let satEnterZ = 0.5
    public static let satFullZ = 1.5
    public static let satMaxDamp = 0.5

    /// Smallest-worthwhile-change dead-zone (Hopkins 2000; Buchheit 2014): a combined |raw| under this
    /// many σ is noise → reads as baseline (1.5), not stress.
    public static let swcBand = 0.5

    /// A `ChronicShift` is flagged as sustained LOAD only when the recent baseline has moved in the load
    /// direction on BOTH channels (HRV down AND RHR up) past these — the coupled sustained-shift gate.
    public static let sustainedHRVPctThreshold = 5.0   // recent 14d HRV ≥5% below the 60d normal
    public static let sustainedRHRBpmThreshold = 2.0   // recent 14d RHR ≥2 bpm above the 60d normal

    /// Band floor for "high" on the 0–3 scale (matches the app's StressBand.high).
    public static let highBandFloor = 2.0

    // MARK: - Output

    /// Buchheit 2014's HRV×RHR quadrant — the autonomic interpretation behind the number.
    public enum Quadrant: String, Sendable, Equatable {
        case balanced                   // no meaningful deviation from the recent baseline
        case sympatheticStress          // HRV down + RHR up  → real autonomic stress / fatigue
        case parasympatheticSaturation  // HRV down + RHR down → benign (fit / deeply relaxed)
        case recovered                  // HRV up             → coping well / well recovered
    }

    /// The SEPARATE chronic readout: how far the recent (short) baseline has moved vs the long-term
    /// normal, and whether that shift is a coupled sustained LOAD (both channels moved together).
    public struct ChronicShift: Sendable, Equatable {
        /// + = recent 14-night HRV baseline sits this % BELOW the 60-night normal (suppressed).
        public let hrvPctBelowLongTerm: Double
        /// + = recent 14-night RHR baseline sits this many bpm ABOVE the 60-night normal (elevated).
        public let rhrBpmAboveLongTerm: Double
        /// True when BOTH channels have shifted in the load direction past their thresholds — a
        /// coupled, physiologically-consistent sustained autonomic load (not one noisy channel).
        public let isSustainedLoad: Bool
        /// Trailing consecutive nights whose HRV sat below the long-term normal band (a rough "for D
        /// days" duration for the readout).
        public let daysBelowBand: Int

        public init(hrvPctBelowLongTerm: Double, rhrBpmAboveLongTerm: Double,
                    isSustainedLoad: Bool, daysBelowBand: Int) {
            self.hrvPctBelowLongTerm = hrvPctBelowLongTerm
            self.rhrBpmAboveLongTerm = rhrBpmAboveLongTerm
            self.isSustainedLoad = isSustainedLoad
            self.daysBelowBand = daysBelowBand
        }
    }

    public struct DailyStress: Sendable, Equatable {
        /// 0–3 daily score: today vs the SHORT adaptive baseline, coupled + SWC-damped. 1.5 = baseline.
        public let score: Double
        /// HRV suppression vs the short baseline (log-domain σ), + = suppressed = toward stress.
        public let zHRV: Double
        /// RHR elevation vs the short baseline (σ), + = elevated = toward stress. 0 when no RHR.
        public let zRHR: Double
        /// The Buchheit autonomic quadrant behind the score.
        public let quadrant: Quadrant
        /// The separate long-term baseline-shift readout (nil when there isn't enough long history).
        public let chronicShift: ChronicShift?
        /// Baseline-density confidence (calibrating / building / solid).
        public let confidence: ScoreConfidence
        /// False when RHR was unavailable and the score fell back to HRV-only (no coupling possible).
        public let usedRHR: Bool

        public init(score: Double, zHRV: Double, zRHR: Double, quadrant: Quadrant,
                    chronicShift: ChronicShift?, confidence: ScoreConfidence, usedRHR: Bool) {
            self.score = score; self.zHRV = zHRV; self.zRHR = zRHR; self.quadrant = quadrant
            self.chronicShift = chronicShift; self.confidence = confidence; self.usedRHR = usedRHR
        }
    }

    // MARK: - Entry point

    /// Evaluate today's daily stress from the daily-metric history. `days` may be any order; the scored
    /// day is `today` (a "yyyy-MM-dd") if given and present, else the latest row carrying HRV/RHR.
    /// Returns nil when there is no scorable day or too little baseline.
    public static func evaluate(days: [DailyMetric], today: String? = nil) -> DailyStress? {
        let sorted = days.sorted { $0.day < $1.day }
        let idx: Int?
        if let today { idx = sorted.firstIndex { $0.day == today && ($0.avgHrv != nil || $0.restingHr != nil) } }
        else { idx = sorted.lastIndex { $0.avgHrv != nil || $0.restingHr != nil } }
        guard let i = idx else { return nil }
        let scored = sorted[i]
        let history = Array(sorted[0..<i])   // strictly before today

        // Baselines end the night BEFORE today (measured against its own recent past, not itself).
        let shortHist = Array(history.suffix(shortWindowDays))
        let longHist = Array(history.suffix(longWindowDays))

        let shortHRVln = foldLnHRV(shortHist)
        guard let sHRV = shortHRVln, sHRV.usable, let hrvT = scored.avgHrv else { return nil }
        let shortRHR = foldRHR(shortHist)
        let rhrT = scored.restingHr.map(Double.init)

        // z-scores against the SHORT adaptive baseline. HRV in log-domain; both oriented so + = stress.
        let zHRV = (sHRV.baseline - log(max(hrvT, 1.0))) / max(1.253 * sHRV.spread, 1e-9)
        let usedRHR = (shortRHR?.usable ?? false) && rhrT != nil
        let zRHR: Double = usedRHR
            ? (rhrT! - shortRHR!.baseline) / max(1.253 * shortRHR!.spread, 1e-9)
            : 0.0

        // Coupled raw (Buchheit): HRV primary, damped when RHR says "saturation", + a direct RHR term.
        let raw = hrvWeight * zHRV * saturationDamp(hrvZ: zHRV, rhrZ: zRHR)
                + (usedRHR ? rhrWeight * zRHR : 0.0)
        let score = squash(deadzone(raw, band: swcBand))

        let quadrant = classify(zHRV: zHRV, zRHR: zRHR, usedRHR: usedRHR)
        let chronic = chronicShift(scored: scored, history: history,
                                   shortHRVln: sHRV, longHist: longHist)
        let hrvNights = shortHist.compactMap { $0.avgHrv }.count
        let confidence = ScoreConfidence.readiness(hasRead: true, baselineNights: hrvNights,
                                                   fullWindow: shortWindowDays)
        return DailyStress(score: score, zHRV: zHRV, zRHR: zRHR, quadrant: quadrant,
                           chronicShift: chronic, confidence: confidence, usedRHR: usedRHR)
    }

    // MARK: - Coupling / math

    /// Parasympathetic-saturation damp on the HRV stress term: fires only when HRV is suppressed
    /// (hrvZ ≥ satEnterZ) AND RHR is NOT elevated (rhrZ < 0), ramping the damp from 1.0 at the entry to
    /// `1 − satMaxDamp` as RHR sinks `satFullZ` below its baseline. Only reduces the term, never flips it.
    static func saturationDamp(hrvZ: Double, rhrZ: Double) -> Double {
        guard hrvZ >= satEnterZ, rhrZ < 0 else { return 1.0 }
        let rhrLow = -rhrZ
        let t = max(0.0, min(1.0, (rhrLow - satEnterZ) / (satFullZ - satEnterZ)))
        return 1.0 - satMaxDamp * t
    }

    /// Smallest-worthwhile-change dead-zone: shrink |raw| toward zero by `band`, preserving sign.
    static func deadzone(_ raw: Double, band: Double) -> Double {
        raw >= 0 ? max(0, raw - band) : min(0, raw + band)
    }

    /// Logistic squash to 0–3 (raw 0 → 1.5), identical scale/curve to the daytime + old daily score.
    static func squash(_ raw: Double) -> Double { min(max(3.0 / (1.0 + exp(-raw)), 0), 3) }

    static func classify(zHRV: Double, zRHR: Double, usedRHR: Bool) -> Quadrant {
        if zHRV <= -satEnterZ { return .recovered }          // HRV meaningfully ABOVE baseline
        guard zHRV >= satEnterZ else { return .balanced }    // HRV within the SWC band → balanced
        if !usedRHR { return .sympatheticStress }            // HRV down, no RHR to disambiguate
        return zRHR > 0 ? .sympatheticStress : .parasympatheticSaturation
    }

    // MARK: - Chronic shift (short baseline vs long reference)

    static func chronicShift(scored: DailyMetric, history: [DailyMetric],
                             shortHRVln: BaselineState, longHist: [DailyMetric]) -> ChronicShift? {
        guard let longHRVln = foldLnHRV(longHist), longHRVln.usable else { return nil }
        // % the recent HRV baseline sits below the long-term (both are geometric centres in ln-space).
        let hrvPct = (1.0 - exp(shortHRVln.baseline - longHRVln.baseline)) * 100.0
        let shortRHR = foldRHR(Array(history.suffix(shortWindowDays)))
        let longRHR = foldRHR(longHist)
        let rhrBpm: Double = (shortRHR?.usable == true && longRHR?.usable == true)
            ? shortRHR!.baseline - longRHR!.baseline : 0.0
        let sustained = hrvPct >= sustainedHRVPctThreshold && rhrBpm >= sustainedRHRBpmThreshold
        // Duration: trailing nights whose HRV sat below the long-term band (mean − 0.5σ, the SWC edge).
        let bandFloorLn = longHRVln.baseline - swcBand * max(1.253 * longHRVln.spread, 1e-9)
        var d = 0
        for row in (history + [scored]).reversed() {
            guard let h = row.avgHrv else { continue }
            if log(max(h, 1.0)) < bandFloorLn { d += 1 } else { break }
        }
        return ChronicShift(hrvPctBelowLongTerm: hrvPct, rhrBpmAboveLongTerm: rhrBpm,
                            isSustainedLoad: sustained, daysBelowBand: d)
    }

    // MARK: - Baseline folds (reuse the shared window-fold spine: reject OFF so a sustained shift adapts)

    static func foldLnHRV(_ rows: [DailyMetric]) -> BaselineState? {
        let ln = rows.map { $0.avgHrv.map { log(max($0, 1.0)) } }
        guard ln.contains(where: { $0 != nil }) else { return nil }
        return Baselines.foldHistory(ln, cfg: Baselines.readinessHRVLnCfg, rejectHardOutliers: false)
    }

    static func foldRHR(_ rows: [DailyMetric]) -> BaselineState? {
        let v = rows.map { $0.restingHr.map(Double.init) }
        guard v.contains(where: { $0 != nil }) else { return nil }
        return Baselines.foldHistory(v, cfg: Baselines.restingHRCfg, rejectHardOutliers: false)
    }
}
