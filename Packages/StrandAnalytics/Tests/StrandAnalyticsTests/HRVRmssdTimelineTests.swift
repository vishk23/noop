import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Tests for the intraday rMSSD timeline (#803): the Deep Timeline "HRV" series must show real HRV
/// variability (rMSSD per time window), not the raw R-R tachogram. Reuses HRVAnalyzer cleaning.
final class HRVRmssdTimelineTests: XCTestCase {

    /// 25 beats alternating 800/810 ms inside one 300 s window → every successive |Δ| = 10 ms, so
    /// RMSSD = sqrt(mean(10²)) = 10. One window in → one point out.
    func testComputesPerWindowRmssdFromCleanRR() {
        let rr = (0..<25).map { RRInterval(ts: $0, rrMs: $0 % 2 == 0 ? 800 : 810) }
        let pts = HRVAnalyzer.rmssdTimeline(rr, windowSeconds: 300)
        XCTAssertEqual(pts.count, 1)
        XCTAssertEqual(pts.first?.rmssd ?? -1, 10.0, accuracy: 0.5)
    }

    /// A single out-of-range artifact (2400 ms ≈ 25 bpm) is range-filtered before rMSSD, so it must
    /// NOT inflate the result toward the raw-interval scale — the whole point of the fix.
    func testArtifactDoesNotInflateRmssd() {
        let rr = (0..<25).map { RRInterval(ts: $0, rrMs: $0 == 12 ? 2400 : ($0 % 2 == 0 ? 800 : 810)) }
        let pts = HRVAnalyzer.rmssdTimeline(rr, windowSeconds: 300)
        XCTAssertEqual(pts.count, 1)
        XCTAssertLessThan(pts.first?.rmssd ?? .greatestFiniteMagnitude, 50.0)
    }

    /// Fewer than `minBeats` clean intervals in a window → no point (an honest gap, not a fake value).
    func testSparseWindowProducesNoPoint() {
        let rr = (0..<5).map { RRInterval(ts: $0, rrMs: 800) }
        XCTAssertTrue(HRVAnalyzer.rmssdTimeline(rr, windowSeconds: 300).isEmpty)
    }

    /// Beats falling in two different windows produce one rMSSD point per window, ascending by ts.
    func testSeparateWindowsProduceOnePointEach() {
        let w1 = (0..<25).map { RRInterval(ts: $0, rrMs: $0 % 2 == 0 ? 800 : 810) }
        let w2 = (0..<25).map { RRInterval(ts: 300 + $0, rrMs: $0 % 2 == 0 ? 900 : 920) }
        let pts = HRVAnalyzer.rmssdTimeline(w1 + w2, windowSeconds: 300)
        XCTAssertEqual(pts.count, 2)
        XCTAssertLessThan(pts.first?.ts ?? 0, pts.last?.ts ?? 0)
    }

    /// A window where most beats were noise must be dropped, even if >= minBeats clean intervals
    /// survive — Noop's spot-reading honesty gate (#585): >35% rejected ⇒ too noisy to trust. This is
    /// what removes the daytime motion-artifact spikes from the Deep Timeline (#803).
    func testWindowDominatedByNoiseIsDropped() {
        // 25 clean beats (>= minBeats) + 35 out-of-range artifacts → 35/60 = 58% rejected > 35% gate.
        var rr = (0..<25).map { RRInterval(ts: $0, rrMs: $0 % 2 == 0 ? 800 : 810) }
        rr += (25..<60).map { RRInterval(ts: $0, rrMs: 2400) }
        XCTAssertTrue(HRVAnalyzer.rmssdTimeline(rr, windowSeconds: 300).isEmpty,
                      "a window where >35% of beats were noise should be dropped, not shown as a spike")
    }
}
