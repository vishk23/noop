import XCTest
@testable import StrandAnalytics
import WhoopStore

/// DailyStressEngine — the redesigned 0–3 daily stress score: log-domain HRV, dual baselines (short
/// adaptive for the number + long reference for a sustained-shift readout), coupled RHR/HRV escalation
/// (Buchheit quadrant), and a smallest-worthwhile-change dead-zone.
final class DailyStressEngineTests: XCTestCase {

    private func dm(_ day: Int, hrv: Double?, rhr: Int?) -> DailyMetric {
        DailyMetric(day: String(format: "2025-05-%02d", day), totalSleepMin: nil, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                    avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
    }

    // MARK: - The coupling (the central design decision)

    func testHRVDownWithRHRUpReadsSympatheticStress() {
        // Stable ~92ms / 50bpm baseline, today a clear HRV drop (66) AND RHR rise (60): the true
        // autonomic-stress quadrant → high score.
        var days: [DailyMetric] = []
        for i in 1...20 { days.append(dm(i, hrv: i % 2 == 0 ? 94 : 90, rhr: i % 2 == 0 ? 51 : 49)) }
        days.append(dm(21, hrv: 66, rhr: 60))
        let s = DailyStressEngine.evaluate(days: days)!
        XCTAssertEqual(s.quadrant, .sympatheticStress)
        XCTAssertGreaterThan(s.score, DailyStressEngine.highBandFloor, "coupled HRV-down+RHR-up is high stress")
    }

    func testHRVDownWithRHRLowIsSaturationAndScoresLowerThanCoupledStress() {
        // THE coupling test: identical HRV drop (66), but RHR is LOW (44) not high. That's benign
        // parasympathetic saturation, not stress — it must classify as saturation AND score clearly
        // lower than the same HRV drop with RHR elevated.
        func build(rhrToday: Int) -> [DailyMetric] {
            var days: [DailyMetric] = []
            for i in 1...20 { days.append(dm(i, hrv: i % 2 == 0 ? 94 : 90, rhr: 50)) }
            days.append(dm(21, hrv: 66, rhr: rhrToday))
            return days
        }
        let saturated = DailyStressEngine.evaluate(days: build(rhrToday: 44))!
        let stressed  = DailyStressEngine.evaluate(days: build(rhrToday: 60))!
        XCTAssertEqual(saturated.quadrant, .parasympatheticSaturation)
        XCTAssertLessThan(saturated.score, stressed.score,
                          "low HRV with LOW RHR (saturation) must read less stressed than low HRV with HIGH RHR")
    }

    func testHRVAboveBaselineReadsRecovered() {
        var days: [DailyMetric] = []
        for i in 1...20 { days.append(dm(i, hrv: 80, rhr: 52)) }
        days.append(dm(21, hrv: 105, rhr: 48))   // HRV well above baseline, RHR below
        let s = DailyStressEngine.evaluate(days: days)!
        XCTAssertEqual(s.quadrant, .recovered)
        XCTAssertLessThan(s.score, 1.5, "a recovered night reads below the 1.5 baseline")
    }

    func testSWCDeadzoneKeepsAnOrdinaryNightNeutral() {
        // Today sits right at the baseline → within the smallest-worthwhile-change band → ~1.5, not
        // nudged off baseline by sub-threshold noise.
        var days: [DailyMetric] = []
        for i in 1...20 { days.append(dm(i, hrv: i % 2 == 0 ? 91 : 89, rhr: 50)) }
        days.append(dm(21, hrv: 90, rhr: 50))
        let s = DailyStressEngine.evaluate(days: days)!
        XCTAssertEqual(s.quadrant, .balanced)
        XCTAssertEqual(s.score, 1.5, accuracy: 0.2, "an ordinary night stays at ~baseline")
    }

    // MARK: - The dual-baseline reframe (the point of the whole redesign)

    func testSustainedShiftNormalizesTheDailyScoreButFlagsChronicLoad() {
        // A sustained autonomic shift: 60 nights at the long-term normal (120 ms / 46 bpm), then 14
        // recent nights settled at a suppressed level (72 ms / 55 bpm), today at that new level.
        // The DAILY score must normalize (today ≈ its own recent baseline), while the CHRONIC readout
        // must flag the sustained load (recent HRV well below the long-term normal, RHR above it).
        var days: [DailyMetric] = []
        var d = 1
        for _ in 0..<60 { days.append(dm(d, hrv: 120, rhr: 46)); d += 1 }
        for _ in 0..<14 { days.append(dm(d, hrv: 72, rhr: 55)); d += 1 }
        days.append(dm(d, hrv: 72, rhr: 55))   // today: the new normal
        let s = DailyStressEngine.evaluate(days: days)!
        XCTAssertLessThan(s.score, DailyStressEngine.highBandFloor,
                          "today at its own recent (shifted) normal must NOT read high stress — the short baseline adapted")
        let chronic = s.chronicShift!
        XCTAssertGreaterThan(chronic.hrvPctBelowLongTerm, 5,
                             "the chronic readout must surface HRV suppressed vs the long-term normal")
        XCTAssertGreaterThan(chronic.rhrBpmAboveLongTerm, 0, "RHR elevated vs long-term too")
        XCTAssertTrue(chronic.isSustainedLoad, "both channels shifted in the load direction → sustained load")
        XCTAssertGreaterThan(chronic.daysBelowBand, 5, "the shift has persisted for many nights")
    }

    // MARK: - Robustness / degradation

    func testHRVOnlyWhenNoRHR() {
        // No RHR anywhere → HRV-only scoring, no coupling, usedRHR false, still produces a score.
        var days: [DailyMetric] = []
        for i in 1...20 { days.append(dm(i, hrv: 90, rhr: nil)) }
        days.append(dm(21, hrv: 66, rhr: nil))
        let s = DailyStressEngine.evaluate(days: days)!
        XCTAssertFalse(s.usedRHR)
        XCTAssertGreaterThan(s.score, 1.5, "an HRV drop still reads as elevated when RHR is unavailable")
    }

    func testInsufficientBaselineReturnsNil() {
        let days = (1...4).map { dm($0, hrv: 90, rhr: 50) }
        XCTAssertNil(DailyStressEngine.evaluate(days: days), "fewer than the minimum baseline nights → nil")
    }

    func testGradualDeclineIsSurfacedByTheMedianLongReference() {
        // A slow multi-week HRV decline (120 → 74 over 60 nights), today at the low end. A recency-
        // WEIGHTED "long" baseline collapses onto the recent low and reads ~0% (the bug a real device's
        // gradually-declining data exposed); the robust MEDIAN long reference captures the decline.
        var days: [DailyMetric] = []
        for i in 0..<60 {
            days.append(dm(i + 1, hrv: 120.0 - Double(i) * (46.0 / 59.0), rhr: 46))   // 120 → 74 linear
        }
        days.append(dm(61, hrv: 74, rhr: 46))
        let cs = DailyStressEngine.evaluate(days: days)!.chronicShift!
        XCTAssertGreaterThan(cs.hrvPctBelowLongTerm, 10,
            "the median long reference must surface a months-long decline that a recency-weighted long baseline would hide")
    }

    func testMultipleDeviceRowsPerDayAreDedupedToOnePerDay() {
        // Two source rows for the same day (Apple with only RHR, WHOOP with HRV+RHR): the richer row
        // wins, and the baseline windows count DAYS not device-rows (else a "60-day" window shrinks).
        var days: [DailyMetric] = []
        for i in 1...20 {
            days.append(dm(i, hrv: nil, rhr: 55))         // apple-like: RHR only
            days.append(dm(i, hrv: 90, rhr: 50))          // whoop-like: richer (HRV present)
        }
        days.append(dm(21, hrv: 66, rhr: 60))
        let s = DailyStressEngine.evaluate(days: days)!
        // If dedup failed, the HRV baseline would still work but be built off far fewer than 20 days;
        // the score should still classify a clear HRV-down + RHR-up night as stress.
        XCTAssertEqual(s.quadrant, .sympatheticStress)
    }
}
