import Foundation

// MARK: - Oura account-export JSON parser
//
// Oura's Account → Export Data download is a single JSON document keyed by category. The categories
// this lane reads (documented Oura account-export / API-V2 shapes; NOOP's own clean parser):
//
//   "sleep"            — sleep PERIODS (one per nap/main sleep): bedtime_start / bedtime_end (ISO8601),
//                        day, total_sleep_duration / deep/light/rem_sleep_duration / awake_time (SECONDS),
//                        efficiency (%), average_heart_rate, lowest_heart_rate, average_hrv (rMSSD ms),
//                        average_breath. Oura gives stage DURATIONS, not a per-segment hypnogram, so the
//                        session carries the breakdown without a stage timeline (we never fake one).
//   "daily_readiness"  — day, score (Oura's OWN readiness — REFERENCE only, never NOOP Charge),
//                        temperature_deviation (°C), contributors.resting_heart_rate.
//   "daily_activity"   — day, steps, active_calories, total_calories.
//   "daily_sleep"      — day, score (sleep score — reference only).
//
// Some exports nest each category as `{ "data": [ ... ] }`; we accept both `[...]` and `{data:[...]}`.

enum OuraExportParser {

    /// True if a top-level dict has at least one Oura category whose elements look Oura-shaped. Used by
    /// brand detection so a renamed JSON still routes to Oura.
    static func looksLikeOura(_ dict: [String: Any]) -> Bool {
        for key in ["sleep", "daily_readiness", "daily_activity", "daily_sleep", "readiness", "activity"] {
            guard let arr = categoryArray(dict, key), let first = arr.first else { continue }
            if first["bedtime_start"] != nil || first["total_sleep_duration"] != nil
                || first["contributors"] != nil || first["temperature_deviation"] != nil
                || (first["day"] != nil && (first["score"] != nil || first["steps"] != nil)) {
                return true
            }
        }
        return false
    }

    static func parse(_ files: [String: Data]) -> (days: [WearableDailyRow], sleeps: [WearableSleepSession]) {
        var byDay: [String: WearableDailyRow] = [:]
        var sleeps: [WearableSleepSession] = []

        func day(_ key: String) -> WearableDailyRow { byDay[key] ?? WearableDailyRow(day: key) }

        for data in files.values {
            guard let root = WearableJSON.object(data) else { continue }

            // Sleep periods → sleep sessions + a per-day sleep rollup.
            for s in categoryArray(root, "sleep") ?? [] {
                guard let session = sleepSession(s) else { continue }
                sleeps.append(session)
                // Fold the night onto its calendar day (Oura's "day" = the wake day).
                let key = WearableJSON.str(s, "day") ?? WearableExportImporter.dayString(session.end)
                var row = day(key)
                row.totalSleepMin = row.totalSleepMin ?? session.totalSleepMin
                row.deepMin = row.deepMin ?? session.deepMin
                row.lightMin = row.lightMin ?? session.lightMin
                row.remMin = row.remMin ?? session.remMin
                row.awakeMin = row.awakeMin ?? session.awakeMin
                row.efficiencyPct = row.efficiencyPct ?? session.efficiencyPct
                row.avgHrvMs = row.avgHrvMs ?? session.avgHrvMs
                // Oura's lowest sleeping HR is the closest thing to a resting HR when readiness lacks one.
                if row.restingHr == nil { row.restingHr = session.lowestHr }
                byDay[key] = row
            }

            // Daily readiness → RHR + temperature deviation + reference readiness score.
            for r in categoryArray(root, "daily_readiness") ?? categoryArray(root, "readiness") ?? [] {
                guard let key = WearableJSON.str(r, "day") else { continue }
                var row = day(key)
                if let contrib = r["contributors"] as? [String: Any] {
                    row.restingHr = WearableJSON.posInt(contrib, "resting_heart_rate") ?? row.restingHr
                }
                row.restingHr = WearableJSON.posInt(r, "resting_heart_rate") ?? row.restingHr
                row.skinTempDevC = WearableJSON.dbl(r, "temperature_deviation") ?? row.skinTempDevC
                row.readinessScore = WearableJSON.posInt(r, "score") ?? row.readinessScore
                byDay[key] = row
            }

            // Daily sleep → reference sleep score only (the night's metrics come from "sleep").
            for d in categoryArray(root, "daily_sleep") ?? [] {
                guard let key = WearableJSON.str(d, "day") else { continue }
                var row = day(key)
                row.sleepScore = WearableJSON.posInt(d, "score") ?? row.sleepScore
                byDay[key] = row
            }

            // Daily activity → steps + calories.
            for a in categoryArray(root, "daily_activity") ?? categoryArray(root, "activity") ?? [] {
                guard let key = WearableJSON.str(a, "day") else { continue }
                var row = day(key)
                row.steps = WearableJSON.posInt(a, "steps") ?? row.steps
                row.activeKcal = WearableJSON.posDbl(a, "active_calories") ?? row.activeKcal
                row.totalKcal = WearableJSON.posDbl(a, "total_calories") ?? row.totalKcal
                byDay[key] = row
            }
        }

        // Fold any Oura CSV daily-summary rows in too. An export can be JSON, CSV, or a mix; JSON is
        // richer so it WINS field-by-field, CSV only fills a day's gaps (#857). CSV-only sessions append.
        let csv = parseCSV(files)
        for d in csv.days {
            var row = byDay[d.day] ?? WearableDailyRow(day: d.day)
            row.totalSleepMin = row.totalSleepMin ?? d.totalSleepMin
            row.deepMin = row.deepMin ?? d.deepMin
            row.lightMin = row.lightMin ?? d.lightMin
            row.remMin = row.remMin ?? d.remMin
            row.awakeMin = row.awakeMin ?? d.awakeMin
            row.efficiencyPct = row.efficiencyPct ?? d.efficiencyPct
            row.restingHr = row.restingHr ?? d.restingHr
            row.avgHrvMs = row.avgHrvMs ?? d.avgHrvMs
            row.skinTempDevC = row.skinTempDevC ?? d.skinTempDevC
            row.spo2Pct = row.spo2Pct ?? d.spo2Pct
            row.steps = row.steps ?? d.steps
            row.activeKcal = row.activeKcal ?? d.activeKcal
            row.totalKcal = row.totalKcal ?? d.totalKcal
            row.readinessScore = row.readinessScore ?? d.readinessScore
            row.sleepScore = row.sleepScore ?? d.sleepScore
            byDay[d.day] = row
        }
        sleeps.append(contentsOf: csv.sleeps)

        return (Array(byDay.values), sleeps)
    }

    // MARK: - CSV (Oura's "Export Data" trends / daily-summary CSV)
    //
    // Alongside the account-export JSON, Oura also lets a user export a per-day SUMMARY CSV (one row per
    // calendar day, header + rows). The columns we read (diacritic/space-folded by HeaderNorm, so e.g.
    // "Average HRV" to "average_hrv", "Total Sleep Duration" to "total_sleep_duration"):
    //
    //   date                         : the calendar day (YYYY-MM-DD or an ISO date/datetime).
    //   total/deep/light/rem sleep   : SECONDS (Oura's CSV uses seconds, like the JSON) -> minutes.
    //   awake time                   : SECONDS -> minutes.
    //   sleep efficiency             : %.
    //   average/lowest resting hr    : bpm (lowest is the night's sleeping floor).
    //   average hrv                  : rMSSD ms.
    //   respiratory rate             : breaths/min.
    //   readiness/sleep score        : Oura's OWN scores, REFERENCE only (never NOOP Charge).
    //   temperature deviation        : degrees C from baseline.
    //   steps / activity (active) burn / total burn : daily activity.
    //
    // A lone `heartrate.csv` (timestamped HR samples, no daily summary) carries NO daily wellness/sleep
    // row, so it folds to nothing here and the importer reports that honestly rather than failing opaquely
    // (#857).

    /// True if a CSV's normalized header set looks like an Oura per-day summary (a date column plus at
    /// least one Oura wellness column). Used by brand detection so a CSV export routes to Oura.
    static func looksLikeOuraCSV(_ normalizedHeaders: [String]) -> Bool {
        let set = Set(normalizedHeaders)
        guard set.contains(where: { dateKeys.contains($0) }) else { return false }
        return set.contains(where: { ouraCSVSignalColumns.contains($0) })
    }

    /// Header keys (already HeaderNorm-normalized) that name the day column in an Oura CSV.
    private static let dateKeys: Set<String> = ["date", "day", "summary_date", "calendar_date"]

    /// Normalized columns that mark a CSV as an Oura DAILY summary (vs a raw `heartrate.csv` sample file).
    private static let ouraCSVSignalColumns: Set<String> = [
        "total_sleep_duration", "rem_sleep_duration", "deep_sleep_duration", "light_sleep_duration",
        "sleep_efficiency", "average_hrv", "average_resting_heart_rate", "lowest_resting_heart_rate",
        "readiness_score", "sleep_score", "respiratory_rate", "temperature_deviation",
    ]

    /// Parse Oura CSV files (daily summaries) into the same day/sleep model the JSON path produces. A CSV
    /// that is only a raw HR-sample file (`heartrate.csv`) yields nothing, so the day stays honestly empty.
    static func parseCSV(_ files: [String: Data]) -> (days: [WearableDailyRow], sleeps: [WearableSleepSession]) {
        var byDay: [String: WearableDailyRow] = [:]
        var sleeps: [WearableSleepSession] = []

        for data in files.values {
            let table = CSVTable(data: data)
            guard looksLikeOuraCSV(table.normalizedHeaders) else { continue }
            for cells in table.rows {
                guard let key = cells.cell("date", "day", "summary_date", "calendar_date")
                    .map(normalizeDayKey) else { continue }

                var row = byDay[key] ?? WearableDailyRow(day: key)

                // Sleep durations are SECONDS in Oura's CSV (as in the JSON) → minutes.
                func minutes(_ keys: String...) -> Double? {
                    for k in keys { if let v = cells.double(k), v > 0 { return v / 60.0 } }
                    return nil
                }
                let total = minutes("total_sleep_duration", "total_sleep")
                let deep = minutes("deep_sleep_duration", "deep_sleep")
                let light = minutes("light_sleep_duration", "light_sleep")
                let rem = minutes("rem_sleep_duration", "rem_sleep")
                let awake = minutes("awake_time", "awake_duration", "time_awake")

                row.totalSleepMin = row.totalSleepMin ?? total
                row.deepMin = row.deepMin ?? deep
                row.lightMin = row.lightMin ?? light
                row.remMin = row.remMin ?? rem
                row.awakeMin = row.awakeMin ?? awake
                row.efficiencyPct = row.efficiencyPct
                    ?? cells.double("sleep_efficiency", "efficiency").flatMap { $0 > 0 ? $0 : nil }

                let restingHr = cells.double("average_resting_heart_rate", "resting_heart_rate")
                    ?? cells.double("lowest_resting_heart_rate", "lowest_heart_rate")
                if let rhr = restingHr, rhr > 0 { row.restingHr = row.restingHr ?? Int(rhr) }
                if let hrv = cells.double("average_hrv", "hrv"), hrv > 0 { row.avgHrvMs = row.avgHrvMs ?? hrv }
                if let temp = cells.double("temperature_deviation", "skin_temperature_deviation") {
                    row.skinTempDevC = row.skinTempDevC ?? temp
                }
                if let spo2 = cells.double("spo2", "blood_oxygen", "average_spo2"), spo2 > 0 {
                    row.spo2Pct = row.spo2Pct ?? spo2
                }
                if let steps = cells.double("steps"), steps >= 0 { row.steps = row.steps ?? Int(steps) }
                if let kcal = cells.double("activity_burn", "active_calories", "active_burn"), kcal > 0 {
                    row.activeKcal = row.activeKcal ?? kcal
                }
                if let total = cells.double("total_burn", "total_calories"), total > 0 {
                    row.totalKcal = row.totalKcal ?? total
                }
                // Oura's OWN scores → REFERENCE only.
                if let r = cells.double("readiness_score", "readiness"), r > 0 {
                    row.readinessScore = row.readinessScore ?? Int(r)
                }
                if let s = cells.double("sleep_score"), s > 0 { row.sleepScore = row.sleepScore ?? Int(s) }

                byDay[key] = row

                // Build a sleep session when the CSV gave a bedtime window, so the night lands on the Sleep
                // tab too (not just the daily rollup). Oura's CSV often carries `bedtime_start/_end`.
                if let start = WhoopTime.parseISOWithOffset(cells.cell("bedtime_start", "sleep_start")),
                   let end = WhoopTime.parseISOWithOffset(cells.cell("bedtime_end", "sleep_end")),
                   end > start {
                    sleeps.append(WearableSleepSession(
                        start: start, end: end,
                        deepMin: deep, lightMin: light, remMin: rem, awakeMin: awake,
                        totalSleepMin: total, efficiencyPct: row.efficiencyPct,
                        avgHr: nil,
                        lowestHr: restingHr.flatMap { $0 > 0 ? Int($0) : nil },
                        avgHrvMs: row.avgHrvMs,
                        respRateBpm: cells.double("respiratory_rate", "average_breath").flatMap { $0 > 0 ? $0 : nil },
                        sleepScore: nil, stages: []))
                }
            }
        }

        return (Array(byDay.values), sleeps)
    }

    /// Reduce an Oura CSV date/datetime cell to the `YYYY-MM-DD` day key (drops any time component).
    private static func normalizeDayKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // "2026-06-01", "2026-06-01T23:15:00+00:00", or "2026-06-01 23:15:00" → "2026-06-01".
        if trimmed.count >= 10 {
            let head = String(trimmed.prefix(10))
            if head.count == 10, head[head.index(head.startIndex, offsetBy: 4)] == "-" { return head }
        }
        return trimmed
    }

    // MARK: - Helpers

    /// Pull a category out of the root, accepting both a bare array and a `{ "data": [...] }` wrapper.
    private static func categoryArray(_ root: [String: Any], _ key: String) -> [[String: Any]]? {
        if let arr = root[key] as? [[String: Any]] { return arr }
        if let wrap = root[key] as? [String: Any], let arr = wrap["data"] as? [[String: Any]] { return arr }
        return nil
    }

    private static func sleepSession(_ s: [String: Any]) -> WearableSleepSession? {
        guard let start = WhoopTime.parse(WearableJSON.str(s, "bedtime_start"), offsetMinutes: 0),
              let end = WhoopTime.parse(WearableJSON.str(s, "bedtime_end"), offsetMinutes: 0),
              end > start else { return nil }

        // Durations are SECONDS in the export → minutes.
        func min(_ k: String) -> Double? { WearableJSON.posDbl(s, k).map { $0 / 60.0 } }

        return WearableSleepSession(
            start: start,
            end: end,
            deepMin: min("deep_sleep_duration"),
            lightMin: min("light_sleep_duration"),
            remMin: min("rem_sleep_duration"),
            awakeMin: min("awake_time"),
            totalSleepMin: min("total_sleep_duration"),
            efficiencyPct: WearableJSON.posDbl(s, "efficiency"),
            avgHr: WearableJSON.posInt(s, "average_heart_rate"),
            lowestHr: WearableJSON.posInt(s, "lowest_heart_rate"),
            avgHrvMs: WearableJSON.posDbl(s, "average_hrv"),
            respRateBpm: WearableJSON.posDbl(s, "average_breath"),
            sleepScore: nil,
            stages: [])
    }
}
