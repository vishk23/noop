package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [WhoopBleClient.classifyCompletedOffload] — the pure classification exitBackfilling runs on a
 * COMPLETED (HISTORY_COMPLETE) offload. The #214 fix is the `rowsPersisted == 0` arm: before it, the
 * empty-banking signal had ONE shape (console-only across ≥3 diagnostic chunks), so a NEAR-EMPTY
 * metadata-only completion (zero rows persisted, fewer than 3 console frames) slipped through to the
 * silent branch and surfaced no "charge to 100% and reconnect" guidance. Kotlin twin of the macOS
 * EmptyBankingClassifierTests. Banner firing still requires a SUSTAINED streak (EmptySyncTracker, #126).
 */
class EmptyBankingClassifierTest {

    @Test
    fun decodedChunksAreBanking() {
        val (banked, nothing) = WhoopBleClient.classifyCompletedOffload(
            decodedChunks = 5, consoleChunks = 0, rowsPersisted = 120,
        )
        assertTrue(banked)
        assertFalse(nothing)
    }

    @Test
    fun consoleOnlyAcrossManyChunksIsBankedNothing() {
        val (banked, nothing) = WhoopBleClient.classifyCompletedOffload(
            decodedChunks = 0, consoleChunks = 4, rowsPersisted = 0,
        )
        assertFalse(banked)
        assertTrue(nothing)
    }

    // #214 regression case: metadata-only completion — zero rows, FEWER than 3 console frames.
    @Test
    fun metadataOnlyZeroRowsIsBankedNothing() {
        val (banked, nothing) = WhoopBleClient.classifyCompletedOffload(
            decodedChunks = 0, consoleChunks = 0, rowsPersisted = 0,
        )
        assertFalse(banked)
        assertTrue("#214: a metadata-only completion that persisted 0 rows banks nothing", nothing)
    }

    @Test
    fun fewConsoleFramesZeroRowsIsBankedNothing() {
        val (_, nothing) = WhoopBleClient.classifyCompletedOffload(
            decodedChunks = 0, consoleChunks = 2, rowsPersisted = 0,
        )
        assertTrue("#214: < 3 console frames no longer hides a zero-row completion", nothing)
    }

    // Rows persisted (but nothing decoded this pass) is NOT "banked nothing".
    @Test
    fun rowsPersistedIsNotBankedNothing() {
        val (banked, nothing) = WhoopBleClient.classifyCompletedOffload(
            decodedChunks = 0, consoleChunks = 0, rowsPersisted = 40,
        )
        assertTrue(banked)
        assertFalse("rows were persisted — the strap is banking", nothing)
    }

    // The new signal still feeds the SUSTAINED-streak gate: 3 consecutive metadata-only completions are
    // required before the banner trips (the #126 guard is unchanged); a banking cycle clears the streak.
    @Test
    fun metadataOnlyTripsBannerOnlyWhenSustained() {
        val tracker = EmptySyncTracker()   // default threshold 3
        fun recordMetadataOnly(): Boolean {
            val (banked, nothing) = WhoopBleClient.classifyCompletedOffload(0, 0, 0)
            return tracker.recordCompletedSync(bankedSensorRecords = banked, consoleOnly = nothing)
        }
        assertFalse(recordMetadataOnly())
        assertFalse(recordMetadataOnly())
        assertTrue("#214 + #126: three consecutive metadata-only completions trip the guidance",
            recordMetadataOnly())
    }

    // #324/#928 future-dated strap banner — Kotlin twin of the macOS futureDatedStrapBanner tests.

    @Test
    fun futureDatedNewestSurfacesBanner() {
        val now = 1_783_843_824L                    // ~2026-07-12, the reporter's wall clock
        val newest = now + 26_445L * 3600L          // 26445 h ahead — the #324 log's banked frontier
        val banner = WhoopBleClient.futureDatedStrapBanner(newest, now)
        assertNotNull(banner)
        assertTrue(banner!!.contains("set in the future"))
        assertTrue(banner.contains("power-cycle"))
    }

    @Test
    fun currentStrapNoFutureBanner() {
        val now = 1_783_843_824L
        assertEquals(null, WhoopBleClient.futureDatedStrapBanner(now - 3600L, now))
        assertEquals(null, WhoopBleClient.futureDatedStrapBanner(now, now))
    }

    @Test
    fun withinSkewAllowanceNoFutureBanner() {
        val now = 1_783_843_824L
        assertEquals("24 h ahead is within the 48 h allowance — not flagged",
            null, WhoopBleClient.futureDatedStrapBanner(now + 24L * 3600L, now))
        assertTrue("just past 48 h is future-dated",
            WhoopBleClient.futureDatedStrapBanner(now + 49L * 3600L, now) != null)
    }

    @Test
    fun nilNewestNoFutureBanner() {
        assertEquals(null, WhoopBleClient.futureDatedStrapBanner(null, 1_783_843_824L))
    }

    // ---- S8c per-terminal-reason empty-offload copy (emptyOffloadUserCopy) ----

    // A COMPLETED-empty offload states what was observed (finished, nothing handed over) and must not
    // assert the "clock has lost sync" diagnosis the old single string carried unmeasured.
    @Test
    fun completedEmptyCopyStatesObservationNotClockDiagnosis() {
        val copy = WhoopBleClient.emptyOffloadUserCopy(
            terminal = WhoopBleClient.EmptyOffloadTerminal.COMPLETED_EMPTY,
            isWhoop5 = false, hasBankedBeforeOnThisInstall = false, consecutiveEmptySyncs = 3,
        )
        assertNotNull(copy)
        assertTrue(copy!!.contains("without handing over any stored history"))
        assertTrue(copy.contains("3 syncs in a row"))
        assertFalse("a completed-empty offload measures no clock fault - it must not assert one",
            copy.contains("clock has lost sync"))
        assertTrue(copy.contains("Fully charge it to 100%"))
        assertFalse(copy.contains("\u2014"))
    }

    // On a 5/MG the completed-empty remedy chain ends at the in-app Restart (a 4.0 has none, #275).
    @Test
    fun completedEmptyCopyOffersRestartOnlyOnFiveMG() {
        val five = WhoopBleClient.emptyOffloadUserCopy(
            terminal = WhoopBleClient.EmptyOffloadTerminal.COMPLETED_EMPTY,
            isWhoop5 = true, hasBankedBeforeOnThisInstall = true, consecutiveEmptySyncs = 4,
        )
        assertTrue(five!!.contains("restart it from the Devices screen"))
        val four = WhoopBleClient.emptyOffloadUserCopy(
            terminal = WhoopBleClient.EmptyOffloadTerminal.COMPLETED_EMPTY,
            isWhoop5 = false, hasBankedBeforeOnThisInstall = true, consecutiveEmptySyncs = 4,
        )
        assertFalse(four!!.contains("restart"))
    }

    // The 2026-08-03 field case: a 5/MG that HAS banked history on this install times out with zero
    // response. That is a wedged command channel, not "no stored history" - the copy names the timeout
    // and puts the in-app Restart BEFORE the charge ritual (the restart is what actually cleared it).
    @Test
    fun timedOutEmptyOnBankedBeforeFiveMGSuggestsRestartFirst() {
        val copy = WhoopBleClient.emptyOffloadUserCopy(
            terminal = WhoopBleClient.EmptyOffloadTerminal.TIMED_OUT_EMPTY,
            isWhoop5 = true, hasBankedBeforeOnThisInstall = true, consecutiveEmptySyncs = 2,
        )
        assertNotNull(copy)
        assertTrue(copy!!.contains("didn't answer the history request"))
        assertTrue(copy.contains("has handed over history before"))
        assertTrue("the in-app Restart comes before the charge ritual",
            copy.indexOf("Restart it from the Devices screen") < copy.indexOf("fully charging"))
        assertFalse("a timeout observed no answer at all - it must not claim the strap had nothing",
            copy.contains("no stored history"))
        assertFalse(copy.contains("\u2014"))
    }

    // A 5/MG never seen banking keeps the #580 experimental surface (null - not an error).
    @Test
    fun timedOutEmptyOnNeverBankedFiveMGStaysExperimental() {
        assertEquals(null, WhoopBleClient.emptyOffloadUserCopy(
            terminal = WhoopBleClient.EmptyOffloadTerminal.TIMED_OUT_EMPTY,
            isWhoop5 = true, hasBankedBeforeOnThisInstall = false, consecutiveEmptySyncs = 5,
        ))
    }

    // A WHOOP 4.0 timeout keeps the caller's existing "went quiet" copy (no in-app restart exists).
    @Test
    fun timedOutEmptyOnWhoop4ReturnsNull() {
        assertEquals(null, WhoopBleClient.emptyOffloadUserCopy(
            terminal = WhoopBleClient.EmptyOffloadTerminal.TIMED_OUT_EMPTY,
            isWhoop5 = false, hasBankedBeforeOnThisInstall = true, consecutiveEmptySyncs = 2,
        ))
    }

    // A single empty completion reads singular (no "(1 syncs in a row)" grammar slip).
    @Test
    fun completedEmptyCopySingleSyncOmitsStreakClause() {
        val copy = WhoopBleClient.emptyOffloadUserCopy(
            terminal = WhoopBleClient.EmptyOffloadTerminal.COMPLETED_EMPTY,
            isWhoop5 = false, hasBankedBeforeOnThisInstall = false, consecutiveEmptySyncs = 1,
        )
        assertFalse(copy!!.contains("in a row"))
    }

    @Test
    fun bankingCycleResetsTheMetadataOnlyStreak() {
        val tracker = EmptySyncTracker()
        val empty = WhoopBleClient.classifyCompletedOffload(0, 0, 0)
        val banking = WhoopBleClient.classifyCompletedOffload(decodedChunks = 3, consoleChunks = 0, rowsPersisted = 90)
        tracker.recordCompletedSync(bankedSensorRecords = empty.first, consoleOnly = empty.second)
        tracker.recordCompletedSync(bankedSensorRecords = empty.first, consoleOnly = empty.second)
        tracker.recordCompletedSync(bankedSensorRecords = banking.first, consoleOnly = banking.second)
        assertEquals(0, tracker.consecutiveEmptySyncs)
    }
}
