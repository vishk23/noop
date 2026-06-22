import Foundation
import WhoopProtocol

/// Estimate daily steps for a WHOOP 4.0 from the strap's MOTION, calibrated per-user against a phone
/// step count (Apple Health / Health Connect).
///
/// WHY THIS IS A CALIBRATED ESTIMATE, NOT A PEDOMETER. A WHOOP 4.0 does not send a step count over BLE,
/// and the accelerometer/gravity data we DO get is sparse (~one vector per stored record, roughly minute
/// granularity) — far below the ~25–50 Hz a true step counter needs to see individual footfalls. So we
/// cannot count steps. What we CAN measure is movement VOLUME (how much the gravity vector moved over the
/// day), and we map that volume to steps with a coefficient learned from days where the phone ALSO counted
/// steps. The output is always framed as an estimate.
///
/// THE MODEL. `steps ≈ k · motionIntensity`, a through-origin fit (no steps ⇒ no motion). `k` (steps per
/// unit of motion) is the only free parameter, and it is PERSONAL — it depends on wrist vs hip placement,
/// gait, and how the strap rides — which is exactly why it's calibrated to each user rather than a global
/// constant. We fit `k` robustly (the median of per-day `steps/motion` ratios) so a single odd day (a drive,
/// a workout that's all arms, a phone left at home) can't drag the whole calibration. A user with no phone
/// step history to fit against can set `k` manually with the calibration slider.
///
/// Pure value type — no I/O, fully unit-tested. The Kotlin twin is StepsEstimateEngine.kt (kept byte-for-byte
/// equivalent: same motion sum, same median fit, same confidence curve, same clamps).
public enum StepsEstimateEngine {

    // MARK: - Tunables

    /// Fewest calibration days (each with both motion and a reference step count) before we trust an
    /// auto-fit `k`. Below this the estimate is withheld unless the user has set a manual `k`.
    public static let minCalibrationDays = 3
    /// Calibration days at/above which confidence saturates toward 1.
    public static let goodCalibrationDays = 14
    /// A day must move at least this much (summed gravity-delta) to enter the ratio fit — filters near-still
    /// days whose tiny motion makes steps/motion explode. Also the floor for producing an estimate.
    public static let minMotionForFit = 1.0
    /// Sanity clamp on a daily estimate so a calibration outlier can never render an absurd number.
    public static let maxDailySteps = 60_000

    // MARK: - Types

    /// One calibration day: the strap's motion volume and the phone's measured step count for the SAME day.
    public struct CalibrationPoint: Equatable {
        public let motion: Double
        public let steps: Double
        public init(motion: Double, steps: Double) { self.motion = motion; self.steps = steps }
    }

    /// The fitted (or manually-set) personal model.
    public struct Calibration: Equatable {
        /// Steps per unit of motion.
        public let coefficient: Double
        /// How many days fed the auto-fit (0 when purely manual).
        public let sampleDays: Int
        /// 0–1: how much to trust the estimate, from sample size and fit spread. 1.0 for a user-set manual `k`.
        public let confidence: Double
        /// True when the user set `k` by hand rather than it being fit from phone data.
        public let manual: Bool
        public init(coefficient: Double, sampleDays: Int, confidence: Double, manual: Bool) {
            self.coefficient = coefficient; self.sampleDays = sampleDays
            self.confidence = confidence; self.manual = manual
        }
    }

    /// A readable read-out of the calibration state, for the Today steps tile and the Settings section.
    /// Pure value type (no UI strings beyond a single short status line) so both surfaces stay in step.
    public enum CalibrationStatus: Equatable {
        /// A manual `k` is in force (the user set it by hand). `sampleDays` = the auto-fit days that exist
        /// alongside it (informational; the manual value still wins).
        case manual(coefficient: Double, sampleDays: Int)
        /// Enough overlapping days fit an auto coefficient. Carries the fit and its 0–1 confidence.
        case calibrated(coefficient: Double, sampleDays: Int, confidence: Double)
        /// Not yet calibrated: `have` overlapping phone-counted days out of `need`, so `need - have` more
        /// are required before an estimate appears (and no manual override is set to fill the gap).
        case needsMoreDays(have: Int, need: Int)

        /// True when an estimate can be produced right now (manual or a usable auto-fit).
        public var canEstimate: Bool {
            switch self {
            case .manual, .calibrated: return true
            case .needsMoreDays: return false
            }
        }

        /// A short, honest one-liner for the tile/Settings. US-neutral, no em-dashes. The caller may also
        /// render a confidence badge from `.calibrated`'s confidence; this is the headline only.
        public var headline: String {
            switch self {
            case .manual:
                return "Calibrated by hand"
            case let .calibrated(_, sampleDays, _):
                return "Estimated from \(sampleDays) day\(sampleDays == 1 ? "" : "s") your phone also counted"
            case let .needsMoreDays(have, need):
                let more = Swift.max(0, need - have)
                return "Need \(more) more day\(more == 1 ? "" : "s") where your phone also counted steps"
            }
        }
    }

    /// Classify the current calibration state from the same inputs `calibrate(_:manualOverride:)` sees,
    /// so the UI can explain WHY the steps tile is (or isn't) showing an estimate without re-deriving the
    /// fit. A positive `manualOverride` always reports `.manual`. Otherwise we count the usable overlapping
    /// days (same filter the fit uses) and report `.calibrated` once `minCalibrationDays` are met, else
    /// `.needsMoreDays`. Mirror of the Kotlin `status(...)`.
    public static func status(_ points: [CalibrationPoint], manualOverride: Double? = nil) -> CalibrationStatus {
        let usableDays = points.filter { $0.motion >= minMotionForFit && $0.steps > 0 }.count
        if let k = manualOverride, k > 0 {
            return .manual(coefficient: k, sampleDays: usableDays)
        }
        guard let cal = calibrate(points), usableDays >= minCalibrationDays else {
            return .needsMoreDays(have: usableDays, need: minCalibrationDays)
        }
        return .calibrated(coefficient: cal.coefficient, sampleDays: cal.sampleDays, confidence: cal.confidence)
    }

    // MARK: - Motion feature

    /// Total daily MOTION INTENSITY = the sum of per-record gravity-vector deltas (L2 magnitude of the change
    /// between consecutive samples). This is movement VOLUME over the day, the same proxy the sleep stager
    /// uses for stillness, integrated. Sparse-but-monotone-with-activity, so it calibrates cleanly to steps.
    public static func dayMotionIntensity(_ grav: [GravitySample]) -> Double {
        guard grav.count > 1 else { return 0 }
        var total = 0.0
        var prev = grav[0]
        for i in 1..<grav.count {
            let r = grav[i]
            let dx = prev.x - r.x, dy = prev.y - r.y, dz = prev.z - r.z
            total += (dx * dx + dy * dy + dz * dz).squareRoot()
            prev = r
        }
        return total
    }

    // MARK: - Calibration

    /// Fit the personal coefficient from days that have BOTH a motion volume and a reference step count.
    /// Robust: take the median of each day's `steps / motion` ratio (days below `minMotionForFit` are skipped),
    /// so outliers don't pull `k`. Returns nil when there aren't enough usable days AND no manual override is
    /// supplied. A non-nil `manualOverride` always wins (confidence 1.0) — for users with no phone step data.
    public static func calibrate(_ points: [CalibrationPoint], manualOverride: Double? = nil) -> Calibration? {
        if let k = manualOverride, k > 0 {
            return Calibration(coefficient: k, sampleDays: points.count, confidence: 1.0, manual: true)
        }
        let ratios = points
            .filter { $0.motion >= minMotionForFit && $0.steps > 0 }
            .map { $0.steps / $0.motion }
            .sorted()
        guard ratios.count >= minCalibrationDays else { return nil }
        let k = median(ratios)
        guard k > 0 else { return nil }
        // Confidence: grows with sample size toward goodCalibrationDays, discounted by relative spread
        // (MAD / median) so a noisy fit is honestly less trusted than a tight one.
        let sizeTerm = min(1.0, Double(ratios.count) / Double(goodCalibrationDays))
        let mad = median(ratios.map { abs($0 - k) })
        let spread = k > 0 ? mad / k : 1.0
        let tightness = max(0.0, 1.0 - spread)              // 1 = all ratios equal, 0 = wildly scattered
        let confidence = (0.5 * sizeTerm + 0.5 * tightness).clampedUnit
        return Calibration(coefficient: k, sampleDays: ratios.count, confidence: confidence, manual: false)
    }

    // MARK: - Estimate

    /// Estimated steps for a day from its motion volume and the personal calibration. nil below
    /// `minMotionForFit` (too little movement to say anything) — the UI then shows "—", never a fake 0.
    public static func estimate(motion: Double, calibration: Calibration) -> Int? {
        guard motion >= minMotionForFit, calibration.coefficient > 0 else { return nil }
        let raw = motion * calibration.coefficient
        return Int(raw.rounded()).clamped(0, maxDailySteps)
    }

    // MARK: - Helpers

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}

private extension Double {
    var clampedUnit: Double { Swift.max(0.0, Swift.min(1.0, self)) }
}
private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.max(lo, Swift.min(hi, self)) }
}
