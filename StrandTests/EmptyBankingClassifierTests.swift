import XCTest
@testable import Strand

/// Pins `BLEManager.classifyCompletedOffload` — the pure classification exitBackfilling runs on a
/// COMPLETED (HISTORY_COMPLETE) offload. The #214 fix is the `rowsPersisted == 0` arm: before it, the
/// empty-banking signal had ONE shape (console-only across ≥3 diagnostic chunks), so a NEAR-EMPTY
/// metadata-only completion (zero rows persisted, fewer than 3 console frames) slipped through to the
/// silent branch and surfaced no "charge to 100% and reconnect" guidance. These pin both shapes plus the
/// banking cases, and (with EmptySyncTracker) that the banner only trips after a SUSTAINED streak so a
/// caught-up strap that banked on an earlier cycle never false-alarms (#126).
final class EmptyBankingClassifierTests: XCTestCase {

    // A normal banking cycle (decoded chunks) → banked records, not "nothing".
    func testDecodedChunksAreBanking() {
        let r = BLEManager.classifyCompletedOffload(
            decodedChunks: 5, archivedFrames: 0, unarchivedFrames: 0, consoleChunks: 0, rowsPersisted: 120)
        XCTAssertTrue(r.bankedSensorRecords)
        XCTAssertFalse(r.bankedNothing)
    }

    // Undecodable-but-archived records still prove the clock is banking to flash.
    func testArchivedFramesAreBanking() {
        let r = BLEManager.classifyCompletedOffload(
            decodedChunks: 0, archivedFrames: 8, unarchivedFrames: 0, consoleChunks: 0, rowsPersisted: 0)
        XCTAssertTrue(r.bankedSensorRecords)
        XCTAssertFalse(r.bankedNothing, "archived frames mean the strap handed over real records")
    }

    // The ORIGINAL #77 shape: console-only across ≥3 diagnostic chunks ⇒ banked nothing.
    func testConsoleOnlyAcrossManyChunksIsBankedNothing() {
        let r = BLEManager.classifyCompletedOffload(
            decodedChunks: 0, archivedFrames: 0, unarchivedFrames: 0, consoleChunks: 4, rowsPersisted: 0)
        XCTAssertFalse(r.bankedSensorRecords)
        XCTAssertTrue(r.bankedNothing)
    }

    // The #214 REGRESSION CASE: metadata-only completion — zero rows persisted, FEWER than 3 console
    // frames. Before the broadening this was classified as "banked nothing = false" and stayed silent.
    func testMetadataOnlyZeroRowsIsBankedNothing() {
        let r = BLEManager.classifyCompletedOffload(
            decodedChunks: 0, archivedFrames: 0, unarchivedFrames: 0, consoleChunks: 0, rowsPersisted: 0)
        XCTAssertFalse(r.bankedSensorRecords)
        XCTAssertTrue(r.bankedNothing, "#214: a metadata-only completion that persisted 0 rows banks nothing")
    }

    // A near-empty completion with one or two console frames (still < 3) but zero rows → banked nothing.
    func testFewConsoleFramesZeroRowsIsBankedNothing() {
        let r = BLEManager.classifyCompletedOffload(
            decodedChunks: 0, archivedFrames: 0, unarchivedFrames: 0, consoleChunks: 2, rowsPersisted: 0)
        XCTAssertTrue(r.bankedNothing, "#214: < 3 console frames no longer hides a zero-row completion")
    }

    // A cycle that persisted rows but happened to decode nothing this pass (rows landed via archive/earlier
    // pass) is NOT "banked nothing" — rowsPersisted > 0 keeps it banking.
    func testRowsPersistedIsNotBankedNothing() {
        let r = BLEManager.classifyCompletedOffload(
            decodedChunks: 0, archivedFrames: 0, unarchivedFrames: 0, consoleChunks: 0, rowsPersisted: 40)
        XCTAssertFalse(r.bankedNothing, "rows were persisted — the strap is banking")
    }

    // The new signal still feeds the SUSTAINED-streak gate: 3 consecutive metadata-only completions are
    // required before the banner fires (the #126 guard is unchanged). A row-banking cycle clears it.
    func testMetadataOnlyTripsBannerOnlyWhenSustained() {
        var tracker = EmptySyncTracker()   // default threshold 3
        func classifyMetadataOnly() -> (Bool, Bool) {
            let c = BLEManager.classifyCompletedOffload(
                decodedChunks: 0, archivedFrames: 0, unarchivedFrames: 0, consoleChunks: 0, rowsPersisted: 0)
            return (c.bankedSensorRecords, c.bankedNothing)
        }
        let c1 = classifyMetadataOnly()
        XCTAssertFalse(tracker.recordCompletedSync(bankedSensorRecords: c1.0, consoleOnly: c1.1))
        let c2 = classifyMetadataOnly()
        XCTAssertFalse(tracker.recordCompletedSync(bankedSensorRecords: c2.0, consoleOnly: c2.1))
        let c3 = classifyMetadataOnly()
        XCTAssertTrue(tracker.recordCompletedSync(bankedSensorRecords: c3.0, consoleOnly: c3.1),
                      "#214 + #126: three consecutive metadata-only completions trip the guidance")
    }

    // MARK: - #324/#928 future-dated strap banner

    // A strap whose newest banked record is far in the FUTURE gets the "clock set in the future" banner.
    // This strap BANKS records (bankedNothing = false), so the clock-lost banner never covers it (#324).
    func testFutureDatedNewestSurfacesBanner() {
        let now = 1_783_843_824                     // ~2026-07-12, the reporter's wall clock
        let newest = now + 26_445 * 3600            // 26445 h ahead — the #324 log's banked frontier
        let banner = BLEManager.futureDatedStrapBanner(strapNewestTs: newest, wallNowUnix: now)
        XCTAssertNotNil(banner)
        XCTAssertTrue(banner?.contains("set in the future") == true, banner ?? "nil")
        XCTAssertTrue(banner?.contains("power-cycle") == true, banner ?? "nil")
    }

    // A healthy strap (newest at/behind the wall clock) gets NO future-clock banner.
    func testCurrentStrapNoFutureBanner() {
        let now = 1_783_843_824
        XCTAssertNil(BLEManager.futureDatedStrapBanner(strapNewestTs: now - 3600, wallNowUnix: now))
        XCTAssertNil(BLEManager.futureDatedStrapBanner(strapNewestTs: now, wallNowUnix: now))
    }

    // Inside the 48 h skew allowance (timezone confusion / mild drift) stays silent — matches the gate
    // shared with shouldAutoContinue so the banner and the backfill decision never disagree.
    func testWithinSkewAllowanceNoFutureBanner() {
        let now = 1_783_843_824
        XCTAssertNil(BLEManager.futureDatedStrapBanner(strapNewestTs: now + 24 * 3600, wallNowUnix: now),
                     "24 h ahead is within the 48 h allowance — not flagged")
        XCTAssertNotNil(BLEManager.futureDatedStrapBanner(strapNewestTs: now + 49 * 3600, wallNowUnix: now),
                        "just past 48 h is future-dated")
    }

    // An unknown (nil) strap frontier is UNKNOWN, not future-dated — no banner.
    func testNilNewestNoFutureBanner() {
        XCTAssertNil(BLEManager.futureDatedStrapBanner(strapNewestTs: nil, wallNowUnix: 1_783_843_824))
    }

    // MARK: - §8c per-terminal-reason empty-offload copy (emptyOffloadUserCopy)

    // A COMPLETED-empty offload states what was observed (finished, nothing handed over) and must not
    // assert the "clock has lost sync" diagnosis the old single string carried unmeasured. Clock-fault
    // wording lives only where clock evidence exists (#324/#928 banner, #773/#547 drops).
    func testCompletedEmptyCopyStatesObservationNotClockDiagnosis() {
        let copy = BLEManager.emptyOffloadUserCopy(
            terminal: .completedEmpty, isWhoop5: false,
            hasBankedBeforeOnThisInstall: false, consecutiveEmptySyncs: 3)
        XCTAssertNotNil(copy)
        XCTAssertTrue(copy!.contains("without handing over any stored history"), copy!)
        XCTAssertTrue(copy!.contains("3 syncs in a row"), copy!)
        XCTAssertFalse(copy!.contains("clock has lost sync"),
                       "a completed-empty offload measures no clock fault - it must not assert one")
        XCTAssertTrue(copy!.contains("Fully charge it to 100%"), copy!)
        XCTAssertFalse(copy!.contains("\u{2014}"))
    }

    // On a 5/MG the completed-empty remedy chain ends at the in-app Restart (a 4.0 has none, #275).
    func testCompletedEmptyCopyOffersRestartOnlyOnFiveMG() {
        let five = BLEManager.emptyOffloadUserCopy(
            terminal: .completedEmpty, isWhoop5: true,
            hasBankedBeforeOnThisInstall: true, consecutiveEmptySyncs: 4)
        XCTAssertTrue(five!.contains("restart it from the Devices screen"), five!)
        let four = BLEManager.emptyOffloadUserCopy(
            terminal: .completedEmpty, isWhoop5: false,
            hasBankedBeforeOnThisInstall: true, consecutiveEmptySyncs: 4)
        XCTAssertFalse(four!.contains("restart"), four!)
    }

    // The 2026-08-03 field case: a 5/MG that HAS banked history on this install times out with zero
    // response. That is a wedged command channel, not "no stored history" - the copy names the timeout
    // and puts the in-app Restart BEFORE the charge ritual (the restart is what actually cleared it).
    func testTimedOutEmptyOnBankedBeforeFiveMGSuggestsRestartFirst() {
        let copy = BLEManager.emptyOffloadUserCopy(
            terminal: .timedOutEmpty, isWhoop5: true,
            hasBankedBeforeOnThisInstall: true, consecutiveEmptySyncs: 2)
        XCTAssertNotNil(copy)
        XCTAssertTrue(copy!.contains("didn't answer the history request"), copy!)
        XCTAssertTrue(copy!.contains("has handed over history before"), copy!)
        XCTAssertLessThan(copy!.range(of: "Restart it from the Devices screen")!.lowerBound,
                          copy!.range(of: "fully charging")!.lowerBound,
                          "the in-app Restart comes before the charge ritual")
        XCTAssertFalse(copy!.contains("no stored history"),
                       "a timeout observed no answer at all - it must not claim the strap had nothing")
        XCTAssertFalse(copy!.contains("\u{2014}"))
    }

    // A 5/MG never seen banking keeps the #580 experimental surface (nil - not an error): many 5/MG
    // firmwares genuinely serve no history, and that is not a fault.
    func testTimedOutEmptyOnNeverBankedFiveMGStaysExperimental() {
        XCTAssertNil(BLEManager.emptyOffloadUserCopy(
            terminal: .timedOutEmpty, isWhoop5: true,
            hasBankedBeforeOnThisInstall: false, consecutiveEmptySyncs: 5))
    }

    // A WHOOP 4.0 timeout keeps the caller's existing "went quiet" copy (no in-app restart exists).
    func testTimedOutEmptyOnWhoop4ReturnsNil() {
        XCTAssertNil(BLEManager.emptyOffloadUserCopy(
            terminal: .timedOutEmpty, isWhoop5: false,
            hasBankedBeforeOnThisInstall: true, consecutiveEmptySyncs: 2))
    }

    // A single empty completion reads singular (no "(1 syncs in a row)" grammar slip).
    func testCompletedEmptyCopySingleSyncOmitsStreakClause() {
        let copy = BLEManager.emptyOffloadUserCopy(
            terminal: .completedEmpty, isWhoop5: false,
            hasBankedBeforeOnThisInstall: false, consecutiveEmptySyncs: 1)
        XCTAssertFalse(copy!.contains("in a row"), copy!)
    }

    // A banking cycle between metadata-only completions resets the streak — no false alarm for a strap
    // that's genuinely caught up after banking earlier.
    func testBankingCycleResetsTheMetadataOnlyStreak() {
        var tracker = EmptySyncTracker()
        let empty = BLEManager.classifyCompletedOffload(
            decodedChunks: 0, archivedFrames: 0, unarchivedFrames: 0, consoleChunks: 0, rowsPersisted: 0)
        let banking = BLEManager.classifyCompletedOffload(
            decodedChunks: 3, archivedFrames: 0, unarchivedFrames: 0, consoleChunks: 0, rowsPersisted: 90)
        XCTAssertFalse(tracker.recordCompletedSync(bankedSensorRecords: empty.bankedSensorRecords, consoleOnly: empty.bankedNothing))
        XCTAssertFalse(tracker.recordCompletedSync(bankedSensorRecords: empty.bankedSensorRecords, consoleOnly: empty.bankedNothing))
        XCTAssertFalse(tracker.recordCompletedSync(bankedSensorRecords: banking.bankedSensorRecords, consoleOnly: banking.bankedNothing),
                       "a banking cycle clears the streak")
        XCTAssertEqual(tracker.consecutiveEmptySyncs, 0)
    }
}
