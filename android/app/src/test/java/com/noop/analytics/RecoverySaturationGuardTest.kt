package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.exp

/**
 * Parasympathetic-saturation guard on Charge (recovery) — Kotlin twin of the Swift
 * `RecoverySaturationGuardTests` (StrandAnalytics, PR #461). A low nightly HRV normally drives Charge DOWN
 * via the dominant HRV term, but in a very fit / very relaxed state HRV can read LOW while resting HR reads
 * LOW too and the two decouple — a benign saturated vagal state, not fatigue. The guard eases (never removes)
 * the low-HRV penalty ONLY in that pattern. These tests pin BOTH directions: a saturation night is NOT tanked,
 * a real-fatigue night (low HRV + HIGH resting HR) still IS. Byte-identical inputs/expectations to the Swift
 * reference. No em-dashes.
 */
class RecoverySaturationGuardTest {

    /** A usable (trusted) baseline with a given mean and Gaussian sigma (spread is internal abs-dev units;
     *  zScore multiplies by 1.253 to recover sigma). Mirrors the Swift `baseline(mean:sigma:nValid:)`. */
    private fun baseline(mean: Double, sigma: Double, nValid: Int = 14): BaselineState =
        BaselineState(
            baseline = mean, spread = sigma / 1.253, nValid = nValid, nightsSinceUpdate = 0,
            status = if (nValid >= 14) BaselineStatus.TRUSTED else BaselineStatus.PROVISIONAL,
        )

    // MARK: - The guard helper in isolation

    @Test fun guardFiresOnSaturationSignatureAndEasesButNeverRemovesPenalty() {
        // HRV clearly below baseline (penalty direction) AND resting HR clearly below baseline (recovery-good
        // direction): the saturation signature. The penalty is eased (effective z closer to 0) but stays
        // negative — never inverted, never fully removed.
        val s = RecoveryScorer.parasympatheticSaturation(hrvZ = -1.5, rhrZ = 1.5)
        assertTrue(s.active)
        assertTrue("eased toward 0", s.effectiveHrvZ > -1.5)
        assertTrue("still a penalty (never inverted)", s.effectiveHrvZ < 0.0)
        assertTrue(s.dampFraction > 0.0)
        assertTrue("capped", s.dampFraction <= RecoveryScorer.satMaxDampFraction)
    }

    @Test fun guardIsSilentOnRealFatigue() {
        // Low HRV + HIGH resting HR (rhrZ negative): normal sympathetic coupling, genuine fatigue. The guard
        // must NOT fire — the low-HRV penalty passes through untouched.
        val s = RecoveryScorer.parasympatheticSaturation(hrvZ = -1.5, rhrZ = -1.5)
        assertFalse(s.active)
        assertEquals(-1.5, s.effectiveHrvZ, 1e-12)
        assertEquals(0.0, s.dampFraction, 1e-12)
    }

    @Test fun guardIsSilentWhenHRVIsNotLow() {
        // HRV at or above baseline is not a penalty to ease, even with a very low resting HR.
        assertFalse(RecoveryScorer.parasympatheticSaturation(hrvZ = 1.5, rhrZ = 1.5).active)
        assertFalse(RecoveryScorer.parasympatheticSaturation(hrvZ = 0.0, rhrZ = 1.5).active)
    }

    @Test fun guardIsSilentWithoutARestingHRSignal() {
        // No RHR term (null): nothing corroborates the low HRV, so real fatigue and benign saturation are
        // indistinguishable from HRV alone. Refuse to guess -> no easing.
        val s = RecoveryScorer.parasympatheticSaturation(hrvZ = -1.5, rhrZ = null)
        assertFalse(s.active)
        assertEquals(-1.5, s.effectiveHrvZ, 1e-12)
    }

    @Test fun guardIsSilentOnMarginalDivergenceBelowTheGate() {
        // Both arms present but shallow (below satEnterZ): marginal noise, not a clear pattern.
        val below = RecoveryScorer.satEnterZ - 0.05
        val s = RecoveryScorer.parasympatheticSaturation(hrvZ = -below, rhrZ = below)
        assertFalse(s.active)
        assertEquals(-below, s.effectiveHrvZ, 1e-12)
    }

    @Test fun dampingIsMonotonicInCorroborationAndCapped() {
        // Stronger corroboration (both arms deeper below baseline) eases more, up to the cap.
        val weak = RecoveryScorer.parasympatheticSaturation(hrvZ = -0.8, rhrZ = 0.8).dampFraction
        val strong = RecoveryScorer.parasympatheticSaturation(hrvZ = -1.4, rhrZ = 1.4).dampFraction
        val saturated = RecoveryScorer.parasympatheticSaturation(hrvZ = -3.0, rhrZ = 3.0).dampFraction
        assertTrue(strong > weak)
        assertEquals(RecoveryScorer.satMaxDampFraction, saturated, 1e-12)   // never exceeds cap
        // The weaker arm caps the strength (conservative): a very low HRV with only a mildly low resting HR
        // is limited by the resting-HR arm.
        val limited = RecoveryScorer.parasympatheticSaturation(hrvZ = -3.0, rhrZ = 0.8)
        val bothStrong = RecoveryScorer.parasympatheticSaturation(hrvZ = -3.0, rhrZ = 3.0)
        assertTrue(limited.dampFraction < bothStrong.dampFraction)
    }

    // MARK: - End to end through recovery(): both directions

    @Test fun saturationNightIsNotTankedButRealFatigueStillIs() {
        val hrvB = baseline(mean = 50.0, sigma = 6.265)   // sigma == 6.265 (spread * 1.253)
        val rhrB = baseline(mean = 55.0, sigma = 5.0)

        // Same LOW HRV (41 ms, ~1.44 sigma below) for both nights; only resting HR differs.
        val saturation = RecoveryScorer.recovery(
            hrv = 41.0, rhr = 48.0, resp = null,          // resting HR ~1.4 sigma BELOW baseline (good)
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )!!
        val fatigue = RecoveryScorer.recovery(
            hrv = 41.0, rhr = 62.0, resp = null,          // resting HR ~1.4 sigma ABOVE baseline (bad)
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )!!

        assertTrue("low HRV + high resting HR must stay red", fatigue < RecoveryScorer.bandRedMax)
        assertTrue("saturation must not read red", saturation >= RecoveryScorer.bandRedMax)
        assertTrue("the guard must meaningfully separate the two", saturation - fatigue > 20.0)
    }

    @Test fun guardLiftsSaturationAboveTheUndampedComposite() {
        // Isolate the guard's effect (not just the low-RHR term's own contribution): reconstruct the score the
        // SAME night would get with the RAW, undamped HRV z, and show recovery() is strictly higher.
        val hrvB = baseline(mean = 50.0, sigma = 6.265)
        val rhrB = baseline(mean = 55.0, sigma = 5.0)

        val hrvZ = RecoveryScorer.zScore(41.0, hrvB.baseline, hrvB.spread)
        val rhrZ = RecoveryScorer.zScore(rhrB.baseline, 48.0, rhrB.spread)  // (mu - x)/sigma
        val wsum = RecoveryScorer.wHRV + RecoveryScorer.wRHR
        val undampedZ = (RecoveryScorer.wHRV * hrvZ + RecoveryScorer.wRHR * rhrZ) / wsum
        val undamped = 100.0 / (1.0 + exp(-RecoveryScorer.logisticK * (undampedZ - RecoveryScorer.logisticZ0)))

        val guarded = RecoveryScorer.recovery(
            hrv = 41.0, rhr = 48.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )!!

        assertTrue("the guard must add real points on a saturation night", guarded > undamped + 5.0)
    }

    @Test fun highRHRHighHRVGoodNightIsUnchangedByGuard() {
        // A genuinely great night (HRV up, resting HR down) must be untouched: the guard only engages when HRV
        // is BELOW baseline. Recompute the plain composite and require equality.
        val hrvB = baseline(mean = 50.0, sigma = 6.265)
        val rhrB = baseline(mean = 55.0, sigma = 5.0)
        val hrvZ = RecoveryScorer.zScore(62.0, hrvB.baseline, hrvB.spread)   // HRV above
        val rhrZ = RecoveryScorer.zScore(rhrB.baseline, 49.0, rhrB.spread)
        val wsum = RecoveryScorer.wHRV + RecoveryScorer.wRHR
        val z = (RecoveryScorer.wHRV * hrvZ + RecoveryScorer.wRHR * rhrZ) / wsum
        val expected = 100.0 / (1.0 + exp(-RecoveryScorer.logisticK * (z - RecoveryScorer.logisticZ0)))
        val actual = RecoveryScorer.recovery(
            hrv = 62.0, rhr = 49.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )!!
        assertEquals("HRV-above-baseline night must bypass the guard", expected, actual, 1e-9)
    }

    // MARK: - Explainability: trace + driver breakdown

    @Test fun traceEmitsSaturationLineAndDampedHRVTermOnlyWhenActive() {
        val hrvB = baseline(mean = 50.0, sigma = 6.265)
        val rhrB = baseline(mean = 55.0, sigma = 5.0)

        // Saturation night: the trace names the eased penalty and its score still equals recovery().
        val (satScore, satLines) = RecoveryScorerTrace.recoveryTrace(
            hrv = 41.0, rhr = 48.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )
        val plain = RecoveryScorer.recovery(
            hrv = 41.0, rhr = 48.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )
        assertEquals(plain, satScore)
        assertTrue(satLines.any { it.contains("charge saturation active") })

        // Real-fatigue night: NO saturation line (guard silent).
        val (_, fatLines) = RecoveryScorerTrace.recoveryTrace(
            hrv = 41.0, rhr = 62.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )
        assertFalse(fatLines.any { it.contains("charge saturation") })
        for (l in satLines + fatLines) assertFalse("em-dash in: $l", l.contains("—"))
    }

    @Test fun chargeDriversHRVPenaltyEasedAndVerdictExplainsSaturation() {
        val hrvB = baseline(mean = 50.0, sigma = 6.265)
        val rhrB = baseline(mean = 55.0, sigma = 5.0)

        // Saturation night: the HRV row is still a penalty (below baseline) but its verdict explains the
        // parasympathetic-saturation easing rather than the plain "limiting recovery".
        val sat = RecoveryDrivers.chargeDrivers(
            hrv = 41.0, rhr = 48.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )
        val satHRV = sat.first { it.label == "Heart rate variability" }
        assertTrue("verdict must explain the eased penalty", satHRV.verdict.contains("saturation"))
        assertFalse(satHRV.verdict.contains("—"))

        // Real-fatigue night: plain limiting verdict, penalty NOT eased.
        val fat = RecoveryDrivers.chargeDrivers(
            hrv = 41.0, rhr = 62.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )
        val fatHRV = fat.first { it.label == "Heart rate variability" }
        assertTrue(fatHRV.verdict.contains("limiting recovery"))
        assertTrue(fatHRV.deltaPoints < 0)
        // The eased saturation penalty is less negative than the raw fatigue penalty for the same HRV.
        assertTrue(satHRV.deltaPoints > fatHRV.deltaPoints)
    }
}
