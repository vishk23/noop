import XCTest
import WhoopStore
@testable import StrandImport
@testable import Strand

/// A fetcher that serves canned page bodies per endpoint.
private final class StubFetcher: OuraPageFetching {
    var pages: [String: [Data]] = [:]
    var capturedQueries: [String: [String: String]] = [:]
    func fetchAllRaw(endpoint: String, query: [String: String]) async throws -> [Data] {
        capturedQueries[endpoint] = query
        return pages[endpoint] ?? []
    }
}

final class OuraSyncCoordinatorTests: XCTestCase {
    func testBackfillFetchesParsesAndWrites() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = StubFetcher()
        fetcher.pages["daily_readiness"] = [#"{"data":[{"day":"2026-01-02","score":80,"contributors":{"resting_heart_rate":50}}],"next_token":null}"#.data(using: .utf8)!]
        fetcher.pages["daily_activity"] = [#"{"data":[{"day":"2026-01-02","steps":9000}],"next_token":null}"#.data(using: .utf8)!]
        fetcher.pages["sleep"] = [#"{"data":[{"id":"s1","day":"2026-01-02","bedtime_start":"2026-01-01T23:00:00+00:00","bedtime_end":"2026-01-02T06:00:00+00:00","total_sleep_duration":24000,"lowest_heart_rate":48,"sleep_phase_5_min":"1234"}],"next_token":null}"#.data(using: .utf8)!]

        var progress: [String] = []
        let coord = OuraSyncCoordinator(fetcher: fetcher, store: store)
        let summary = try await coord.runFullImport(today: "2026-02-01") { progress.append($0.endpoint) }

        XCTAssertEqual(summary.days, 1)
        XCTAssertEqual(summary.sleeps, 1)
        XCTAssertTrue(summary.rawPages >= 3)
        XCTAssertTrue(progress.contains("sleep"))

        // Coalesce + RHR precedence: daily_readiness's true RHR (50) wins over sleep's lowestHr (48).
        let days = try await store.dailyMetrics(deviceId: "oura-api", from: "2026-01-01", to: "2026-01-03")
        XCTAssertEqual(days.first?.restingHr, 50)
        XCTAssertEqual(days.first?.steps, 9000)
        XCTAssertEqual(days.first?.totalSleepMin, 400)
    }

    func testEndpointDateParamsAreWiredCorrectly() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = StubFetcher()
        let coord = OuraSyncCoordinator(fetcher: fetcher, store: store)
        _ = try await coord.runFullImport(today: "2026-02-01")

        XCTAssertNotNil(fetcher.capturedQueries["heartrate"]?["start_datetime"])
        XCTAssertNotNil(fetcher.capturedQueries["heartrate"]?["end_datetime"])
        XCTAssertNil(fetcher.capturedQueries["heartrate"]?["start_date"])

        XCTAssertEqual(fetcher.capturedQueries["personal_info"], [:])
        XCTAssertEqual(fetcher.capturedQueries["ring_configuration"], [:])

        XCTAssertNotNil(fetcher.capturedQueries["daily_readiness"]?["start_date"])
        XCTAssertNotNil(fetcher.capturedQueries["daily_readiness"]?["end_date"])
    }
}
