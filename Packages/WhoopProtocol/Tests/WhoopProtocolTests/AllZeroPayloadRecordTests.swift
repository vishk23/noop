import XCTest
@testable import WhoopProtocol

/// `isAllZeroPayloadRecord` — the gate that keeps the Backfiller's reject hex dump (#91 / #30) from
/// full-frame-dumping records whose payload is entirely zero. Observed shape: structurally valid
/// 1584 B frames (21-byte header + 1,559 zero bytes + 4-byte CRC32 trailer), banked once per second
/// by a WHOOP 5/MG after a raw-data config-flag write. These mirror the Android
/// `AllZeroPayloadRecordTest` 1:1 — SAME bounds, SAME behavior.
final class AllZeroPayloadRecordTests: XCTestCase {

    /// A frame in the observed shape: nonzero header bytes, an all-zero payload, a nonzero CRC trailer.
    private func zeroPayloadFrame(size: Int = 1584) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: size)
        for i in 0..<21 { f[i] = UInt8((i &* 7) &+ 1) }   // arbitrary nonzero header
        f[0] = 0xAA                                        // observed magic
        for i in (size - 4)..<size { f[i] = 0xCD }         // nonzero CRC32 trailer
        return f
    }

    func testObservedShapeIsAllZeroPayload() {
        XCTAssertTrue(isAllZeroPayloadRecord(zeroPayloadFrame()))
    }

    func testSingleNonzeroPayloadByteDefeatsIt() {
        // One nonzero byte anywhere in the payload region means there IS something to map — dump it.
        for offset in [21, 800, 1579] {
            var f = zeroPayloadFrame()
            f[offset] = 0x01
            XCTAssertFalse(isAllZeroPayloadRecord(f), "nonzero byte at \(offset) must defeat the check")
        }
    }

    func testNonzeroHeaderAndTrailerAreIgnored() {
        // The header and CRC trailer are ALWAYS nonzero on a real frame; only the payload matters.
        var f = zeroPayloadFrame()
        for i in 0..<21 { f[i] = 0xFF }
        for i in (f.count - 4)..<f.count { f[i] = 0xFF }
        XCTAssertTrue(isAllZeroPayloadRecord(f))
    }

    func testTooShortFrameIsNeverAllZeroPayload() {
        // A frame with no payload region at all (≤ header + trailer) must be dumped, not summarized —
        // there is nothing to classify, and short frames are exactly the unfamiliar ones worth seeing.
        XCTAssertFalse(isAllZeroPayloadRecord([UInt8](repeating: 0, count: 25)))
        XCTAssertFalse(isAllZeroPayloadRecord([UInt8](repeating: 0, count: 24)))
        XCTAssertFalse(isAllZeroPayloadRecord([]))
    }

    func testMinimalOneBytePayload() {
        // 26 B = 21 header + 1 payload byte + 4 trailer: the smallest frame the check can classify.
        var f = [UInt8](repeating: 0, count: 26)
        f[0] = 0xAA
        XCTAssertTrue(isAllZeroPayloadRecord(f))
        f[21] = 0x01
        XCTAssertFalse(isAllZeroPayloadRecord(f))
    }

    func testSmallUnmappedRecordsStayDumpable() {
        // v25/v26-sized records (~84 B) with real payload bytes — the frames #91's dump exists for —
        // must never be classified as zero-payload.
        var f = [UInt8](repeating: 0, count: 84)
        f[0] = 0xAA
        f[40] = 0x5A
        XCTAssertFalse(isAllZeroPayloadRecord(f))
    }
}
