import XCTest
@testable import Strand

/// `LiveState.capForPersist` — the per-line cap applied at PERSIST time to the durable UserDefaults
/// log tail. The in-memory ring keeps full lines; the cap only stops a full-frame reject hex dump
/// (~3,168 chars, #91) from inflating the persisted blob that every subsequent persist re-serializes.
@MainActor
final class LiveStatePersistTailTests: XCTestCase {

    // Ordinary diagnostic lines pass through byte-identical.
    func testShortLineUnchanged() {
        XCTAssertEqual(LiveState.capForPersist("connected ok"), "connected ok")
    }

    // A line exactly at the cap is NOT truncated — the suffix only appears when chars were dropped.
    func testExactCapLineUnchanged() {
        let line = String(repeating: "x", count: LiveState.persistedLineCap)
        XCTAssertEqual(LiveState.capForPersist(line), line)
    }

    // One char over: truncated to the cap with an explicit overflow marker, never silently short.
    func testOneOverCapTruncatesWithMarker() {
        let line = String(repeating: "x", count: LiveState.persistedLineCap + 1)
        XCTAssertEqual(LiveState.capForPersist(line),
                       String(repeating: "x", count: LiveState.persistedLineCap) + "… (+1 more)")
    }

    // The motivating case: a 3,168-char full-frame hex dump persists as cap + marker, and the marker
    // states exactly how many chars were dropped.
    func testHexDumpSizedLineCapsWithCount() {
        let hex = String(repeating: "ab", count: 1584)   // 3,168 chars, one hex pair per frame byte
        let capped = LiveState.capForPersist(hex)
        XCTAssertTrue(capped.hasPrefix(String(repeating: "ab", count: LiveState.persistedLineCap / 2)))
        XCTAssertTrue(capped.hasSuffix("… (+\(3_168 - LiveState.persistedLineCap) more)"))
        XCTAssertLessThan(capped.count, 560)   // cap + a short marker, nowhere near the original
    }

    // The cap preserves the line's PREFIX — where the Backfiller puts the frame size and the record
    // header hex — so a capped dump still identifies which frame it was.
    func testPrefixSurvivesCapping() {
        let line = "Backfill: rejected frame[0] 1584B: aa0128" + String(repeating: "00", count: 2000)
        XCTAssertTrue(LiveState.capForPersist(line).hasPrefix("Backfill: rejected frame[0] 1584B: aa0128"))
    }
}
