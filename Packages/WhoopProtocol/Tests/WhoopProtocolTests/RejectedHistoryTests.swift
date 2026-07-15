import XCTest
@testable import WhoopProtocol

/// Tests for `rejectedHistoricalRecords` — the history-loss guard (#77 / #91). It returns the
/// HISTORICAL_DATA (type-47) record frames that would otherwise be silently dropped (CRC failure or
/// an unmapped layout), so the Backfiller can archive them BEFORE acking the trim. Frames that
/// decode cleanly, console (type-50) frames, and 5/MG v26 PPG blocks must NOT be returned.
final class RejectedHistoryTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    // A synthetic WHOOP 4.0 V24 type-47 record (HR=63) that decodes cleanly (from HistoricalV24Tests).
    private let v24Hex =
        "aa5a008e2f18000000000000f153650000000000003f0152030000000000000000dc053075" +
        "000000cdcc4c3dcdcccc3d5a657e3f00000040cdcc4c3dcdcccc3d5a657e3f504668428403" +
        "200364006400b80bb80b000000000000c25c1a88"

    // A real WHOOP 5/MG type-47 v18 record (HR present, decodes cleanly; from Whoop5HistoricalTests).
    private let whoop5V18Hex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    // A real WHOOP 5/MG type-47 v26 record — the high-rate PPG waveform buffer NOOP stores by design.
    private let whoop5V26Hex =
        "aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc8bfd4cfebafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84fe15ff5cff405fb33c50080101006cb67c17"

    // MARK: - clean records are NOT rejected

    func testDecodableWhoop4RecordNotRejected() {
        let rejected = rejectedHistoricalRecords([bytes(v24Hex)], family: .whoop4)
        XCTAssertTrue(rejected.isEmpty, "a cleanly-decoding type-47 record must not be flagged as lost")
    }

    func testDecodableWhoop5RecordNotRejected() {
        let rejected = rejectedHistoricalRecords([bytes(whoop5V18Hex)], family: .whoop5)
        XCTAssertTrue(rejected.isEmpty)
    }

    // MARK: - undecodable records ARE rejected

    func testCRCCorruptWhoop4RecordIsRejected() {
        // Flip a payload byte so the CRC32 trailer mismatches (crcOK == false) but the type byte is
        // still 47 — exactly the silent-loss case the guard exists to catch.
        var bad = bytes(v24Hex)
        bad[10] ^= 0xFF
        let f = parseFrame(bad)
        XCTAssertEqual(f.crcOK, false, "precondition: the corrupted frame must fail CRC")
        let rejected = rejectedHistoricalRecords([bad], family: .whoop4)
        XCTAssertEqual(rejected, [bad])
    }

    func testCRCCorruptWhoop5RecordIsRejected() {
        var bad = bytes(whoop5V18Hex)
        bad[20] ^= 0xFF                    // corrupt a biometric payload byte (type byte @8 untouched)
        XCTAssertEqual(bad[8], 47)         // still a HISTORICAL_DATA record
        let rejected = rejectedHistoricalRecords([bad], family: .whoop5)
        XCTAssertEqual(rejected, [bad])
    }

    // MARK: - by-design skips are NEVER rejected

    func testConsoleFrameExcluded() {
        // type-50 CONSOLE_LOGS is strap-side debug text — decodes to zero rows by design, never lost.
        let console = frameFromPayload([0x01, 0x02, 0x03, 0x04], type: 50, seq: 0, cmd: 0)
        XCTAssertEqual(console[4], 50)
        XCTAssertTrue(rejectedHistoricalRecords([console], family: .whoop4).isEmpty)
    }

    func testWhoop5V26PpgExcluded() {
        let v26 = bytes(whoop5V26Hex)
        XCTAssertEqual(v26[8], 47)         // it IS a type-47 record…
        XCTAssertEqual(v26[9], 26)         // …but version 26 (PPG), skipped by design — not lost data
        XCTAssertTrue(rejectedHistoricalRecords([v26], family: .whoop5).isEmpty)
    }

    func testWhoop5V20AndV21DeepBuffersExcluded() {
        // Header bytes taken verbatim from a real 5/MG offload (fw 50.40.1.0): the strap banks one v18 +
        // one v21 (1244 B) + one v20 (2140 B) per SECOND of history, so on a real backlog these are ~34
        // of every 51 records. Both DECODE fine (`decodeWhoop5HistoricalV2021` → optical/IMU channels);
        // they only LOOK undecodable to the unmapped-layout predicate because they carry no heart_rate
        // and no gravity_x — exactly why v26 is exempted too. Archiving them hex-dumps ~3.4 KB/s of
        // history into the 5 MB raw archive, whose at-cap rewrite then blocks the trim ack.
        let v21 = bytes("aa01d40401005c702f1580c585af000ea4566a1e45046400640003005bfb53fb66fb5dfb")
        let v20 = bytes("aa0154080100b5b32f1481c585af000ea4566a1e4504001900001901160d042c1a032000")
        XCTAssertEqual(v21[8], 47)          // type-47 HISTORICAL_DATA…
        XCTAssertEqual(v21[9], 21)          // …version 21 — a known, decoded layout
        XCTAssertEqual(v20[8], 47)
        XCTAssertEqual(v20[9], 20)          // …version 20 — likewise
        XCTAssertTrue(rejectedHistoricalRecords([v21], family: .whoop5).isEmpty,
                      "v21 deep buffer decodes — it must not be archived as undecodable")
        XCTAssertTrue(rejectedHistoricalRecords([v20], family: .whoop5).isEmpty,
                      "v20 deep buffer decodes — it must not be archived as undecodable")
        // The whole batch shape a real offload delivers: nothing here belongs in the reject archive.
        XCTAssertTrue(rejectedHistoricalRecords([v20, v21, v20, v21], family: .whoop5).isEmpty)
    }

    func testNonHistoricalFrameExcluded() {
        // A REALTIME_DATA (type-40) frame is live, not offload — never a history-loss candidate.
        let realtime = frameFromPayload([0x01, 0x02, 0x03], type: 40, seq: 0, cmd: 0)
        XCTAssertTrue(rejectedHistoricalRecords([realtime], family: .whoop4).isEmpty)
    }

    func testTooShortFrameExcluded() {
        XCTAssertTrue(rejectedHistoricalRecords([[0xAA, 0x01]], family: .whoop4).isEmpty)
        XCTAssertTrue(rejectedHistoricalRecords([[]], family: .whoop5).isEmpty)
    }

    // MARK: - mixed batch returns only the genuine losses, in order

    func testMixedBatchReturnsOnlyRejects() {
        var bad = bytes(v24Hex); bad[10] ^= 0xFF   // undecodable
        let good = bytes(v24Hex)                   // clean
        let console = frameFromPayload([0x00], type: 50, seq: 0, cmd: 0)
        let rejected = rejectedHistoricalRecords([good, bad, console], family: .whoop4)
        XCTAssertEqual(rejected, [bad])
    }
}
