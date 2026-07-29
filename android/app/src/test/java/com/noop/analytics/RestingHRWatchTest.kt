package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirror of the Swift RestingHRWatchTests — identical inputs and expected outputs (parity guard).
 */
class RestingHRWatchTest {

    private fun flat(n: Int, v: Double = 50.0): List<Double?> = List(n) { v }

    // ── Cold start ──

    @Test
    fun tooLittleHistoryStaysQuiet() {
        val r = RestingHRWatch.evaluate(flat(6) + listOf(70.0))
        assertEquals(RestingHRWatch.Level.QUIET, r.level)
        assertNull("no median may be reported below the history floor", r.medianBPM)
        assertEquals(0, r.consecutiveElevatedNights)
    }

    @Test
    fun raisesOnTheNinthNight() {
        // 7 prior nights is the floor, so two elevated nights on top = 9 total is the EARLIEST raise.
        val r = RestingHRWatch.evaluate(flat(7) + listOf(56.0, 57.0))
        assertEquals(RestingHRWatch.Level.RAISED, r.level)
        assertEquals(2, r.consecutiveElevatedNights)
    }

    // ── Persistence is the false-positive suppressor ──

    @Test
    fun singleElevatedNightDoesNotRaise() {
        val r = RestingHRWatch.evaluate(flat(20) + listOf(60.0))
        assertEquals(RestingHRWatch.Level.QUIET, r.level)
        assertEquals(1, r.consecutiveElevatedNights)
        assertEquals(10.0, r.deltaBPM!!, 1e-9)
    }

    @Test
    fun twoConsecutiveElevatedNightsRaise() {
        val r = RestingHRWatch.evaluate(flat(20) + listOf(56.0, 56.0))
        assertEquals(RestingHRWatch.Level.RAISED, r.level)
        assertEquals(2, r.consecutiveElevatedNights)
    }

    @Test
    fun elevationThatRecoversDoesNotRaise() {
        val r = RestingHRWatch.evaluate(flat(20) + listOf(58.0, 58.0, 50.0))
        assertEquals(RestingHRWatch.Level.QUIET, r.level)
        assertEquals(0, r.consecutiveElevatedNights)
    }

    // ── The threshold is absolute and ONE-SIDED ──

    @Test
    fun justUnderTheOffsetDoesNotFire() {
        val r = RestingHRWatch.evaluate(flat(20) + listOf(53.9, 53.9))
        assertEquals(RestingHRWatch.Level.QUIET, r.level)
    }

    @Test
    fun exactlyAtTheOffsetFires() {
        val r = RestingHRWatch.evaluate(flat(20) + listOf(54.0, 54.0))
        assertEquals(RestingHRWatch.Level.RAISED, r.level)
    }

    /** THE ONE-SIDEDNESS GUARD. Deeply below the median is the HEALTHY direction and must never fire. */
    @Test
    fun deeplyBelowMedianNeverRaises() {
        val r = RestingHRWatch.evaluate(flat(20) + listOf(38.0, 37.0, 36.0, 35.0))
        assertEquals(RestingHRWatch.Level.QUIET, r.level)
        assertEquals(0, r.consecutiveElevatedNights)
        assertTrue(r.deltaBPM!! < 0)
        assertNull("the healthy direction must produce no copy", RestingHRWatch.copy(r))
    }

    // ── Baseline mechanics ──

    @Test
    fun medianIsTakenBeforeTonightSoAnElevationCannotPropUpItsOwnBaseline() {
        val r = RestingHRWatch.evaluate(flat(20) + listOf(56.0, 56.0))
        assertEquals(50.0, r.medianBPM!!, 1e-9)
    }

    /** A median does NOT widen when an outlier lands in it — the property the EWMA-spread lacks. */
    @Test
    fun sustainedElevationDoesNotSuppressItself() {
        val r = RestingHRWatch.evaluate(flat(20) + List(6) { 58.0 })
        assertEquals(RestingHRWatch.Level.RAISED, r.level)
        assertEquals(6, r.consecutiveElevatedNights)
        assertTrue(
            "the delta must not decay as the elevation persists",
            r.deltaBPM!! >= RestingHRWatch.offsetBPM,
        )
    }

    @Test
    fun missingNightsAreSkippedNotTreatedAsZero() {
        val r = RestingHRWatch.evaluate(flat(20) + listOf(56.0, null, 56.0))
        assertEquals(RestingHRWatch.Level.RAISED, r.level)
        assertEquals(50.0, r.medianBPM!!, 1e-9)
    }

    @Test
    fun emptyHistoryIsQuietNotACrash() {
        val r = RestingHRWatch.evaluate(emptyList())
        assertEquals(RestingHRWatch.Level.QUIET, r.level)
        assertNull(r.deltaBPM)
        assertEquals(0, r.consecutiveElevatedNights)
    }

    @Test
    fun allNullHistoryIsQuiet() {
        val r = RestingHRWatch.evaluate(List(30) { null })
        assertEquals(RestingHRWatch.Level.QUIET, r.level)
    }

    // ── Copy safety (wellness framing, never a diagnosis) ──

    @Test
    fun copyNeverNamesAConditionAndCarriesTheDisclaimer() {
        val r = RestingHRWatch.evaluate(flat(20) + listOf(58.0, 58.0))
        val copy = RestingHRWatch.copy(r)
        assertNotNull(copy)
        assertTrue(copy!!.endsWith(IllnessSignalEngine.disclaimerTail))
        // Check the AUTHORED body only — the mandatory disclaimer tail necessarily contains "diagnosis".
        val body = copy.replace(IllnessSignalEngine.disclaimerTail, "").lowercase()
        for (banned in listOf(
            "illness", "infection", "fever", "sick", "virus", "flu", "covid", "diagnos", "disease",
        )) {
            assertFalse("copy must never name a condition, found '$banned' in: $copy", body.contains(banned))
        }
    }

    // ── Real-history regression (shape of a measured event, not the user's data) ──

    @Test
    fun realShapedEventRaisesOnTheSecondElevatedNight() {
        val runIn = flat(9)
        assertEquals(
            "a single elevated night must not fire, even at onset",
            RestingHRWatch.Level.QUIET,
            RestingHRWatch.evaluate(runIn + listOf(55.0)).level,
        )
        val r = RestingHRWatch.evaluate(runIn + listOf(55.0, 58.0))
        assertEquals(RestingHRWatch.Level.RAISED, r.level)
        assertEquals(2, r.consecutiveElevatedNights)
    }

    @Test
    fun healthyLowStretchAfterTheEventStaysQuiet() {
        val r = RestingHRWatch.evaluate(flat(20, 49.0) + listOf(44.0, 41.0, 43.0, 44.0))
        assertEquals(RestingHRWatch.Level.QUIET, r.level)
        assertEquals(0, r.consecutiveElevatedNights)
    }
}
