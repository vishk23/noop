package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the offline file-import of a user's OWN Oura / Fitbit / Garmin data export onto NOOP's daily
 * metrics + sleep sessions. Kotlin twin of the macOS WearableExportImporterTests — same arithmetic,
 * same brand detection, same honesty rules (a brand's own score is reference-only, never Charge).
 *
 * Tests the pure parse functions directly (no Room) with tiny inline fixtures.
 */
class WearableExportImporterTest {

    private fun bytes(s: String) = s.trimIndent().toByteArray()

    // ---------------- Oura ----------------

    @Test
    fun ouraSleepReadinessActivityFold() {
        val json = """
            {
              "sleep": [
                { "day": "2026-06-01", "bedtime_start": "2026-05-31T23:15:00+00:00",
                  "bedtime_end": "2026-06-01T06:30:00+00:00", "total_sleep_duration": 25200,
                  "deep_sleep_duration": 5400, "light_sleep_duration": 13800, "rem_sleep_duration": 6000,
                  "awake_time": 900, "efficiency": 92, "average_heart_rate": 54, "lowest_heart_rate": 48,
                  "average_hrv": 65 } ],
              "daily_readiness": [
                { "day": "2026-06-01", "score": 81, "temperature_deviation": -0.2,
                  "contributors": { "resting_heart_rate": 49 } } ],
              "daily_activity": [
                { "day": "2026-06-01", "steps": 8421, "active_calories": 520 } ]
            }
        """
        val files = mapOf("oura_2026.json" to bytes(json))
        assertEquals(WearableExportImporter.Brand.OURA, WearableExportImporter.detectBrand(files))
        val p = WearableExportImporter.parseOura(files)

        assertEquals(1, p.sleeps.size)
        val s = p.sleeps[0]
        assertEquals(420.0, s.totalSleepMin!!, 1e-6)   // 25200s → 420 min
        assertEquals(90.0, s.deepMin!!, 1e-6)
        assertEquals(100.0, s.remMin!!, 1e-6)
        assertEquals(65.0, s.avgHrvMs!!, 1e-6)
        assertEquals(48, s.lowestHr)

        assertEquals(1, p.days.size)
        val d = p.days[0]
        assertEquals("2026-06-01", d.day)
        assertEquals(49, d.restingHr)                   // readiness contributor wins
        assertEquals(-0.2, d.skinTempDevC!!, 1e-6)
        assertEquals(8421, d.steps)
        assertEquals(520.0, d.activeKcal!!, 1e-6)
        assertEquals(420.0, d.totalSleepMin!!, 1e-6)
        // Oura's OWN readiness score is kept as REFERENCE only — never a NOOP score.
        assertEquals(81, d.readinessScore)
    }

    @Test
    fun ouraAcceptsDataWrapperAndDetectsByContent() {
        val json = """
            { "sleep": { "data": [
                { "day": "2026-06-02", "bedtime_start": "2026-06-01T22:00:00+00:00",
                  "bedtime_end": "2026-06-02T05:00:00+00:00", "total_sleep_duration": 21600 } ] } }
        """
        val files = mapOf("export.json" to bytes(json))
        assertEquals(WearableExportImporter.Brand.OURA, WearableExportImporter.detectBrand(files))
        val p = WearableExportImporter.parseOura(files)
        assertEquals(1, p.sleeps.size)
        assertEquals(360.0, p.sleeps[0].totalSleepMin!!, 1e-6)
    }

    // ---------------- Oura CSV (#857) ----------------

    @Test
    fun ouraDailySummaryCsvFoldsDays() {
        // Representative Oura daily-summary CSV: header + two days. Sleep durations are SECONDS (like the
        // JSON); headers mix spaces/case so HeaderNorm has to normalize them.
        val csv = """
            date,Total Sleep Duration,Deep Sleep Duration,REM Sleep Duration,Light Sleep Duration,Awake Time,Sleep Efficiency,Average Resting Heart Rate,Average HRV,Temperature Deviation,Readiness Score,Sleep Score,Steps,Activity Burn
            2026-06-01,25200,5400,6000,13800,900,92,49,65,-0.2,81,84,8421,520
            2026-06-02,21600,4800,5400,11400,600,90,51,58,0.1,76,79,9300,610
        """
        val files = mapOf("oura_daily.csv" to bytes(csv))
        assertEquals(WearableExportImporter.Brand.OURA, WearableExportImporter.detectBrand(files))

        val p = WearableExportImporter.parseOura(files)
        assertEquals(2, p.days.size)
        val byDay = p.days.associateBy { it.day }

        val d1 = byDay["2026-06-01"]!!
        assertEquals(420.0, d1.totalSleepMin!!, 1e-6)   // 25200s → 420 min
        assertEquals(90.0, d1.deepMin!!, 1e-6)
        assertEquals(100.0, d1.remMin!!, 1e-6)
        assertEquals(92.0, d1.efficiencyPct!!, 1e-6)
        assertEquals(49, d1.restingHr)
        assertEquals(65.0, d1.avgHrvMs!!, 1e-6)
        assertEquals(-0.2, d1.skinTempDevC!!, 1e-6)
        assertEquals(8421, d1.steps)
        assertEquals(520.0, d1.activeKcal!!, 1e-6)
        // Oura's OWN scores stay REFERENCE only.
        assertEquals(81, d1.readinessScore)
        assertEquals(84, d1.sleepScore)

        assertEquals(360.0, byDay["2026-06-02"]!!.totalSleepMin!!, 1e-6)
        assertEquals(51, byDay["2026-06-02"]!!.restingHr)
    }

    @Test
    fun loneHeartRateCsvRoutesToOuraButImportsNothing() {
        // The exact #857 input: a single raw heartrate.csv (timestamped samples, no daily summary).
        val csv = """
            timestamp,heart_rate
            2026-06-01T09:00:00+00:00,62
            2026-06-01T09:01:00+00:00,64
        """
        val files = mapOf("heartrate.csv" to bytes(csv))
        assertEquals(WearableExportImporter.Brand.OURA, WearableExportImporter.detectBrand(files))
        assertTrue(WearableExportImporter.onlyHeartRateCsv(files))
        val p = WearableExportImporter.parseOura(files)
        assertTrue(p.days.isEmpty())
        assertTrue(p.sleeps.isEmpty())
    }

    // ---------------- Fitbit ----------------

    @Test
    fun fitbitSleepRestingHrSteps() {
        val sleep = """
            [ { "dateOfSleep": "2026-06-01", "startTime": "2026-05-31T23:00:00.000",
                "endTime": "2026-06-01T06:00:00.000", "minutesAsleep": 400, "minutesAwake": 20,
                "efficiency": 94,
                "levels": { "summary": {
                  "deep": { "minutes": 80 }, "light": { "minutes": 220 },
                  "rem": { "minutes": 100 }, "wake": { "minutes": 20 } } } } ]
        """
        val rhr = """
            [ { "dateTime": "2026-06-01T00:00:00.000", "value": { "date": "2026-06-01", "value": 51.5 } } ]
        """
        val steps = """
            [ { "dateTime": "2026-06-01 08:00:00", "value": "1200" },
              { "dateTime": "2026-06-01 09:00:00", "value": "800" } ]
        """
        val files = mapOf(
            "sleep-2026-06-01.json" to bytes(sleep),
            "resting_heart_rate-2026-06-01.json" to bytes(rhr),
            "steps-2026-06-01.json" to bytes(steps),
        )
        assertEquals(WearableExportImporter.Brand.FITBIT, WearableExportImporter.detectBrand(files))
        val p = WearableExportImporter.parseFitbit(files)

        assertEquals(1, p.sleeps.size)
        val s = p.sleeps[0]
        assertEquals(400.0, s.totalSleepMin!!, 1e-6)
        assertEquals(80.0, s.deepMin!!, 1e-6)
        assertEquals(100.0, s.remMin!!, 1e-6)
        assertEquals(94.0, s.efficiencyPct!!, 1e-6)

        assertEquals(1, p.days.size)
        val d = p.days[0]
        assertEquals("2026-06-01", d.day)
        assertEquals(51, d.restingHr)                   // nested value.value, narrowed
        assertEquals(2000, d.steps)                     // intraday steps summed
        assertEquals(400.0, d.totalSleepMin!!, 1e-6)
    }

    // ---------------- Garmin ----------------

    @Test
    fun garminWellnessSleepAndDaily() {
        val startMs = 1_780_272_000_000L            // 2026-06-01 00:00:00 UTC
        val endMs = startMs + 7 * 3600 * 1000
        val sleepData = """
            [ { "calendarDate": "2026-06-01", "sleepStartTimestampGMT": $startMs,
                "sleepEndTimestampGMT": $endMs,
                "deepSleepSeconds": 4800, "lightSleepSeconds": 14400, "remSleepSeconds": 5400,
                "awakeSleepSeconds": 600, "overallSleepScore": 78 } ]
        """
        val daily = """
            [ { "calendarDate": "2026-06-01", "restingHeartRate": 47, "totalSteps": 9100,
                "totalDistanceMeters": 7300.5, "averageStressLevel": 31 } ]
        """
        val files = mapOf(
            "di_connect/di_connect_wellness/2026_sleepdata.json" to bytes(sleepData),
            "di_connect/di_connect_wellness/2026_dailysummary.json" to bytes(daily),
        )
        assertEquals(WearableExportImporter.Brand.GARMIN, WearableExportImporter.detectBrand(files))
        val p = WearableExportImporter.parseGarmin(files)

        assertEquals(1, p.sleeps.size)
        val s = p.sleeps[0]
        assertEquals(80.0, s.deepMin!!, 1e-6)           // 4800s
        assertEquals(240.0, s.lightMin!!, 1e-6)         // 14400s
        assertEquals(90.0, s.remMin!!, 1e-6)            // 5400s
        assertEquals(410.0, s.totalSleepMin!!, 1e-6)
        assertEquals(78, s.sleepScore)                   // reference, never Charge

        assertEquals(1, p.days.size)
        val d = p.days[0]
        assertEquals("2026-06-01", d.day)
        assertEquals(47, d.restingHr)
        assertEquals(9100, d.steps)
        assertEquals(7300.5, d.distanceM!!, 1e-6)
        assertEquals(31, d.avgStress)
    }

    // ---------------- Date formatter caching (PR #583) ----------------
    //
    // The Fitbit/dayKey formatters were hoisted to cached fields; these pin that the parse behaviour —
    // and crucially the isDateOnly LocalDate-vs-LocalDateTime split in dayKey — is unchanged.

    @Test
    fun fitbitTimeParsesAllCachedDateTimePatterns() {
        // ISO-with-offset goes through WhoopTime; the three offsetless local patterns go through the
        // cached FITBIT_DT_FMTS list (millis / seconds / minute precision), interpreted at UTC.
        val withMillis = WearableExportImporter.fitbitTime("2026-06-01T23:00:00.000")
        val withSeconds = WearableExportImporter.fitbitTime("2026-06-01 23:00:00")
        val withMinutes = WearableExportImporter.fitbitTime("2026-06-01 23:00")
        assertEquals(withMillis, withSeconds)            // .000 and :00 are the same instant
        assertEquals(withSeconds, withMinutes)           // minute precision lands on the same :00
        assertNull(WearableExportImporter.fitbitTime("not a date"))
        assertNull(WearableExportImporter.fitbitTime(null))
    }

    @Test
    fun dayKeySplitHoldsAcrossMonthDayYearAndIsoDate() {
        // dateTime is the MM/dd/yy HH:mm:ss form (a DAYKEY_DATETIME_FMTS LocalDateTime parse): the RHR
        // row must still fold onto the 2026-06-01 day. A bare yyyy-MM-dd would take the LocalDate branch.
        val rhr = """
            [ { "dateTime": "06/01/26 08:30:00", "value": 53 } ]
        """
        val files = mapOf("resting_heart_rate-2026.json" to bytes(rhr))
        val p = WearableExportImporter.parseFitbit(files)
        val d = p.days.firstOrNull { it.day == "2026-06-01" }
        assertEquals(53, d?.restingHr)                   // MM/dd/yy datetime → correct day, RHR set
    }

    // ---------------- Safety / honesty ----------------

    @Test
    fun junkIsNotMistakenForAWearable() {
        assertNull(WearableExportImporter.detectBrand(mapOf("random.json" to bytes("{\"foo\":1}"))))
    }

    @Test
    fun zeroAndBadValuesProduceNoFabricatedRows() {
        val json = """
            { "sleep": [
                { "day": "2026-06-03", "bedtime_start": "bad", "bedtime_end": "also-bad",
                  "total_sleep_duration": 0, "average_heart_rate": 0 } ],
              "daily_readiness": [
                { "day": "2026-06-03", "score": 0, "contributors": { "resting_heart_rate": 0 } } ] }
        """
        val p = WearableExportImporter.parseOura(mapOf("oura.json" to bytes(json)))
        assertEquals(0, p.sleeps.size)                  // unparseable times → dropped
        val d = p.days.firstOrNull { it.day == "2026-06-03" }
        if (d != null) {
            assertNull(d.restingHr)                     // 0 RHR → nil
            assertNull(d.readinessScore)                // 0 score → nil
        }
    }

    @Test
    fun hugeOutOfRangeNumberDoesNotTrapOrStoreGarbage() {
        // org.json's optInt SATURATES a huge value; the finite/range guard must drop it. The valid
        // sibling field still imports.
        val json = """
            { "daily_activity": [ { "day": "2026-06-04", "steps": 1e19, "active_calories": 500 } ] }
        """
        val p = WearableExportImporter.parseOura(mapOf("oura.json" to bytes(json)))
        val d = p.days.first { it.day == "2026-06-04" }
        assertNull(d.steps)                              // 1e19 out of Int range → dropped
        assertEquals(500.0, d.activeKcal!!, 1e-6)
    }

    @Test
    fun nonWellnessFilesAreFilteredOut() {
        assertTrue(WearableExportImporter.isWellnessFile("sleep-2026-06-01.json", bytes("[]")))
        assertTrue(WearableExportImporter.isWellnessFile("2026_sleepdata.json", bytes("[]")))
        assertTrue(!WearableExportImporter.isWellnessFile("device_settings.json", bytes("{}")))
        assertTrue(!WearableExportImporter.isWellnessFile("readme.txt", bytes("hi")))
    }
}
