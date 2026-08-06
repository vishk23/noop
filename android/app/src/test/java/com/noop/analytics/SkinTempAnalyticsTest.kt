package com.noop.analytics

import com.noop.data.EventRow
import com.noop.data.HrSample
import com.noop.data.SkinTempSample
import com.noop.protocol.DeviceFamily
import com.noop.protocol.Whoop4SkinTemp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the WHOOP 5.0/MG skin-temperature pipeline added in AnalyticsEngine/IntelligenceEngine.
 *
 * Two parts, mirroring the codebase's "test the building block" convention (see BaselineSeedingTest):
 *  1. [AnalyticsEngine.wornNightlySkinTempC] — the new wear-gated nightly-mean logic (the part that
 *     turns raw skin_temp_raw@73 samples into a trustworthy per-night value).
 *  2. The seed→deviation flow over [Baselines.foldHistory]/[Baselines.deviation] with the standard
 *     `skin_temp` config — pinning the honest cold-start gate (<4 nights ⇒ no skinTempDevC) and that a
 *     real elevation surfaces as a positive deviation once seeded. All values APPROXIMATE.
 *
 * Skin-temp raw is u16 centi-°C (°C = raw/100); worn nightly values seen on real hardware were ~33–35 °C,
 * off-wrist/charging ~22–27 °C — which is exactly the contamination the wear-gate excludes.
 */
class SkinTempAnalyticsTest {

    private val dev = "my-whoop"

    private fun session(start: Long, durSec: Long) = DetectedSleep(
        start = start, end = start + durSec, efficiency = 0.9,
        stages = emptyList(), restingHR = 50, avgHRV = 60.0,
    )

    private fun hr(ts: Long, bpm: Int = 55) = HrSample(deviceId = dev, ts = ts, bpm = bpm)
    private fun skin(ts: Long, rawCentiC: Int) = SkinTempSample(deviceId = dev, ts = ts, raw = rawCentiC)

    // ── wornNightlySkinTempC ────────────────────────────────────────────────

    @Test
    fun meanOverWornInBedSamples() {
        val start = 1_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + it) }
        val temps = (0 until 600).map { skin(start + it, 3400) } // 34.00 °C
        val mean = AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps)
        assertEquals(34.0, mean!!, 1e-9)
    }

    @Test
    fun excludesSamplesWithoutConcurrentWornHr() {
        // The strap streams HR only on-wrist; skin-temp samples with no concurrent worn BPM are dropped.
        val start = 2_000_000L
        val sess = listOf(session(start, 600))
        val temps = (0 until 600).map { skin(start + it, 3400) }
        assertNull(AnalyticsEngine.wornNightlySkinTempC(sess, emptyList(), temps))
    }

    @Test
    fun excludesDaytimeSamplesOutsideTheSleepSession() {
        // Daytime samples are in worn range (36 °C) AND have worn HR, but fall OUTSIDE the in-bed
        // session window, so only the in-bed 34 °C samples count. Isolates the session-window gate.
        val night = 3_000_000L
        val sess = listOf(session(night, 600))
        val inBedHr = (0 until 600).map { hr(night + it) }
        val inBedTemp = (0 until 600).map { skin(night + it, 3400) }
        val day = night + 10_000
        val dayHr = (0 until 600).map { hr(day + it) }
        val dayTemp = (0 until 600).map { skin(day + it, 3600) } // 36 °C, worn-range, but daytime
        val mean = AnalyticsEngine.wornNightlySkinTempC(sess, inBedHr + dayHr, inBedTemp + dayTemp)
        assertEquals(34.0, mean!!, 1e-9)
    }

    @Test
    fun excludesOnChargerAmbientEvenInBed() {
        // Mid-night on charger: HR still has stray worn-range values but skin temp drifts to ambient
        // (~22 °C) — which passes the strap's looser 20–45 decode gate but is below the worn floor.
        val start = 4_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + it) }
        val temps = (0 until 600).map { skin(start + it, 2200) } // 22 °C ambient
        assertNull(AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps))
    }

    @Test
    fun belowMinSamplesIsNull() {
        val start = 5_000_000L
        val sess = listOf(session(start, 100))
        val hrs = (0 until 100).map { hr(start + it) }
        val temps = (0 until 100).map { skin(start + it, 3400) } // only 100 < MIN_SKIN_TEMP_SAMPLES
        assertNull(AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps))
    }

    @Test
    fun emptyInputsAreNull() {
        assertNull(AnalyticsEngine.wornNightlySkinTempC(emptyList(), emptyList(), emptyList()))
    }

    // ── skin-temp funnel diagnostic (#752) ──────────────────────────────────

    /** The kept-path: the funnel's mean is identical to [AnalyticsEngine.wornNightlySkinTempC], and the
     *  drop buckets + kept sum to the total (every sample accounted for once). Mirrors Swift
     *  testFunnelKeptPathMatchesMeanAndAccountsForEverySample. */
    @Test
    fun funnelKeptPathMatchesMeanAndAccountsForEverySample() {
        val start = 6_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + it) }
        val temps = (0 until 600).map { skin(start + it, 3400) } // 34 °C, all worn + in-window
        val f = AnalyticsEngine.skinTempFunnel(sess, hrs, temps)
        assertEquals(600, f.totalSamples)
        assertEquals(600, f.kept)
        assertEquals(f.totalSamples, f.droppedNotWorn + f.droppedOutOfWindow + f.droppedOutOfRange + f.kept)
        assertEquals(34.0, f.mean!!, 1e-9)
        assertFalse(f.isAbsent)
        assertEquals(AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps), f.mean)
    }

    /** 4.0-style "skin temp absent": samples exist but NONE are worn → all loss to droppedNotWorn, mean
     *  absent. Mirrors Swift testFunnelAllNotWornExplainsAbsence. */
    @Test
    fun funnelAllNotWornExplainsAbsence() {
        val start = 7_000_000L
        val sess = listOf(session(start, 600))
        val temps = (0 until 600).map { skin(start + it, 3400) }
        val f = AnalyticsEngine.skinTempFunnel(sess, emptyList(), temps)
        assertEquals(600, f.totalSamples)
        assertEquals(600, f.droppedNotWorn)
        assertEquals(0, f.kept)
        assertTrue(f.isAbsent)
        assertTrue("the summary names the dominant gate: ${f.summary}", f.summary.contains("notWorn=600"))
    }

    /** Worn + in-window samples that drift to ambient (~22 °C) fail the worn-range gate → droppedOutOfRange.
     *  Mirrors Swift testFunnelOutOfRangeIsAttributedToRangeGate. */
    @Test
    fun funnelOutOfRangeIsAttributedToRangeGate() {
        val start = 8_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + it) }
        val temps = (0 until 600).map { skin(start + it, 2200) } // 22 °C ambient
        val f = AnalyticsEngine.skinTempFunnel(sess, hrs, temps)
        assertEquals(600, f.droppedOutOfRange)
        assertEquals(0, f.droppedNotWorn)
        assertEquals(0, f.kept)
        assertTrue(f.isAbsent)
    }

    /** Worn samples outside every in-bed span → droppedOutOfWindow; with NO session, every sample is out of
     *  window (legacy early-return parity). Mirrors Swift testFunnelOutOfWindowAndNoSession. */
    @Test
    fun funnelOutOfWindowAndNoSession() {
        val start = 9_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + 100_000 + it) }
        val temps = (0 until 600).map { skin(start + 100_000 + it, 3400) }
        val f = AnalyticsEngine.skinTempFunnel(sess, hrs, temps)
        assertEquals(600, f.droppedOutOfWindow)
        assertEquals(0, f.kept)
        assertTrue(f.isAbsent)
        val none = AnalyticsEngine.skinTempFunnel(emptyList(), hrs, temps)
        assertEquals(600, none.droppedOutOfWindow)
        assertTrue(none.isAbsent)
    }

    /** Below the min-samples floor: every sample kept but the mean is still absent (last gate); kept reports
     *  the survivor count. Mirrors Swift testFunnelBelowMinSamplesKeepsButMeanAbsent. */
    @Test
    fun funnelBelowMinSamplesKeepsButMeanAbsent() {
        val start = 10_000_000L
        val sess = listOf(session(start, 100))
        val hrs = (0 until 100).map { hr(start + it) }
        val temps = (0 until 100).map { skin(start + it, 3400) } // 100 < MIN_SKIN_TEMP_SAMPLES
        val f = AnalyticsEngine.skinTempFunnel(sess, hrs, temps)
        assertEquals(100, f.kept)
        assertTrue(f.minSamples > 100)
        assertTrue("kept < minSamples → no trusted mean", f.isAbsent)
    }

    // ── device-family-aware conversion (#938) ───────────────────────────────

    /** A WHOOP 4.0 v24 worn night (raw ~840, the reporter's steady worn baseline) produced NO nightly mean
     *  under the old family-blind /100 (8.4 °C, below the 28 °C worn gate). With the WHOOP4 scale it lands
     *  ~33.7 °C and the night is kept. Mirrors Swift testWhoop4WornNightProducesMeanUnderFamilyAwareScale. */
    @Test
    fun whoop4WornNightProducesMeanUnderFamilyAwareScale() {
        val start = 11_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + it) }
        val temps = (0 until 600).map { skin(start + it, 840) } // raw 840 (NOT centi-°C for a 4.0)
        assertNull(AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps, DeviceFamily.WHOOP5))
        val mean = AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps, DeviceFamily.WHOOP4)!!
        assertTrue("worn 4.0 night must clear the 28 °C gate, was $mean", mean > 28.0)
        assertTrue("worn 4.0 night must stay under 42 °C, was $mean", mean < 42.0)
    }

    /** A 5/MG worn night is identical whether family is defaulted or passed explicitly. Mirrors Swift
     *  testWhoop5NightUnchangedByFamilyParameter. */
    @Test
    fun whoop5NightUnchangedByFamilyParameter() {
        val start = 12_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + it) }
        val temps = (0 until 600).map { skin(start + it, 3400) } // 34 °C centidegrees
        val defaulted = AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps)!!
        val explicit = AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps, DeviceFamily.WHOOP5)!!
        assertEquals(34.0, defaulted, 1e-9)
        assertEquals(defaulted, explicit, 1e-12)
    }

    /** The funnel diagnostic reports the SAME family-aware outcome: a worn 4.0 night is kept under WHOOP4 but
     *  all-out-of-range under the family-blind WHOOP5 scale. Mirrors Swift testFunnelFamilyAwareAttribution. */
    @Test
    fun funnelFamilyAwareAttribution() {
        val start = 13_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + it) }
        val temps = (0 until 600).map { skin(start + it, 840) }
        val w5 = AnalyticsEngine.skinTempFunnel(sess, hrs, temps, DeviceFamily.WHOOP5)
        assertEquals(600, w5.droppedOutOfRange)
        assertTrue(w5.isAbsent)
        val w4 = AnalyticsEngine.skinTempFunnel(sess, hrs, temps, DeviceFamily.WHOOP4)
        assertEquals(600, w4.kept)
        assertFalse(w4.isAbsent)
    }

    // ── per-device worn anchor, end-to-end (#938 second capture) ─────────────

    /** A second real 4.0 strap: worn raws ~1250–1330 (nightly mean raw ~1290). Under the GLOBAL 826 anchor
     *  those map to ~54–58 °C, all failing the 28–42 °C worn gate (kept=0, no mean). With the device's OWN
     *  learned anchor the worn band lands ~33 °C and the night is kept. Mirrors Swift
     *  testHighRegisterDeviceKeptWithLearnedAnchor. */
    @Test
    fun highRegisterDeviceKeptWithLearnedAnchor() {
        val start = 20_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + it) }
        // 600 worn samples sweeping raw 1250..1329 (nightly mean ~1290), a whole session inside worn seconds.
        val temps = (0 until 600).map { skin(start + it, 1250 + (it % 80)) }
        val anchor = Whoop4SkinTemp.deviceAnchorRaw(temps.map { it.raw })!!
        // GLOBAL anchor (null → 826): every worn raw maps to ~54–58 °C, all out of range → absent.
        assertNull(AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps, DeviceFamily.WHOOP4, null))
        // LEARNED anchor: kept, and the mean sits in the plausible worn band ≈ 33 °C.
        val mean = AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps, DeviceFamily.WHOOP4, anchor)!!
        assertTrue("worn high-register 4.0 night must clear the 28 °C gate, was $mean", mean > 28.0)
        assertTrue("worn high-register 4.0 night must stay under 42 °C, was $mean", mean < 42.0)
        assertEquals("mean sits near the anchor's 33.0 °C", 33.0, mean, 1.5)
    }

    /** Two nights whose raw means differ by +20, converted with the SAME window-wide anchor → nightly °C
     *  means differ by exactly +1.0 (20 × 0.05 slope). This is WHY the anchor is window-wide, not per-night:
     *  the shared constant offset cancels, leaving the true cross-night deviation intact. Mirrors Swift
     *  testDeviationPreservedAcrossNightsWithSameAnchor. */
    @Test
    fun deviationPreservedAcrossNightsWithSameAnchor() {
        val anchor = 1290.0
        fun nightMean(startTs: Long, raw: Int): Double {
            val sess = listOf(session(startTs, 600))
            val hrs = (0 until 600).map { hr(startTs + it) }
            val temps = (0 until 600).map { skin(startTs + it, raw) }
            return AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps, DeviceFamily.WHOOP4, anchor)!!
        }
        val n1 = nightMean(21_000_000L, 1290)
        val n2 = nightMean(22_000_000L, 1310) // +20 raw
        assertEquals(1.0, n2 - n1, 1e-9)
    }

    /** Byte-compat: WHOOP4 with anchorRaw=null and reporter-band raws (~826) produces the IDENTICAL mean as
     *  the explicit global anchor (ANCHOR_RAW=826) — the pre-per-device behaviour. Mirrors Swift
     *  testWhoop4NullAnchorByteIdenticalToGlobal. */
    @Test
    fun whoop4NullAnchorByteIdenticalToGlobal() {
        val start = 23_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + it) }
        val temps = (0 until 600).map { skin(start + it, 826) }
        val nullAnchor = AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps, DeviceFamily.WHOOP4, null)!!
        val explicitGlobal =
            AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps, DeviceFamily.WHOOP4, Whoop4SkinTemp.ANCHOR_RAW)!!
        assertEquals(33.0, nullAnchor, 1e-9) // raw 826 → exactly the 33.0 °C anchor
        assertEquals(explicitGlobal, nullAnchor, 1e-12)
    }

    /** WHOOP5 is unchanged by the anchor parameter: a centidegree night is byte-identical with or without one.
     *  Mirrors Swift testWhoop5IgnoresAnchor. */
    @Test
    fun whoop5IgnoresAnchor() {
        val start = 24_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + it) }
        val temps = (0 until 600).map { skin(start + it, 3400) } // 34 °C centidegrees
        val noAnchor = AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps, DeviceFamily.WHOOP5, null)!!
        val withAnchor = AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps, DeviceFamily.WHOOP5, 1290.0)!!
        assertEquals(34.0, noAnchor, 1e-9)
        assertEquals(noAnchor, withAnchor, 1e-12)
    }

    /** Doff-floor (509) and pegged-saturation (2047) samples on a WHOOP4 night count as outOfRange (dropped
     *  BEFORE the anchor map) and the four buckets + kept still sum to totalSamples. Mirrors Swift
     *  testWhoop4FloorAndSaturationCountAsOutOfRange. */
    @Test
    fun whoop4FloorAndSaturationCountAsOutOfRangeAndBucketsSum() {
        val start = 25_000_000L
        val sess = listOf(session(start, 900))
        val hrs = (0 until 900).map { hr(start + it) }
        val worn = (0 until 600).map { skin(start + it, 1290) }        // in-band worn
        val floor = (600 until 750).map { skin(start + it, 509) }      // no-contact floor
        val pegged = (750 until 900).map { skin(start + it, 2047) }    // 11-bit saturation
        val temps = worn + floor + pegged
        val anchor = Whoop4SkinTemp.deviceAnchorRaw(temps.map { it.raw })!! // learned from the 600 in-band raws
        val f = AnalyticsEngine.skinTempFunnel(sess, hrs, temps, DeviceFamily.WHOOP4, anchor)
        assertEquals(900, f.totalSamples)
        assertEquals(300, f.droppedOutOfRange) // 150 floor + 150 saturation, out of the plausible worn ADC band
        assertEquals(600, f.kept)
        assertEquals(f.totalSamples, f.droppedNotWorn + f.droppedOutOfWindow + f.droppedOutOfRange + f.kept)
    }

    // ── seed → deviation (skin_temp baseline) ───────────────────────────────

    private val skinCfg = Baselines.metricCfg.getValue("skin_temp")

    @Test
    fun coldStart_belowSeed_baselineNotUsable() {
        // 3 nightly means (< minNightsSeed = 4): still CALIBRATING → skinTempDevC stays null.
        val nights: List<Double?> = listOf(33.5, 33.6, 33.4)
        assertFalse(Baselines.foldHistory(nights, skinCfg).usable)
    }

    @Test
    fun atSeed_usable_elevationShowsPositiveDeviation() {
        // 4 baseline nights ~33.5 °C; a +0.8 °C night surfaces as a clearly positive deviation —
        // the signal IllnessWatch reads as its skin-temp flag (fires at ≥ +0.6 °C).
        val nights: List<Double?> = listOf(33.5, 33.4, 33.6, 33.5)
        val base = Baselines.foldHistory(nights, skinCfg)
        assertTrue("4 valid nights must seed a usable skin-temp baseline", base.usable)
        val dev = Baselines.deviation(34.3, base).delta
        assertTrue("a +0.8 °C night must read as a clear positive deviation, was $dev", dev > 0.5)
    }

    /** #skin-diag: WHOOP 4.0 raw-band + resolved-anchor visibility. A worn night whose raws sit at 1290
     *  (in the 550–2040 worn band) maps to ~56 °C under the GLOBAL 826 anchor → every worn sample fails the
     *  28–42 °C gate (absent), but to 33 °C under the per-device anchor → kept. The new fields surface the
     *  raw band + which anchor resolved, so an absent 4.0 skin temp explains WHY. Mirrors the Swift twin. */
    @Test
    fun funnelSurfacesRawBandAndResolvedAnchorWhoop4() {
        val start = 10_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + it) }
        val temps = (0 until 600).map { skin(start + it, 1290) }

        // Global 826 fallback (no anchor passed): p50 1290 → ~56 °C → all out of range, mean absent.
        val g = AnalyticsEngine.skinTempFunnel(sess, hrs, temps, DeviceFamily.WHOOP4)
        assertEquals(1290, g.rawMin)
        assertEquals(1290, g.rawMedian)
        assertEquals(1290, g.rawMax)
        assertEquals(600, g.inBandCount)
        assertEquals(Whoop4SkinTemp.ANCHOR_RAW, g.resolvedAnchorRaw!!, 1e-9)
        assertTrue("p50 must map above the 42 °C gate: ${g.medianMappedC}", g.medianMappedC!! > 42.0)
        assertEquals(600, g.droppedOutOfRange)
        assertTrue(g.isAbsent)
        assertTrue("summary carries the raw line: ${g.summary}",
            g.summary.contains("skin-temp-raw: raw[min=1290 p50=1290 max=1290]"))

        // Per-device anchor 1290: p50 → 33 °C → in range → kept, mean present.
        val d = AnalyticsEngine.skinTempFunnel(sess, hrs, temps, DeviceFamily.WHOOP4, 1290.0)
        assertEquals(1290.0, d.resolvedAnchorRaw!!, 1e-9)
        assertEquals(33.0, d.medianMappedC!!, 0.01)
        assertEquals(600, d.kept)
        assertFalse(d.isAbsent)
    }

    /** #skin-diag: the new observation fields never perturb the gate/mean — a kept-path night's mean stays
     *  byte-identical to [AnalyticsEngine.wornNightlySkinTempC], and 5/MG carries no anchor. */
    @Test
    fun funnelRawBandFieldsDoNotChangeMean() {
        val start = 11_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + it) }
        val temps = (0 until 600).map { skin(start + it, 3400) }
        val f = AnalyticsEngine.skinTempFunnel(sess, hrs, temps) // WHOOP5 default
        assertEquals(AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps), f.mean)
        assertNull("5/MG centidegree path has no anchor", f.resolvedAnchorRaw)
        assertEquals(3400, f.rawMedian)
    }

    // ── on-wrist charging contamination (twin of Swift SkinTempAnalyticsTests) ──────────────────────

    private fun event(ts: Long, kind: String) =
        EventRow(deviceId = dev, ts = ts, kind = kind, payloadJSON = "{}")

    /**
     * The WHOOP 5/MG battery pack slides onto the strap while it stays ON THE WRIST, so a charge does NOT
     * drift to cold ambient — it HEATS the sensor. Reproduces the real shape of the 2026-07-29→30 night:
     * worn HR throughout, one in-bed span, ~39 °C while the pack is attached and ~33.5 °C after it comes
     * off. Every pre-existing gate ADMITS the hot samples, so without a charge gate the nightly mean is
     * dragged up by the artifact.
     */
    @Test
    fun chargeIntervalDroppedSoNightlyMeanReflectsUnchargedPortionOnly() {
        val start = 13_000_000L
        val chargeStart = start + 600
        val chargeEnd = start + 3_600
        val sess = listOf(session(start, 4_800))
        val hrs = (0 until 4_800).map { hr(start + it) }     // worn the WHOLE time, charging included
        val temps = (0 until 4_800).map {
            val ts = start + it
            skin(ts, if (ts in chargeStart until chargeEnd) 3_900 else 3_350)   // 39.0 °C vs 33.5 °C
        }
        val charge = listOf(chargeStart to chargeEnd)

        val contaminated = AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps)!!
        assertTrue("the 39 °C on-charger span must be what poisons the mean", contaminated > 34.0)

        val mean = AnalyticsEngine.wornNightlySkinTempC(
            sess, hrs, temps, DeviceFamily.WHOOP5, null, charge,
        )!!
        assertEquals(33.5, mean, 1e-9)

        val f = AnalyticsEngine.skinTempFunnel(
            sess, hrs, temps, DeviceFamily.WHOOP5, null, charge,
        )
        assertEquals(3_000, f.droppedCharging)
        assertEquals(1_800, f.kept)
        assertEquals("HR streams throughout — this is NOT an off-wrist night", 0, f.droppedNotWorn)
        assertEquals("39 °C is inside 28–42 °C — the range gate cannot catch this", 0, f.droppedOutOfRange)
        assertEquals(
            f.totalSamples,
            f.droppedNotWorn + f.droppedOutOfWindow + f.droppedCharging + f.droppedOutOfRange + f.kept,
        )
        assertTrue("the summary names the charge gate: ${f.summary}", f.summary.contains("charging=3000"))
    }

    /** No charge intervals ⇒ byte-identical to the pre-change behaviour. */
    @Test
    fun emptyChargeIntervalsAreByteIdenticalToPriorBehaviour() {
        val start = 14_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + it) }
        val temps = (0 until 600).map { skin(start + it, 3_400) }
        val defaulted = AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps)!!
        val explicitEmpty = AnalyticsEngine.wornNightlySkinTempC(
            sess, hrs, temps, DeviceFamily.WHOOP5, null, emptyList(),
        )!!
        assertEquals(defaulted, explicitEmpty, 0.0)
        assertEquals(0, AnalyticsEngine.skinTempFunnel(sess, hrs, temps).droppedCharging)
    }

    /**
     * THE TRAP, straight from the real night: CHARGING_ON/CHARGING_OFF toggled 15 times inside ONE
     * continuous BATTERY_PACK_CONNECTED→REMOVED span, and the sensor stayed hot through every
     * CHARGING_OFF gap — the pack is still physically attached, the charge current merely paused.
     */
    @Test
    fun packSpanCoversChargingOffGaps() {
        val t = 1_785_386_564L
        val events = listOf(
            event(t, "BATTERY_PACK_CONNECTED(21)"),
            event(t, "CHARGING_ON(7)"),
            event(t + 898, "CHARGING_OFF(8)"),
            event(t + 1_520, "CHARGING_ON(7)"),
            event(t + 1_895, "CHARGING_OFF(8)"),
            event(t + 15_342, "BATTERY_PACK_REMOVED(22)"),
        )
        val intervals = AnalyticsEngine.chargeIntervals(events, t + 20_000)
        assertEquals("the toggles merge into the single pack span: $intervals", 1, intervals.size)
        assertEquals(t, intervals[0].first)
        assertEquals(t + 15_342, intervals[0].second)
    }

    /** CHARGING_ON alone still opens an interval; a span open at the window end closes at windowEnd. */
    @Test
    fun chargingOnlyEventsAndUnclosedSpan() {
        val t = 2_000_000L
        val closed = AnalyticsEngine.chargeIntervals(
            listOf(event(t, "CHARGING_ON(7)"), event(t + 300, "CHARGING_OFF(8)")), t + 9_999,
        )
        assertEquals(1, closed.size)
        assertEquals(t + 300, closed[0].second)
        val open = AnalyticsEngine.chargeIntervals(listOf(event(t, "BATTERY_PACK_CONNECTED(21)")), t + 5_000)
        assertEquals(1, open.size)
        assertEquals(t + 5_000, open[0].second)
        assertTrue(
            AnalyticsEngine.chargeIntervals(
                listOf(event(t, "WRIST_OFF(10)"), event(t + 10, "BOOT(1)")), t + 100,
            ).isEmpty(),
        )
    }

    /**
     * The events-missing fallback: a RATE test (pp per hour), which separates a ~20 pp/h charge from a
     * ~1.65 pp/h discharge at any cadence — unlike a fixed per-reading step, which never fires at the
     * real ~30 s cadence.
     */
    @Test
    fun socRiseInfersChargeWhenEventsAreMissing() {
        val t = 3_000_000L
        val rising = (0..16_200 step 30).map { (t + it) to (9.4 + it * 0.0056) }
        val inferred = AnalyticsEngine.chargeIntervalsFromSoc(rising)
        assertEquals("a sustained rise is ONE charge interval: $inferred", 1, inferred.size)
        assertTrue(inferred[0].first <= t + 60)
        assertTrue(inferred[0].second >= t + 16_000)
        val falling = (0..28_800 step 30).map { (t + it) to (90.0 - it * 0.00046) }
        assertTrue(
            "a ~1.65 pp/h discharge is not a charge",
            AnalyticsEngine.chargeIntervalsFromSoc(falling).isEmpty(),
        )
    }
}
