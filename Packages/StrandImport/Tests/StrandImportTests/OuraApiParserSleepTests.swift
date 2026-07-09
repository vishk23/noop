import XCTest
@testable import StrandImport

final class OuraApiParserSleepTests: XCTestCase {
    func testParsesPeriodWithHypnogramAndFoldsDay() throws {
        let docs: [[String: Any]] = [[
            "id": "s1", "day": "2026-01-02",
            "bedtime_start": "2026-01-01T23:00:00+00:00",
            "bedtime_end": "2026-01-02T06:00:00+00:00",
            "total_sleep_duration": 24000, "deep_sleep_duration": 6000,
            "light_sleep_duration": 12000, "rem_sleep_duration": 6000, "awake_time": 1200,
            "efficiency": 92, "average_heart_rate": 55, "lowest_heart_rate": 48,
            "average_hrv": 65, "average_breath": 14.2,
            "sleep_phase_5_min": "1234",
            "movement_30_sec": "1212",
            "heart_rate": ["interval": 300, "timestamp": "2026-01-01T23:00:00+00:00",
                           "items": [60, 58, NSNull(), 57]]
        ]]
        let (periods, days) = OuraApiParser.parseSleep(docs)
        XCTAssertEqual(periods.count, 1)
        let p = try XCTUnwrap(periods.first)
        XCTAssertEqual(p.session.totalSleepMin, 400)              // 24000s ÷ 60
        XCTAssertEqual(p.session.lowestHr, 48)
        XCTAssertEqual(p.session.avgHrvMs, 65)
        XCTAssertEqual(p.session.stages.map(\.stage), ["deep", "light", "rem", "wake"])
        XCTAssertEqual(p.movement30s, [1, 2, 1, 2])
        XCTAssertEqual(p.hr.map(\.bpm), [60, 58, 57])            // null sample dropped
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.day, "2026-01-02")
        XCTAssertEqual(days.first?.totalSleepMin, 400)
        XCTAssertEqual(days.first?.restingHr, 48)                // lowestHr ≈ resting fallback
    }

    func testSkipsPeriodWithInvalidSpan() {
        let (periods, _) = OuraApiParser.parseSleep([["bedtime_start": "nope", "bedtime_end": "nope"]])
        XCTAssertTrue(periods.isEmpty)
    }
}
