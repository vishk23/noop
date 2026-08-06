package com.noop.analytics

import com.noop.data.EventRow
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Byte-parity twin of Swift `StrapLivenessTests`. Every fixture is the shape of a real, verified span from
 * the 2026-06-26→08-06 corpus.
 */
class StrapLivenessTest {

    private val dev = "my-whoop"
    private fun beat(ts: Long) =
        EventRow(deviceId = dev, ts = ts, kind = "STRAP_CONDITION_REPORT(29)", payloadJSON = "{}")
    private fun hr(ts: Long, bpm: Int = 60) = HrSample(deviceId = dev, ts = ts, bpm = bpm)

    /** Worn and collecting: the heartbeat beats and HR flows. */
    @Test
    fun heartbeatWithHRIsCollecting() {
        val t = 1_785_000_000L
        val events = (0 until 3_600 step 600).map { beat(t + it) }
        val samples = (0 until 3_600).map { hr(t + it) }
        val bins = StrapLiveness.timeline(events, samples, t, t + 3_600)
        assertEquals(4, bins.size)                          // 3600 / 900
        assertTrue("$bins", bins.all { it.state == StrapLiveness.State.COLLECTING })
        assertEquals(3_600L, StrapLiveness.summarize(bins).collectingSeconds)
    }

    /**
     * THE CASE THIS TYPE EXISTS FOR — the real 2026-08-01T22:53:30Z→08-02T01:40:18Z off-wrist episode. 167
     * minutes bounded to the second by WRIST_OFF/WRIST_ON, during which the strap logged 16
     * STRAP_CONDITION_REPORTs and HR was absent. That is ALIVE_NOT_WORN: an honest absence, NOT a gap to go
     * hunting for. Before this it was indistinguishable from a dead strap.
     */
    @Test
    fun heartbeatWithoutHRIsAliveNotWorn() {
        val start = 1_785_624_810L                          // 2026-08-01T22:53:30Z
        val end = start + 10_008L                           // 08-02T01:40:18Z, the verified 10,008 s
        val events = (0 until 10_008 step 600).map { beat(start + it) }
        assertEquals("the real episode carried ~16 reports at a ~600 s cadence", 17, events.size)
        val bins = StrapLiveness.timeline(events, emptyList(), start, end)
        assertTrue("$bins", bins.all { it.state == StrapLiveness.State.ALIVE_NOT_WORN })
        val s = StrapLiveness.summarize(bins)
        assertEquals(10_008L, s.aliveNotWornSeconds)
        assertEquals(0L, s.collectingSeconds)
        assertEquals(0L, s.silentSeconds)
    }

    /**
     * THE REGRESSION THE REAL DATA CAUGHT. That same 167-minute off-wrist episode carried exactly ONE HR
     * sample in 10,008 s. Under an "any HR at all" rule that single stray sample flipped the entire episode
     * to COLLECTING, which is the precise confusion this type exists to remove. Coverage — not presence — is
     * the test.
     */
    @Test
    fun oneStrayHRSampleDoesNotDefeatAliveNotWorn() {
        val start = 1_785_624_810L
        val end = start + 10_008L
        val events = (0 until 10_008 step 600).map { beat(start + it) }
        val bins = StrapLiveness.timeline(events, listOf(hr(start + 5_000)), start, end)
        assertTrue("one sample in 167 min is not 'worn': $bins",
            bins.all { it.state == StrapLiveness.State.ALIVE_NOT_WORN })
        assertEquals(10_008L, StrapLiveness.summarize(bins).aliveNotWornSeconds)
    }

    /**
     * The threshold sits in a measured empty gap: across the corpus no bin fell between 5 % and 20 %
     * coverage, so any value in [0.05, 0.20) classifies identically. Pin both sides of it.
     */
    @Test
    fun coverageThresholdSeparatesWornFromNotWorn() {
        val t = 1_785_000_000L
        val events = listOf(beat(t), beat(t + 600))
        // 4 % coverage (36 samples in 900 s) — below the bar, not worn.
        val sparse = (0 until 36).map { hr(t + it * 25L) }
        assertEquals(
            StrapLiveness.State.ALIVE_NOT_WORN,
            StrapLiveness.timeline(events, sparse, t, t + 900).first().state,
        )
        // 50 % coverage (450 samples in 900 s) — above the bar, worn.
        val dense = (0 until 450).map { hr(t + it * 2L) }
        assertEquals(
            StrapLiveness.State.COLLECTING,
            StrapLiveness.timeline(events, dense, t, t + 900).first().state,
        )
        assertEquals(0.10, StrapLiveness.WORN_HR_COVERAGE, 0.0001)
    }

    /**
     * The 2026-07-05T04:31:23Z→07-09T23:23:48Z dead span: 114 h 52 m in which the strap emitted 10
     * heartbeats where the cadence predicts ~689, and 2026-07-06/07/08 carried ZERO events and ZERO HR.
     * This is the one state that means "go look for missing data".
     */
    @Test
    fun noHeartbeatIsSilentEvenThoughSomeEventsExist() {
        val start = 1_783_225_883L                          // 2026-07-05T04:31:23Z
        val end = start + 413_545L                          // 07-09T23:23:48Z
        val events = (0 until 10).map { beat(start + it * 600L) }
        val bins = StrapLiveness.timeline(events, emptyList(), start, end)
        val s = StrapLiveness.summarize(bins)
        assertTrue("the span must read overwhelmingly silent: ${s.silentSeconds}", s.silentSeconds > 400_000L)
        assertEquals(10, s.heartbeats)
        assertEquals("413,545 s / 600 s — the ratio is what makes it legible", 689L, s.expectedHeartbeats)
        assertTrue(s.summary, s.summary.contains("Diagnostic only"))
    }

    /**
     * Jitter must not fake a death. The real cadence is ~600 s but only ~35 % of inter-arrivals are exactly
     * 600, so a 600 s bin can straddle two beats and leave one empty. At the 1.5× default a beat drifting by
     * ±5 s (the observed 595–605 s band) never empties a bin.
     */
    @Test
    fun cadenceJitterDoesNotProduceFalseSilent() {
        val t = 1_785_000_000L
        var ts = t
        val events = ArrayList<EventRow>()
        for (i in 0 until 40) {
            events.add(beat(ts))
            ts += if (i % 2 == 0) 595L else 605L
        }
        val samples = (0 until 24_000).map { hr(t + it) }
        val bins = StrapLiveness.timeline(events, samples, t, t + 24_000)
        assertFalse(
            "jitter inside 595–605 s must not read as silent: ${bins.filter { it.state == StrapLiveness.State.SILENT }}",
            bins.any { it.state == StrapLiveness.State.SILENT },
        )
    }

    /**
     * Bins tile the window exactly: contiguous, half-open, and the LAST ONE ABSORBS the remainder rather
     * than being clipped short. A clipped 200 s tail could not contain a ~600 s-cadence beat, so it would
     * report SILENT at the end of every healthy window for a purely arithmetic reason.
     */
    @Test
    fun lastBinAbsorbsTheRemainderInsteadOfBeingClipped() {
        val t = 1_000_000L
        val span = 2_000L                                   // 2 × 900 + 200
        val bins = StrapLiveness.timeline(emptyList(), emptyList(), t, t + span)
        assertEquals("the 200 s remainder is absorbed, not left as a third bin: $bins", 2, bins.size)
        assertEquals(t, bins[0].start)
        assertEquals(t + span, bins.last().end)
        assertEquals("the last bin is 900 + the 200 remainder", 1_100L, bins.last().end - bins.last().start)
        assertEquals(span, bins.sumOf { it.end - it.start })
        for (i in 1 until bins.size) {
            assertEquals("bins must be contiguous", bins[i - 1].end, bins[i].start)
        }
        assertEquals(span, StrapLiveness.summarize(bins).totalSeconds)
        // Every bin is at least binSeconds wide — the property the 1.5×-cadence choice rests on.
        assertTrue(bins.all { it.end - it.start >= StrapLiveness.DEFAULT_BIN_SECONDS })
        // A window shorter than one bin is a single bin, not zero and not a sliver.
        val short = StrapLiveness.timeline(emptyList(), emptyList(), t, t + 120)
        assertEquals(1, short.size)
        assertEquals(120L, short[0].end - short[0].start)
    }

    /**
     * Liveness asks whether the strap emitted anything, not whether the beat was plausible. An out-of-band
     * bpm still proves the strap was on a wrist and reporting, so it must NOT read as ALIVE_NOT_WORN — that
     * would recreate the exact ambiguity this type removes.
     */
    @Test
    fun implausibleBpmStillCountsAsCollecting() {
        val t = 1_785_000_000L
        val wild = (0 until 900).map { hr(t + it, bpm = 250) }
        val bins = StrapLiveness.timeline(listOf(beat(t)), wild, t, t + 900)
        assertEquals(
            "liveness asks whether the strap emitted, not whether the beat was plausible",
            StrapLiveness.State.COLLECTING, bins.first().state,
        )
    }

    /** Unsorted input, an empty window and an inverted window must all behave. */
    @Test
    fun unsortedInputAndDegenerateWindows() {
        val t = 1_785_000_000L
        val shuffled = listOf(beat(t + 800), beat(t + 100), beat(t + 400))
        val bins = StrapLiveness.timeline(shuffled, emptyList(), t, t + 900)
        assertEquals(1, bins.size)
        assertEquals("sorting is internal; callers need not pre-sort", 3, bins[0].heartbeats)
        assertTrue(StrapLiveness.timeline(shuffled, emptyList(), t, t).isEmpty())
        assertTrue(StrapLiveness.timeline(shuffled, emptyList(), t, t - 5).isEmpty())
    }

    /**
     * Non-heartbeat events contribute nothing — the corpus banks 36 event kinds and only one is the
     * heartbeat.
     */
    @Test
    fun otherEventKindsAreIgnored() {
        val t = 1_785_000_000L
        val noise = listOf(
            EventRow(deviceId = dev, ts = t + 1, kind = "BATTERY_LEVEL(3)", payloadJSON = "{}"),
            EventRow(deviceId = dev, ts = t + 2, kind = "WRIST_OFF(10)", payloadJSON = "{}"),
            EventRow(deviceId = dev, ts = t + 3, kind = "SET_RTC(16)", payloadJSON = "{}"),
        )
        val bins = StrapLiveness.timeline(noise, listOf(hr(t + 5)), t, t + 900)
        assertEquals("HR without a heartbeat is still silent", StrapLiveness.State.SILENT, bins.first().state)
        assertEquals(0, bins.first().heartbeats)
    }
}
