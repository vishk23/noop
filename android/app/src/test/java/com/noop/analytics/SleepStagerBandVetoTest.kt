package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.ceil

/**
 * Pins the H9 @73 band-state WAKE-veto ([SleepStager.applyBandStateWakeVeto]).
 *
 * NOOP's EEG-free cardiorespiratory stager over-calls WAKE. WHOOP's OWN per-second sleep-state band (#175)
 * is an independent scored signal; letting its explicit "asleep" ([SleepStager.bandStateAsleep]) verdict
 * VETO an INTERIOR wake epoch recovers most of that spurious wake with near-zero downside. These tests pin
 * the contract: only asleep(2) vetoes (still/up/wake never do), the leading onset-latency and trailing
 * final-wake blocks are never touched, recovery is per-EPOCH, an absent band is a no-op, the output keeps
 * tiling [start,end], and the veto only ever turns wake into sleep. Android twin of the Swift H9
 * band-state wake-veto tests in `SleepStagerTests`.
 */
class SleepStagerBandVetoTest {

    /**
     * A hypnogram tiling [0, 960] (32 epochs of 30 s): a leading onset-latency wake block, an INTERIOR
     * WASO wake block (epochs 10–15 = [300, 480)), and a trailing final-morning wake block — the exact
     * shape the veto must treat differently at the edges vs the interior.
     */
    private fun vetoHypnoFixture(): List<StageSegment> = listOf(
        StageSegment(start = 0, end = 60, stage = "wake"),      // epochs 0–1  (onset latency)
        StageSegment(start = 60, end = 300, stage = "light"),   // epochs 2–9
        StageSegment(start = 300, end = 480, stage = "wake"),   // epochs 10–15 (interior WASO)
        StageSegment(start = 480, end = 900, stage = "light"),  // epochs 16–29
        StageSegment(start = 900, end = 960, stage = "wake"),   // epochs 30–31 (final wake)
    )

    /** One band sample per 30 s epoch carrying the given [states] (the shape sessionEpochSleepState grids). */
    private fun bandSamples(start: Long, states: List<Int>): List<Pair<Long, Int>> =
        states.mapIndexed { i, s -> (start + i * 30L) to s }

    private fun bandAllAsleep(start: Long, end: Long): List<Pair<Long, Int>> {
        val n = maxOf(1, ceil((end - start).toDouble() / 30.0).toInt())
        return (0 until n).map { (start + it * 30L) to 2 }
    }

    @Test
    fun recoversInteriorFalseWake() {
        // The strap's OWN band reads "asleep" (2) across the WHOLE night. The interior WASO block is
        // recovered to light (and merges with the flanking light); the leading onset-latency and trailing
        // final-wake blocks are NEVER touched even though the band scored them asleep too.
        val out = SleepStager.applyBandStateWakeVeto(
            vetoHypnoFixture(), start = 0, end = 960,
            bandSleepState = bandAllAsleep(start = 0, end = 960),
        )
        assertEquals(
            "interior @73-asleep wake -> light (merged); onset-latency + final-wake blocks stay wake",
            listOf(
                StageSegment(start = 0, end = 60, stage = "wake"),
                StageSegment(start = 60, end = 900, stage = "light"),
                StageSegment(start = 900, end = 960, stage = "wake"),
            ),
            out,
        )
    }

    @Test
    fun onlyAsleepStateVetoes() {
        // Interior wake epochs 10–15 get band states still(1)/up(3)/wake(0) — none is asleep(2) — so NONE
        // is recovered. (Sleep + edge epochs are asleep(2) but the veto only ever looks at wake epochs, and
        // the edges are excluded.) The hypnogram is returned byte-identical.
        val states = MutableList(32) { 2 }
        val block = listOf(1, 1, 3, 3, 0, 0)
        for ((k, i) in (10..15).withIndex()) states[i] = block[k]
        val out = SleepStager.applyBandStateWakeVeto(
            vetoHypnoFixture(), start = 0, end = 960,
            bandSleepState = bandSamples(start = 0, states = states),
        )
        assertEquals(
            "still/up/wake band never vetoes — only the strap's explicit asleep(2) does",
            vetoHypnoFixture(), out,
        )
    }

    @Test
    fun partialInteriorRecovery() {
        // Per-EPOCH: within the interior WASO block, only epochs 10–12 are asleep(2); 13–15 are up(3). The
        // block splits — [300,390) recovered to light, [390,480) stays wake — proving epoch granularity.
        val states = MutableList(32) { 2 }
        for (i in 13..15) states[i] = 3
        val out = SleepStager.applyBandStateWakeVeto(
            vetoHypnoFixture(), start = 0, end = 960,
            bandSleepState = bandSamples(start = 0, states = states),
        )
        assertEquals(
            "only the asleep-banded sub-run of an interior wake block is recovered",
            listOf(
                StageSegment(start = 0, end = 60, stage = "wake"),
                StageSegment(start = 60, end = 390, stage = "light"),
                StageSegment(start = 390, end = 480, stage = "wake"),
                StageSegment(start = 480, end = 900, stage = "light"),
                StageSegment(start = 900, end = 960, stage = "wake"),
            ),
            out,
        )
    }

    @Test
    fun noOpWhenBandAbsent() {
        // No band stream (WHOOP 4.0 / unbanded window) → byte-identical hypnogram, whatever the flag.
        assertEquals(
            "absent band → veto is a no-op",
            vetoHypnoFixture(),
            SleepStager.applyBandStateWakeVeto(
                vetoHypnoFixture(), start = 0, end = 960, bandSleepState = emptyList(),
            ),
        )
        // Band entirely outside the window grids to empty → also a no-op (never fabricates asleep).
        assertEquals(
            vetoHypnoFixture(),
            SleepStager.applyBandStateWakeVeto(
                vetoHypnoFixture(), start = 0, end = 960, bandSleepState = listOf(100_000L to 2),
            ),
        )
    }

    @Test
    fun preservesTilingAndOnlyRemovesWake() {
        assertTrue("H9 veto ships default-ON", SleepStager.bandStateWakeVetoEnabled)
        val stages = vetoHypnoFixture()
        val out = SleepStager.applyBandStateWakeVeto(
            stages, start = 0, end = 960, bandSleepState = bandAllAsleep(start = 0, end = 960),
        )
        assertEquals(0L, out.first().start)
        assertEquals(960L, out.last().end)
        for (i in 1 until out.size) {
            assertEquals("segments tile [start,end] with no gaps/overlaps", out[i - 1].end, out[i].start)
        }
        val wake = { segs: List<StageSegment> -> segs.filter { it.stage == "wake" }.sumOf { it.end - it.start } }
        assertTrue("the veto only ever turns wake into sleep", wake(out) < wake(stages))
    }
}
