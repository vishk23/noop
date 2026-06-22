import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class HRVAnalyzerTests: XCTestCase {

    func testRMSSDRawHandComputed() {
        // NN = [800, 810, 800, 810] → diffs 10, -10, 10 → sqrt(300/3) = 10.
        let nn = [800.0, 810, 800, 810]
        XCTAssertEqual(HRVAnalyzer.rmssdRaw(nn)!, 10.0, accuracy: 1e-9)
    }

    func testSDNNRawSampleStdDev() {
        // Sample SD (ddof=1) of [800, 810, 800, 810] = 5.7735026919...
        let nn = [800.0, 810, 800, 810]
        XCTAssertEqual(HRVAnalyzer.sdnnRaw(nn)!, 5.773502691896258, accuracy: 1e-9)
    }

    func testRMSSDRawTooFewReturnsNil() {
        XCTAssertNil(HRVAnalyzer.rmssdRaw([800]))
        XCTAssertNil(HRVAnalyzer.sdnnRaw([]))
    }

    func testRangeFilterDropsOutOfRange() {
        let rr = [250.0, 300, 800, 2000, 2100, 1500]
        // 250 (<300) and 2100 (>2000) dropped; 300 and 2000 kept (inclusive).
        XCTAssertEqual(HRVAnalyzer.rangeFilter(rr), [300, 800, 2000, 1500])
    }

    func testAnalyzeRequiresMinBeats() {
        // 19 clean intervals → below minBeats(20) → empty result.
        let rr = Array(repeating: 800.0, count: 19)
        let result = HRVAnalyzer.analyze(rawRR: rr)
        XCTAssertNil(result.rmssd)
        XCTAssertNil(result.sdnn)
        XCTAssertEqual(result.nInput, 19)
        XCTAssertEqual(result.nClean, 0)
    }

    func testAnalyzeGoldenSeries() {
        // 22 intervals oscillating near 800 ms; matches Python golden values.
        let nn: [Double] = [800, 810, 805, 815, 800, 820, 810, 800, 815, 805, 810,
                            800, 820, 815, 805, 810, 800, 815, 810, 805, 800, 820]
        let result = HRVAnalyzer.analyze(rawRR: nn)
        XCTAssertEqual(result.nClean, 22)  // none ectopic (all near local median)
        XCTAssertEqual(result.rmssd!, 11.649647450214351, accuracy: 1e-9)
        XCTAssertEqual(result.sdnn!, 7.101612523427368, accuracy: 1e-9)
        XCTAssertEqual(result.meanNN!, nn.reduce(0,+)/22, accuracy: 1e-9)
    }

    func testEctopicRejectionDropsSpike() {
        // A steady 800 ms series with one impossible 1400 ms beat in the middle.
        // The spike deviates ~75% from local median → rejected. Remaining beats
        // are all 800 → RMSSD 0.
        var nn = Array(repeating: 800.0, count: 30)
        nn[15] = 1400
        let clean = HRVAnalyzer.cleanRR(nn)
        XCTAssertEqual(clean.count, 29)               // exactly one beat dropped
        XCTAssertFalse(clean.contains(1400))
        XCTAssertEqual(HRVAnalyzer.rmssdRaw(clean)!, 0.0, accuracy: 1e-9)
    }

    func testEctopicKeepsModerateVariation() {
        // ±15% variation is within the 20% Malik threshold → all kept.
        let nn = [800.0, 900, 800, 900, 800, 900, 800, 900]  // 900/800 = +12.5%
        let clean = HRVAnalyzer.rejectEctopic(nn)
        XCTAssertEqual(clean.count, nn.count)
    }

    // MARK: - #585 spot honesty gate (maxRejectedFraction)

    func testSpotGateRefusesWhenTooManyBeatsRejected() {
        // 40 input beats: 24 valid 800 ms + 16 out-of-range 100 ms (dropped by the range filter).
        // 24 clean survive (>= minBeats 20), but 16/40 = 0.40 rejected > 0.35 gate → refused (empty).
        var rr = Array(repeating: 800.0, count: 24)
        rr.append(contentsOf: Array(repeating: 100.0, count: 16))   // 100 ms < rrMinMs(300) → range-dropped
        let gated = HRVAnalyzer.analyze(rawRR: rr, maxRejectedFraction: 0.35)
        XCTAssertNil(gated.rmssd, "0.40 rejected > 0.35 gate must refuse the spot reading")
        XCTAssertNil(gated.sdnn)
        XCTAssertEqual(gated.nInput, 40)
        XCTAssertEqual(gated.nClean, 0)   // empty() reports no clean beats on refusal

        // SAME beats with NO gate (nil) still produce a value — 24 clean ≥ minBeats. Proves the gate is
        // the only thing rejecting it, not the beat count.
        let ungated = HRVAnalyzer.analyze(rawRR: rr)
        XCTAssertEqual(ungated.nClean, 24)
        XCTAssertEqual(ungated.rmssd!, 0.0, accuracy: 1e-9)   // all-800 survivors → no successive diffs
    }

    func testSpotGateAllowsWhenRejectionUnderCeiling() {
        // 40 input: 30 valid 800 ms + 10 out-of-range → 10/40 = 0.25 rejected < 0.35 gate → allowed.
        var rr = Array(repeating: 800.0, count: 30)
        rr.append(contentsOf: Array(repeating: 100.0, count: 10))
        let gated = HRVAnalyzer.analyze(rawRR: rr, maxRejectedFraction: 0.35)
        XCTAssertEqual(gated.nClean, 30)
        XCTAssertEqual(gated.rmssd!, 0.0, accuracy: 1e-9)
    }

    func testNightlyWindowedRMSSDUnchangedWithDefaultedGate() {
        // The nightly windowed analyze(_:windowStart:windowEnd:) passes NO maxRejectedFraction, so the
        // gate is skipped and the result is byte-identical to analyze(rawRR:) on the same beats — even
        // when the series WOULD trip a spot gate (here 0.40 rejected). Overnight HRV must not move (#585).
        var rr: [RRInterval] = []
        for t in 0..<24 { rr.append(RRInterval(ts: 1000 + t, rrMs: 800)) }   // 24 valid 800 ms
        for t in 0..<16 { rr.append(RRInterval(ts: 1100 + t, rrMs: 100)) }   // 16 range-dropped
        let windowed = HRVAnalyzer.analyze(rr, windowStart: 1000, windowEnd: 2000)
        // The spot gate WOULD refuse this (0.40 > 0.35); the nightly path must NOT.
        XCTAssertEqual(windowed.nClean, 24)
        XCTAssertNotNil(windowed.rmssd)
        // Identical to the un-gated raw analysis on the same values.
        let raw = HRVAnalyzer.analyze(rawRR: rr.map { Double($0.rrMs) })
        XCTAssertEqual(windowed.rmssd!, raw.rmssd!, accuracy: 1e-12)
        XCTAssertEqual(windowed.sdnn ?? .nan, raw.sdnn ?? .nan, accuracy: 1e-12)
        XCTAssertEqual(windowed.nClean, raw.nClean)
    }

    func testAnalyzeWindowFiltersByTimestamp() {
        // RR rows across two windows; only [1000,1010] should be analyzed.
        var rr: [RRInterval] = []
        for t in 1000...1030 { rr.append(RRInterval(ts: t, rrMs: 800)) }   // 31 in window A
        for t in 5000...5030 { rr.append(RRInterval(ts: t, rrMs: 600)) }   // window B
        let result = HRVAnalyzer.analyze(rr, windowStart: 1000, windowEnd: 1030)
        XCTAssertEqual(result.nInput, 31)
        XCTAssertEqual(result.nClean, 31)
        XCTAssertEqual(result.rmssd!, 0.0, accuracy: 1e-9)  // all 800 → no successive diffs
    }
}
