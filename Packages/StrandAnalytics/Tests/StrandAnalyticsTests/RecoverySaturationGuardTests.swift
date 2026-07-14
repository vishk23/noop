import XCTest
import Foundation
@testable import StrandAnalytics

/// Parasympathetic-saturation guard on Charge (recovery). A low nightly HRV normally drives Charge
/// DOWN via the dominant HRV term, but in a very fit / very relaxed state HRV can read LOW while
/// resting HR reads LOW too and the two decouple — a benign saturated vagal state, not fatigue.
/// The guard eases (never removes) the low-HRV penalty ONLY in that pattern. These tests pin BOTH
/// directions: a saturation night is NOT tanked, a real-fatigue night (low HRV + HIGH resting HR)
/// still IS. No em-dashes.
final class RecoverySaturationGuardTests: XCTestCase {

    /// A usable (trusted) baseline with a given mean and Gaussian sigma (spread is internal
    /// abs-dev units; zScore multiplies by 1.253 to recover sigma).
    private func baseline(mean: Double, sigma: Double, nValid: Int = 14) -> BaselineState {
        BaselineState(baseline: mean, spread: sigma / 1.253, nValid: nValid,
                      nightsSinceUpdate: 0, status: nValid >= 14 ? .trusted : .provisional)
    }

    // MARK: - The guard helper in isolation

    func testGuardFiresOnSaturationSignatureAndEasesButNeverRemovesPenalty() {
        // HRV clearly below baseline (penalty direction) AND resting HR clearly below baseline
        // (recovery-good direction): the saturation signature. The penalty is eased (effective z
        // closer to 0) but stays negative — never inverted, never fully removed.
        let s = RecoveryScorer.parasympatheticSaturation(hrvZ: -1.5, rhrZ: 1.5)
        XCTAssertTrue(s.active)
        XCTAssertGreaterThan(s.effectiveHrvZ, -1.5)          // eased toward 0
        XCTAssertLessThan(s.effectiveHrvZ, 0.0)               // still a penalty (never inverted)
        XCTAssertGreaterThan(s.dampFraction, 0.0)
        XCTAssertLessThanOrEqual(s.dampFraction, RecoveryScorer.satMaxDampFraction)  // capped
    }

    func testGuardIsSilentOnRealFatigue() {
        // Low HRV + HIGH resting HR (rhrZ negative): normal sympathetic coupling, genuine fatigue.
        // The guard must NOT fire — the low-HRV penalty passes through untouched.
        let s = RecoveryScorer.parasympatheticSaturation(hrvZ: -1.5, rhrZ: -1.5)
        XCTAssertFalse(s.active)
        XCTAssertEqual(s.effectiveHrvZ, -1.5, accuracy: 1e-12)
        XCTAssertEqual(s.dampFraction, 0.0, accuracy: 1e-12)
    }

    func testGuardIsSilentWhenHRVIsNotLow() {
        // HRV at or above baseline is not a penalty to ease, even with a very low resting HR.
        XCTAssertFalse(RecoveryScorer.parasympatheticSaturation(hrvZ: 1.5, rhrZ: 1.5).active)
        XCTAssertFalse(RecoveryScorer.parasympatheticSaturation(hrvZ: 0.0, rhrZ: 1.5).active)
    }

    func testGuardIsSilentWithoutARestingHRSignal() {
        // No RHR term (nil): nothing corroborates the low HRV, so real fatigue and benign
        // saturation are indistinguishable from HRV alone. Refuse to guess -> no easing.
        let s = RecoveryScorer.parasympatheticSaturation(hrvZ: -1.5, rhrZ: nil)
        XCTAssertFalse(s.active)
        XCTAssertEqual(s.effectiveHrvZ, -1.5, accuracy: 1e-12)
    }

    func testGuardIsSilentOnMarginalDivergenceBelowTheGate() {
        // Both arms present but shallow (below satEnterZ): marginal noise, not a clear pattern.
        let below = RecoveryScorer.satEnterZ - 0.05
        let s = RecoveryScorer.parasympatheticSaturation(hrvZ: -below, rhrZ: below)
        XCTAssertFalse(s.active)
        XCTAssertEqual(s.effectiveHrvZ, -below, accuracy: 1e-12)
    }

    func testDampingIsMonotonicInCorroborationAndCapped() {
        // Stronger corroboration (both arms deeper below baseline) eases more, up to the cap.
        let weak = RecoveryScorer.parasympatheticSaturation(hrvZ: -0.8, rhrZ: 0.8).dampFraction
        let strong = RecoveryScorer.parasympatheticSaturation(hrvZ: -1.4, rhrZ: 1.4).dampFraction
        let saturated = RecoveryScorer.parasympatheticSaturation(hrvZ: -3.0, rhrZ: 3.0).dampFraction
        XCTAssertGreaterThan(strong, weak)
        XCTAssertEqual(saturated, RecoveryScorer.satMaxDampFraction, accuracy: 1e-12)  // never exceeds cap
        // The weaker arm caps the strength (conservative): a very low HRV with only a mildly low
        // resting HR is limited by the resting-HR arm.
        let limited = RecoveryScorer.parasympatheticSaturation(hrvZ: -3.0, rhrZ: 0.8)
        let bothStrong = RecoveryScorer.parasympatheticSaturation(hrvZ: -3.0, rhrZ: 3.0)
        XCTAssertLessThan(limited.dampFraction, bothStrong.dampFraction)
    }

    // MARK: - End to end through recovery(): both directions

    func testSaturationNightIsNotTankedButRealFatigueStillIs() {
        let hrvB = baseline(mean: 50, sigma: 6.265)   // sigma == 6.265 (spread * 1.253)
        let rhrB = baseline(mean: 55, sigma: 5.0)

        // Same LOW HRV (41 ms, ~1.44 sigma below) for both nights; only resting HR differs.
        let saturation = RecoveryScorer.recovery(
            hrv: 41, rhr: 48, resp: nil,               // resting HR ~1.4 sigma BELOW baseline (good)
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)!
        let fatigue = RecoveryScorer.recovery(
            hrv: 41, rhr: 62, resp: nil,               // resting HR ~1.4 sigma ABOVE baseline (bad)
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)!

        // Real fatigue: still tanked into the red band.
        XCTAssertLessThan(fatigue, RecoveryScorer.bandRedMax, "low HRV + high resting HR must stay red")
        // Saturation: lifted OUT of red, and clearly above the fatigue night.
        XCTAssertGreaterThanOrEqual(saturation, RecoveryScorer.bandRedMax, "saturation must not read red")
        XCTAssertGreaterThan(saturation - fatigue, 20.0, "the guard must meaningfully separate the two")
    }

    func testGuardLiftsSaturationAboveTheUndampedComposite() {
        // Isolate the guard's effect (not just the low-RHR term's own contribution): reconstruct
        // the score the SAME night would get with the RAW, undamped HRV z, and show recovery() is
        // strictly higher because the guard eased the penalty.
        let hrvB = baseline(mean: 50, sigma: 6.265)
        let rhrB = baseline(mean: 55, sigma: 5.0)

        let hrvZ = RecoveryScorer.zScore(41, mean: hrvB.baseline, spread: hrvB.spread)
        let rhrZ = RecoveryScorer.zScore(rhrB.baseline, mean: 48, spread: rhrB.spread)  // (mu - x)/sigma
        let wsum = RecoveryScorer.wHRV + RecoveryScorer.wRHR
        let undampedZ = (RecoveryScorer.wHRV * hrvZ + RecoveryScorer.wRHR * rhrZ) / wsum
        let undamped = 100.0 / (1.0 + exp(-RecoveryScorer.logisticK * (undampedZ - RecoveryScorer.logisticZ0)))

        let guarded = RecoveryScorer.recovery(
            hrv: 41, rhr: 48, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)!

        XCTAssertGreaterThan(guarded, undamped + 5.0, "the guard must add real points on a saturation night")
    }

    func testHighRHRHighHRVGoodNightIsUnchangedByGuard() {
        // A genuinely great night (HRV up, resting HR down) must be untouched: the guard only
        // engages when HRV is BELOW baseline. Recompute the plain composite and require equality.
        let hrvB = baseline(mean: 50, sigma: 6.265)
        let rhrB = baseline(mean: 55, sigma: 5.0)
        let hrvZ = RecoveryScorer.zScore(62, mean: hrvB.baseline, spread: hrvB.spread)   // HRV above
        let rhrZ = RecoveryScorer.zScore(rhrB.baseline, mean: 49, spread: rhrB.spread)
        let wsum = RecoveryScorer.wHRV + RecoveryScorer.wRHR
        let z = (RecoveryScorer.wHRV * hrvZ + RecoveryScorer.wRHR * rhrZ) / wsum
        let expected = 100.0 / (1.0 + exp(-RecoveryScorer.logisticK * (z - RecoveryScorer.logisticZ0)))
        let actual = RecoveryScorer.recovery(
            hrv: 62, rhr: 49, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)!
        XCTAssertEqual(actual, expected, accuracy: 1e-9, "HRV-above-baseline night must bypass the guard")
    }

    // MARK: - Explainability: trace + driver breakdown

    func testTraceEmitsSaturationLineAndDampedHRVTermOnlyWhenActive() {
        let hrvB = baseline(mean: 50, sigma: 6.265)
        let rhrB = baseline(mean: 55, sigma: 5.0)

        // Saturation night: the trace names the eased penalty and its score still equals recovery().
        let (satScore, satLines) = RecoveryScorer.recoveryTrace(
            hrv: 41, rhr: 48, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)
        let plain = RecoveryScorer.recovery(
            hrv: 41, rhr: 48, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)
        XCTAssertEqual(satScore, plain)
        XCTAssertTrue(satLines.contains { $0.contains("charge saturation active") })

        // Real-fatigue night: NO saturation line (guard silent).
        let (_, fatLines) = RecoveryScorer.recoveryTrace(
            hrv: 41, rhr: 62, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)
        XCTAssertFalse(fatLines.contains { $0.contains("charge saturation") })
        for l in satLines + fatLines { XCTAssertFalse(l.contains("\u{2014}"), "em-dash in: \(l)") }
    }

    func testChargeDriversHRVPenaltyEasedAndVerdictExplainsSaturation() {
        let hrvB = baseline(mean: 50, sigma: 6.265)
        let rhrB = baseline(mean: 55, sigma: 5.0)

        // Saturation night: the HRV row is still a penalty (below baseline) but its verdict
        // explains the parasympathetic-saturation easing rather than the plain "limiting recovery".
        let sat = RecoveryScorer.chargeDrivers(
            hrv: 41, rhr: 48, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)
        let satHRV = sat.first { $0.label == "Heart rate variability" }!
        XCTAssertTrue(satHRV.verdict.contains("saturation"), "verdict must explain the eased penalty")
        XCTAssertFalse(satHRV.verdict.contains("\u{2014}"))

        // Real-fatigue night: plain limiting verdict, penalty NOT eased.
        let fat = RecoveryScorer.chargeDrivers(
            hrv: 41, rhr: 62, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)
        let fatHRV = fat.first { $0.label == "Heart rate variability" }!
        XCTAssertTrue(fatHRV.verdict.contains("limiting recovery"))
        XCTAssertLessThan(fatHRV.deltaPoints, 0)
        // The eased saturation penalty is less negative than the raw fatigue penalty for the same HRV.
        XCTAssertGreaterThan(satHRV.deltaPoints, fatHRV.deltaPoints)
    }
}
