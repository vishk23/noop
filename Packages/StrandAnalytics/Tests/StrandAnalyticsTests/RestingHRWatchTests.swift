import XCTest
@testable import StrandAnalytics

/// Pins the SINGLE-SIGNAL resting-HR tier. Every expectation here is mirrored by the Kotlin twin
/// (`RestingHRWatchTest.kt`) with identical inputs, so the two platforms cannot drift.
final class RestingHRWatchTests: XCTestCase {

    /// A flat 50 bpm history: the median is 50 and nothing is elevated.
    private func flat(_ n: Int, _ v: Double = 50) -> [Double?] { Array(repeating: v, count: n) }

    // MARK: - Cold start

    func testTooLittleHistoryStaysQuiet() {
        // 6 prior nights + tonight — below `minHistoryNights` (7), so there is no median to compare to.
        let r = RestingHRWatch.evaluate(flat(6) + [70])
        XCTAssertEqual(r.level, .quiet)
        XCTAssertNil(r.medianBPM, "no median may be reported below the history floor")
        XCTAssertEqual(r.consecutiveElevatedNights, 0)
    }

    func testRaisesOnTheNinthNight() {
        // 7 prior nights is the floor, so two elevated nights on top = 9 total is the EARLIEST raise.
        // This is the whole point of the tier: the corroborated engine needs ~17.
        let r = RestingHRWatch.evaluate(flat(7) + [56, 57])
        XCTAssertEqual(r.level, .raised)
        XCTAssertEqual(r.consecutiveElevatedNights, 2)
    }

    // MARK: - Persistence is the false-positive suppressor

    func testSingleElevatedNightDoesNotRaise() {
        let r = RestingHRWatch.evaluate(flat(20) + [60])
        XCTAssertEqual(r.level, .quiet, "one hard workout or bad night must not fire")
        XCTAssertEqual(r.consecutiveElevatedNights, 1)
        XCTAssertEqual(r.deltaBPM ?? 0, 10, accuracy: 1e-9)
    }

    func testTwoConsecutiveElevatedNightsRaise() {
        let r = RestingHRWatch.evaluate(flat(20) + [56, 56])
        XCTAssertEqual(r.level, .raised)
        XCTAssertEqual(r.consecutiveElevatedNights, 2)
    }

    func testElevationThatRecoversDoesNotRaise() {
        // Elevated, elevated, then back to normal — the run must END at the most recent night.
        let r = RestingHRWatch.evaluate(flat(20) + [58, 58, 50])
        XCTAssertEqual(r.level, .quiet)
        XCTAssertEqual(r.consecutiveElevatedNights, 0)
    }

    // MARK: - The threshold is absolute and ONE-SIDED

    func testJustUnderTheOffsetDoesNotFire() {
        let r = RestingHRWatch.evaluate(flat(20) + [53.9, 53.9])   // +3.9, under the +4.0 offset
        XCTAssertEqual(r.level, .quiet)
    }

    func testExactlyAtTheOffsetFires() {
        let r = RestingHRWatch.evaluate(flat(20) + [54, 54])       // +4.0 exactly
        XCTAssertEqual(r.level, .raised)
    }

    /// THE ONE-SIDEDNESS GUARD. A resting HR far BELOW the personal median is the HEALTHY direction
    /// (well-rested, well-trained) and must never raise, however extreme or however sustained.
    func testDeeplyBelowMedianNeverRaises() {
        let r = RestingHRWatch.evaluate(flat(20) + [38, 37, 36, 35])
        XCTAssertEqual(r.level, .quiet)
        XCTAssertEqual(r.consecutiveElevatedNights, 0)
        XCTAssertLessThan(r.deltaBPM ?? 0, 0)
        XCTAssertNil(RestingHRWatch.copy(for: r), "the healthy direction must produce no copy")
    }

    // MARK: - Baseline mechanics

    func testMedianIsTakenBeforeTonightSoAnElevationCannotPropUpItsOwnBaseline() {
        let r = RestingHRWatch.evaluate(flat(20) + [56, 56])
        XCTAssertEqual(r.medianBPM ?? 0, 50, accuracy: 1e-9,
                       "tonight must be excluded from its own comparison window")
    }

    /// A median does NOT widen when an outlier lands in it — the property the EWMA-spread baseline in
    /// `IllnessSignalEngine` lacks, and the reason a SUSTAINED elevation keeps reading as one here.
    func testSustainedElevationDoesNotSuppressItself() {
        var nights = flat(20)
        nights.append(contentsOf: Array(repeating: 58, count: 6) as [Double?])
        let r = RestingHRWatch.evaluate(nights)
        XCTAssertEqual(r.level, .raised)
        XCTAssertEqual(r.consecutiveElevatedNights, 6,
                       "every night of a sustained elevation must still read as elevated")
        XCTAssertGreaterThanOrEqual(r.deltaBPM ?? 0, RestingHRWatch.offsetBPM,
                                    "the delta must not decay as the elevation persists")
    }

    func testMissingNightsAreSkippedNotTreatedAsZero() {
        // A gap in the middle must neither break the elevated run nor drag the median toward zero.
        let r = RestingHRWatch.evaluate(flat(20) + [56, nil, 56])
        XCTAssertEqual(r.level, .raised)
        XCTAssertEqual(r.medianBPM ?? 0, 50, accuracy: 1e-9)
    }

    func testEmptyHistoryIsQuietNotACrash() {
        let r = RestingHRWatch.evaluate([])
        XCTAssertEqual(r.level, .quiet)
        XCTAssertNil(r.deltaBPM)
        XCTAssertEqual(r.consecutiveElevatedNights, 0)
    }

    func testAllNilHistoryIsQuiet() {
        let r = RestingHRWatch.evaluate(Array(repeating: nil, count: 30))
        XCTAssertEqual(r.level, .quiet)
    }

    // MARK: - Copy safety (wellness framing, never a diagnosis)

    func testCopyNeverNamesAConditionAndCarriesTheDisclaimer() {
        let r = RestingHRWatch.evaluate(flat(20) + [58, 58])
        let copy = try! XCTUnwrap(RestingHRWatch.copy(for: r))
        XCTAssertTrue(copy.hasSuffix(IllnessSignalEngine.disclaimerTail))
        // Check the AUTHORED body only — the mandatory disclaimer tail necessarily contains the word
        // "diagnosis", which is the point of it.
        let body = copy.replacingOccurrences(of: IllnessSignalEngine.disclaimerTail, with: "").lowercased()
        for banned in ["illness", "infection", "fever", "sick", "virus", "flu", "covid",
                       "diagnos", "disease"] {
            XCTAssertFalse(body.contains(banned),
                           "copy must never name a condition, found '\(banned)' in: \(copy)")
        }
    }

    // MARK: - Real-history regression (VK's WHOOP era, 2026-06-27 → 2026-07-27)
    //
    // The measured event: resting HR steps 55 → 58 → 59 over 2026-07-10…07-12 against a ~50 bpm
    // personal median, then recovers. The corroborated tier returned `.quiet` on EVERY day of this
    // history because it had not yet earned a trusted baseline. This tier raises on 07-11.
    //
    // The values are the shape of the event, not the user's data: a flat 50 bpm run-in stands in for the
    // real (49-54) run-in so the fixture carries no health history.

    func testRealShapedEventRaisesOnTheSecondElevatedNight() {
        let runIn = flat(9)                                    // ~50 bpm, the settled personal level
        let onset: [Double?] = [55]                            // night 1 of the event: +5, one night only
        XCTAssertEqual(RestingHRWatch.evaluate(runIn + onset).level, .quiet,
                       "a single elevated night must not fire, even at onset")

        let secondNight: [Double?] = [55, 58]                  // night 2: the raise
        let r = RestingHRWatch.evaluate(runIn + secondNight)
        XCTAssertEqual(r.level, .raised)
        XCTAssertEqual(r.consecutiveElevatedNights, 2)
    }

    func testHealthyLowStretchAfterTheEventStaysQuiet() {
        // The real history's tail runs 44/41/43/44 bpm against a ~49 median — a strongly NEGATIVE
        // deviation. A two-sided test would have fired here; this tier must not.
        let r = RestingHRWatch.evaluate(flat(20, 49) + [44, 41, 43, 44])
        XCTAssertEqual(r.level, .quiet)
        XCTAssertEqual(r.consecutiveElevatedNights, 0)
    }
}
