// Tests the CLOUD_SYNC-gated deep-buffer upload planning logic; compiled only when the flag is set
// (StrandTests shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if CLOUD_SYNC
import XCTest
@testable import Strand

/// Pins `DeepBufferUploadPlan` — the pure rules that decide which bytes of the append-only
/// deep-buffer log have already been shipped. Every function under test is value-in/value-out, so
/// this whole file runs with no strap, no server, no filesystem and no `UserDefaults`. That matters
/// more here than usual: the log holds the ONLY copy of high-rate buffers the strap's ack-trim has
/// already freed, so a re-upload wastes VK's bandwidth but a SKIP silently destroys research data,
/// and neither shows up as an error anywhere.
final class DeepBufferUploadPlanTests: XCTestCase {

    // MARK: - nextRange

    func testNextRangeStartsAtZeroForAnUnseenGeneration() {
        XCTAssertEqual(DeepBufferUploadPlan.nextRange(uploaded: 0, fileSize: 100, maxChunk: 1000), 0..<100)
    }

    func testNextRangeResumesFromTheWatermark() {
        // The whole point of the lane: bytes below the watermark are never read again.
        XCTAssertEqual(DeepBufferUploadPlan.nextRange(uploaded: 60, fileSize: 100, maxChunk: 1000), 60..<100)
    }

    func testNextRangeIsNilWhenCaughtUp() {
        XCTAssertNil(DeepBufferUploadPlan.nextRange(uploaded: 100, fileSize: 100, maxChunk: 1000))
        XCTAssertNil(DeepBufferUploadPlan.nextRange(uploaded: 0, fileSize: 0, maxChunk: 1000))
    }

    func testNextRangeCapsAtMaxChunk() {
        XCTAssertEqual(DeepBufferUploadPlan.nextRange(uploaded: 0, fileSize: 100, maxChunk: 40), 0..<40)
        XCTAssertEqual(DeepBufferUploadPlan.nextRange(uploaded: 80, fileSize: 100, maxChunk: 40), 80..<100)
    }

    // MARK: - sanitizedWatermark (the inode-reuse backstop)

    func testWatermarkAboveFileSizeResetsToZero() {
        // Impossible for an append-only file, so the identity is lying: a recycled inode inside the
        // same millisecond, or UserDefaults restored onto a different device. Re-uploading from 0 is
        // idempotent server-side; resuming from a bogus offset would ship meaningless bytes.
        XCTAssertEqual(DeepBufferUploadPlan.sanitizedWatermark(uploaded: 500, fileSize: 100), 0)
        XCTAssertEqual(DeepBufferUploadPlan.nextRange(uploaded: 500, fileSize: 100, maxChunk: 1000), 0..<100)
    }

    func testNegativeWatermarkResetsToZero() {
        XCTAssertEqual(DeepBufferUploadPlan.sanitizedWatermark(uploaded: -1, fileSize: 100), 0)
    }

    func testWatermarkExactlyAtFileSizeIsKept() {
        // The caught-up case is legitimate, not corruption — it must NOT reset and re-ship the file.
        XCTAssertEqual(DeepBufferUploadPlan.sanitizedWatermark(uploaded: 100, fileSize: 100), 100)
    }

    // MARK: - lastCompleteLineEnd

    func testLastCompleteLineEndCutsATrailingPartialLine() {
        // The writer appends concurrently, so a read can land mid-line. The partial tail is left for
        // the next drain (by which time the line is finished), never shipped as broken JSONL.
        let data = Data("{\"a\":1}\n{\"b\":2}\n{\"c\":".utf8)
        XCTAssertEqual(DeepBufferUploadPlan.lastCompleteLineEnd(data), 16)
    }

    func testLastCompleteLineEndOnAnExactBoundaryKeepsEverything() {
        let data = Data("{\"a\":1}\n{\"b\":2}\n".utf8)
        XCTAssertEqual(DeepBufferUploadPlan.lastCompleteLineEnd(data), data.count)
    }

    func testLastCompleteLineEndIsZeroWithNoNewlineAtAll() {
        // One in-progress line longer than the whole read — nothing complete to ship yet.
        XCTAssertEqual(DeepBufferUploadPlan.lastCompleteLineEnd(Data("{\"a\":1".utf8)), 0)
        XCTAssertEqual(DeepBufferUploadPlan.lastCompleteLineEnd(Data()), 0)
    }

    func testLastCompleteLineEndWorksOnASlice() {
        // `readLineAlignedChunk` hands this whatever `FileHandle.read` returned, and Data slices do not
        // start at index 0 — an implementation using a raw Int index instead of `distance(from:to:)`
        // passes every test above and corrupts exactly this case.
        let full = Data("XXXX{\"a\":1}\n{\"b\":".utf8)
        let slice = full.dropFirst(4)
        XCTAssertEqual(DeepBufferUploadPlan.lastCompleteLineEnd(slice), 8)
    }

    // MARK: - generationId

    func testGenerationIdDistinguishesInodes() {
        let d = Date(timeIntervalSince1970: 1_752_600_000)
        XCTAssertNotEqual(DeepBufferUploadPlan.generationId(creationDate: d, inode: 1),
                          DeepBufferUploadPlan.generationId(creationDate: d, inode: 2))
    }

    func testGenerationIdDistinguishesRecycledInodes() {
        // The reason the creation date is in the id at all: rotation deletes `.jsonl.1`, freeing its
        // inode for the filesystem to hand straight back to the next `.jsonl`. Same inode, different
        // file — if the ids collided, the new generation would inherit the old one's watermark and
        // skip real data.
        XCTAssertNotEqual(
            DeepBufferUploadPlan.generationId(creationDate: Date(timeIntervalSince1970: 1_752_600_000), inode: 7),
            DeepBufferUploadPlan.generationId(creationDate: Date(timeIntervalSince1970: 1_752_600_060), inode: 7))
    }

    func testGenerationIdIsStableForTheSameFile() {
        let d = Date(timeIntervalSince1970: 1_752_600_000.123)
        XCTAssertEqual(DeepBufferUploadPlan.generationId(creationDate: d, inode: 42),
                       DeepBufferUploadPlan.generationId(creationDate: d, inode: 42))
    }

    func testGenerationIdSeparatesSubSecondCreations() {
        // Millisecond precision, not seconds: a delete/create pair inside one second is exactly the
        // case a seconds-resolution id would collapse.
        XCTAssertNotEqual(
            DeepBufferUploadPlan.generationId(creationDate: Date(timeIntervalSince1970: 1_752_600_000.100), inode: 7),
            DeepBufferUploadPlan.generationId(creationDate: Date(timeIntervalSince1970: 1_752_600_000.900), inode: 7))
    }

    func testGenerationIdToleratesAMissingCreationDate() {
        XCTAssertFalse(DeepBufferUploadPlan.generationId(creationDate: nil, inode: 5).isEmpty)
    }

    // MARK: - prunedWatermarks

    func testPruneDropsGenerationsThatNoLongerExist() {
        // Rotation destroys `.jsonl.1` permanently; without this the map grows one dead entry per
        // rotation forever inside a UserDefaults value rewritten on every drain.
        let pruned = DeepBufferUploadPlan.prunedWatermarks(["a": 10, "b": 20, "c": 30], live: ["b", "c"])
        XCTAssertEqual(pruned, ["b": 20, "c": 30])
    }

    func testPruneKeepsEverythingWhenAllGenerationsAreLive() {
        XCTAssertEqual(DeepBufferUploadPlan.prunedWatermarks(["a": 1], live: ["a"]), ["a": 1])
    }
}
#endif // CLOUD_SYNC
