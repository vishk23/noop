import Foundation
import WhoopStore
import StrandImport

/// Abstracts the page fetch so the coordinator is testable without a live network (OuraAPIClient conforms).
protocol OuraPageFetching {
    func fetchAllRaw(endpoint: String, query: [String: String]) async throws -> [Data]
}
extension OuraAPIClient: OuraPageFetching {}

struct OuraSyncProgress: Equatable { let endpoint: String; let pages: Int }

/// One-time backfill across every Oura v2 endpoint → an assembled OuraSyncResult → OuraSyncWriter. Merges
/// the per-day WearableDailyRows across endpoints (daily endpoints BEFORE sleep, so readiness RHR wins).
final class OuraSyncCoordinator {
    private let fetcher: OuraPageFetching
    private let store: WhoopStore
    init(fetcher: OuraPageFetching, store: WhoopStore) { self.fetcher = fetcher; self.store = store }

    /// Daily-summary endpoints handed to `parseDaily(_, endpoint:)`. Ordered so `daily_readiness` merges
    /// before `sleep` (RHR precedence). `daily_sleep` etc. contribute extras only.
    private static let dailyEndpoints = ["daily_readiness", "daily_activity", "daily_spo2", "daily_sleep",
                                         "daily_stress", "daily_resilience", "daily_cardiovascular_age", "vO2_max"]
    /// Endpoints with no Plan-1 parser — archived raw only.
    private static let rawOnlyEndpoints = ["personal_info", "ring_configuration", "sleep_time", "session",
                                           "tag", "enhanced_tag", "rest_mode_period", "ring_battery_level"]

    func runFullImport(startDate: String = "2013-01-01", today: String,
                       onProgress: @escaping (OuraSyncProgress) -> Void = { _ in }) async throws -> OuraSyncSummary {
        var result = OuraSyncResult()
        var byDay: [String: WearableDailyRow] = [:]

        func fetchRaw(_ endpoint: String, dateParam: String?) async throws -> [Data] {
            var q: [String: String] = [:]
            if let dateParam { q[dateParam] = startDate; q[dateParam == "start_datetime" ? "end_datetime" : "end_date"] = today }
            let pages = try await fetcher.fetchAllRaw(endpoint: endpoint, query: q)
            var idx = 0
            for body in pages {
                result.rawPages.append(OuraRawRow(endpoint: endpoint, documentId: "\(endpoint)-\(startDate)-\(idx)",
                                                  day: nil, payloadJSON: String(data: body, encoding: .utf8) ?? "",
                                                  fetchedAt: Int(Date().timeIntervalSince1970)))
                idx += 1
            }
            onProgress(OuraSyncProgress(endpoint: endpoint, pages: pages.count))
            return pages
        }

        func docs(_ pages: [Data]) -> [[String: Any]] {
            pages.flatMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["data"] as? [[String: Any]] ?? [] }
        }
        func merge(_ rows: [WearableDailyRow]) {
            for r in rows {
                var m = byDay[r.day] ?? WearableDailyRow(day: r.day)
                m.restingHr = m.restingHr ?? r.restingHr; m.avgHrvMs = m.avgHrvMs ?? r.avgHrvMs
                m.skinTempDevC = m.skinTempDevC ?? r.skinTempDevC; m.spo2Pct = m.spo2Pct ?? r.spo2Pct
                m.steps = m.steps ?? r.steps; m.activeKcal = m.activeKcal ?? r.activeKcal
                m.totalKcal = m.totalKcal ?? r.totalKcal; m.respRateBpm = m.respRateBpm ?? r.respRateBpm
                m.totalSleepMin = m.totalSleepMin ?? r.totalSleepMin; m.deepMin = m.deepMin ?? r.deepMin
                m.lightMin = m.lightMin ?? r.lightMin; m.remMin = m.remMin ?? r.remMin
                m.awakeMin = m.awakeMin ?? r.awakeMin; m.efficiencyPct = m.efficiencyPct ?? r.efficiencyPct
                byDay[r.day] = m
            }
        }

        // One failing endpoint must not abort the whole backfill (spec §7 — honest partial). A fetch
        // error (e.g. a scope 401 like the live spo2 naming mismatch) records the endpoint as skipped
        // and the run continues; the UI surfaces the skips from the summary.
        var skipped: [String] = []

        // Daily endpoints first (readiness RHR precedence), extras accumulate.
        for endpoint in Self.dailyEndpoints {
            do {
                let pages = try await fetchRaw(endpoint, dateParam: "start_date")
                let (days, extras) = OuraApiParser.parseDaily(docs(pages), endpoint: endpoint)
                merge(days); result.extras.append(contentsOf: extras)
            } catch { skipped.append(endpoint) }
        }
        // Sleep last (its lowestHr fallback only fills days readiness didn't cover).
        do {
            let sleepPages = try await fetchRaw("sleep", dateParam: "start_date")
            let (periods, sleepDays) = OuraApiParser.parseSleep(docs(sleepPages))
            result.sleepPeriods = periods; merge(sleepDays)
        } catch { skipped.append("sleep") }
        // Workouts + heart-rate.
        do {
            let workoutPages = try await fetchRaw("workout", dateParam: "start_date")
            result.workouts = OuraApiParser.parseWorkouts(docs(workoutPages))
        } catch { skipped.append("workout") }
        do {
            let hrPages = try await fetchRaw("heartrate", dateParam: "start_datetime")
            result.heartRate = OuraApiParser.parseHeartRate(docs(hrPages))
        } catch { skipped.append("heartrate") }
        // Raw-only endpoints (no parser).
        for endpoint in Self.rawOnlyEndpoints {
            do {
                _ = try await fetchRaw(endpoint, dateParam: ["personal_info", "ring_configuration"].contains(endpoint) ? nil : "start_date")
            } catch { skipped.append(endpoint) }
        }

        result.days = Array(byDay.values)
        var summary = try await OuraSyncWriter.persist(result, into: store)
        summary.skippedEndpoints = skipped
        return summary
    }
}
