// Tests the CLOUD_SYNC-gated deep-buffer drain; compiled only when the flag is set (StrandTests
// shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if CLOUD_SYNC
import XCTest
@testable import Strand

/// A spy conforming to `DeepBufferIngesting` that records every chunk instead of reaching a network —
/// mirrors `SpyCloudIngester` in `CloudSyncUploaderTests.swift`. `failFrom` makes the Nth call onward
/// throw, so the watermark's failure semantics can be tested without a server.
private final class SpyDeepBufferClient: DeepBufferIngesting {
    struct Call: Equatable {
        let generation: String
        let byteStart: Int
        let byteEnd: Int
        let compressed: Data
    }
    private(set) var calls: [Call] = []
    var failFrom: Int?
    var reportDuplicate = false
    /// Runs INSIDE an upload, standing in for the seconds a real network call takes. The only way to
    /// exercise something rotating the log mid-drain — the window the identity re-check exists for.
    var onUpload: (() -> Void)?

    func uploadDeepBuffer(generation: String, byteStart: Int, byteEnd: Int,
                          compressed: Data) async throws -> DeepBufferUploadReceipt {
        onUpload?()
        if let failFrom, calls.count >= failFrom { throw CloudSyncError.network("simulated failure") }
        calls.append(Call(generation: generation, byteStart: byteStart, byteEnd: byteEnd, compressed: compressed))
        return DeepBufferUploadReceipt(storedBytes: compressed.count, lines: 1, duplicate: reportDuplicate)
    }

    /// Every chunk's payload inflated and concatenated, in the order it was sent.
    func reassembled() -> Data {
        calls.reduce(into: Data()) { acc, c in
            acc.append((try? (c.compressed as NSData).decompressed(using: .zlib) as Data) ?? Data())
        }
    }
}

/// In-memory watermarks, so a test never races the test host's real `UserDefaults` (`StrandTests` runs
/// inside the full app via TEST_HOST — see `CloudSyncModel.isRunningUnderXCTest`).
private final class MemoryWatermarks: DeepBufferWatermarkStoring {
    var marks: [String: Int]
    init(_ marks: [String: Int] = [:]) { self.marks = marks }
    func watermarks() -> [String: Int] { marks }
    func setWatermarks(_ m: [String: Int]) { marks = m }
}

/// Behavioural tests for `DeepBufferUploader.drain` against REAL files in a temp directory — the
/// append-only + rotation semantics it exists to get right are filesystem semantics (`rename(2)`
/// preserving an inode is the load-bearing fact), so faking the filesystem would fake away the thing
/// under test. Only the network is stubbed.
final class DeepBufferUploaderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepbuf-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private var liveURL: URL { dir.appendingPathComponent(DeepBufferUploadPlan.liveFilename) }
    private var rotatedURL: URL { dir.appendingPathComponent(DeepBufferUploadPlan.rotatedFilename) }

    /// `n` JSONL lines shaped like the real log's, from `PuffinDeepBufferLog.appendIfDeepBuffer`.
    private func lines(_ n: Int, startTs: Int = 1_752_600_000) -> Data {
        var out = Data()
        for i in 0..<n {
            let hex = String(repeating: "ab", count: 64)
            out.append(Data("{\"ts_ms\":\((startTs + i) * 1000),\"strap_ts\":\(startTs + i),\"size\":1244,\"offload\":true,\"char\":\"61080002-8d6d-82b8-614a-1c8cb0f8dcc6\",\"hex\":\"\(hex)\"}\n".utf8))
        }
        return out
    }

    private func append(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url)
        } else {
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: data)
        }
    }

    // MARK: - The contract with the capture half

    func testLogFilenamesMatchTheCaptureContract() {
        // `DeepBufferUploadPlan` duplicates these rather than reading `PuffinDeepBufferLog.logURL()`
        // (which is private, and is an upstream-safe file that must stay free of any reason to think
        // about upload). This pins the duplication: if the capture half ever renames its file, this
        // fails rather than the drain silently uploading nothing forever.
        XCTAssertEqual(DeepBufferUploadPlan.liveFilename, "puffin-deepbuffers.jsonl")
        XCTAssertEqual(DeepBufferUploadPlan.rotatedFilename, "puffin-deepbuffers.jsonl.1")
        XCTAssertEqual(DeepBufferUploadPlan.logDirectoryName, "OpenWhoop")
    }

    // MARK: - Nothing to do

    func testDrainWithNoLogFileDoesNothing() async {
        let client = SpyDeepBufferClient(), marks = MemoryWatermarks()
        let s = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir)
        XCTAssertTrue(s.isEmpty)
        XCTAssertTrue(client.calls.isEmpty)
        XCTAssertNil(s.error)
    }

    func testSecondDrainWithNoNewBytesSendsNothing() async throws {
        try append(lines(5), to: liveURL)
        let client = SpyDeepBufferClient(), marks = MemoryWatermarks()
        _ = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir)
        XCTAssertEqual(client.calls.count, 1)

        let second = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir)
        XCTAssertEqual(client.calls.count, 1, "a caught-up drain must not re-send anything")
        XCTAssertTrue(second.isEmpty)
    }

    // MARK: - Append-only: never re-upload

    func testAppendOnlyDrainSendsOnlyTheNewBytes() async throws {
        let first = lines(5)
        try append(first, to: liveURL)
        let client = SpyDeepBufferClient(), marks = MemoryWatermarks()
        _ = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir)
        XCTAssertEqual(client.calls[0].byteStart, 0)
        XCTAssertEqual(client.calls[0].byteEnd, first.count)

        // The strap keeps banking while we were away.
        let second = lines(3, startTs: 1_752_700_000)
        try append(second, to: liveURL)
        _ = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir)

        XCTAssertEqual(client.calls.count, 2)
        XCTAssertEqual(client.calls[1].byteStart, first.count, "the second chunk must resume exactly where the first ended")
        XCTAssertEqual(client.calls[1].byteEnd, first.count + second.count)
        XCTAssertEqual(client.reassembled(), first + second, "chunks must concatenate back to the original file")
    }

    func testUploadedChunksReassembleToTheExactFileBytes() async throws {
        // The archive's whole value is byte fidelity: these buffers are the only copy of packets the
        // strap has already freed. Many small chunks, so several boundaries are exercised.
        let body = lines(40)
        try append(body, to: liveURL)
        let client = SpyDeepBufferClient(), marks = MemoryWatermarks()
        let s = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir,
                                                maxChunks: 100, maxChunkBytes: 600)
        XCTAssertGreaterThan(client.calls.count, 3, "the small chunk cap must actually split this file")
        XCTAssertNil(s.error)
        XCTAssertEqual(client.reassembled(), body)
    }

    // MARK: - Line alignment

    func testChunksAreCutAtLineBoundariesNotAtTheByteCap() async throws {
        let body = lines(10)
        try append(body, to: liveURL)
        let client = SpyDeepBufferClient(), marks = MemoryWatermarks()
        // 600 B against a 256 B fixture line: ~2.3 lines per chunk, so every chunk boundary lands
        // mid-line and the alignment logic is actually exercised. It must stay ABOVE one line — see
        // testAChunkCapSmallerThanOneLineShipsNothingRatherThanACorruptLine for that boundary.
        _ = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir,
                                            maxChunks: 100, maxChunkBytes: 600)
        for call in client.calls {
            let inflated = (try? (call.compressed as NSData).decompressed(using: .zlib) as Data) ?? Data()
            XCTAssertEqual(inflated.last, 0x0A, "every chunk must end on a newline")
            // Each chunk must independently parse as JSONL — that is what lets the server build the
            // manifest from one chunk without holding its neighbours.
            for line in inflated.split(separator: 0x0A) {
                XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line)),
                                 "each line in a chunk must be valid JSON on its own")
            }
        }
        XCTAssertEqual(client.reassembled(), body)
    }

    func testAPartialTrailingLineIsHeldBackUntilItIsComplete() async throws {
        // The writer appends concurrently and `stat` can report a size that lands mid-line. The partial
        // tail must be left for the next drain, never shipped as broken JSONL and never skipped.
        let whole = lines(3)
        try append(whole, to: liveURL)
        try append(Data("{\"ts_ms\":1752600099,\"strap".utf8), to: liveURL) // an in-progress line

        let client = SpyDeepBufferClient(), marks = MemoryWatermarks()
        _ = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir)
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(client.calls[0].byteEnd, whole.count, "the drain must stop at the last complete line")

        // The writer finishes the line; the next drain picks it up from exactly there.
        try append(Data("_ts\":1752600099,\"size\":1244,\"offload\":true,\"char\":\"c\",\"hex\":\"ab\"}\n".utf8), to: liveURL)
        _ = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir)
        XCTAssertEqual(client.calls.count, 2)
        XCTAssertEqual(client.calls[1].byteStart, whole.count)

        let onDisk = try Data(contentsOf: liveURL)
        XCTAssertEqual(client.reassembled(), onDisk, "the held-back line must arrive, not be skipped")
    }

    func testAChunkCapSmallerThanOneLineShipsNothingRatherThanACorruptLine() async throws {
        // The boundary of the line-alignment rule, pinned deliberately. A chunk cap below one line
        // length has no complete line to cut at, so the drain ships NOTHING for that generation and
        // stays stuck there. That is the correct trade for THIS archive — its entire value is byte
        // fidelity for buffers the strap has already freed, so a truncated line is worse than a
        // stalled upload — but it is a silent stall, so it is pinned rather than left to be
        // rediscovered.
        //
        // UNREACHABLE in production by ~3800x: the largest line the capture path can emit is the
        // 2140-B optical buffer as hex (~4.4 KB), against maxChunkBytes of 16 MB. The strap's buffer
        // sizes are fixed, so this cannot drift into reach without a protocol change.
        let body = lines(4)
        try append(body, to: liveURL)
        let client = SpyDeepBufferClient(), marks = MemoryWatermarks()
        let s = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir,
                                                maxChunks: 10, maxChunkBytes: 100) // < one 256 B line
        XCTAssertEqual(client.calls.count, 0, "no complete line fits, so nothing may be shipped")
        XCTAssertNil(s.error, "this is not an error path — it is 'nothing shippable yet'")
        XCTAssertTrue(marks.marks.isEmpty, "and no watermark may be invented for bytes never sent")
    }

    // MARK: - Rotation

    func testRotationResumesTheRotatedGenerationAndStartsTheNewOneAtZero() async throws {
        // The scenario the (generation, offset) pair exists for. A plain offset would either skip the
        // new generation entirely or resume mid-file into unrelated bytes.
        let genA = lines(6)
        try append(genA, to: liveURL)
        let client = SpyDeepBufferClient(), marks = MemoryWatermarks()
        // Drain only part of generation A, so it has a non-zero watermark when it rotates away.
        _ = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir,
                                            maxChunks: 1, maxChunkBytes: 400)
        let drainedFromA = client.calls[0].byteEnd
        XCTAssertLessThan(drainedFromA, genA.count, "this test needs A to be only partly drained")

        // PuffinDeepBufferLog's rotation: live -> .1 (rename preserves the inode), then a fresh live.
        try FileManager.default.moveItem(at: liveURL, to: rotatedURL)
        let genB = lines(4, startTs: 1_752_800_000)
        try append(genB, to: liveURL)

        _ = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir,
                                            maxChunks: 100, maxChunkBytes: 10_000)

        let generations = Set(client.calls.map(\.generation))
        XCTAssertEqual(generations.count, 2, "the rotated file and the fresh file must be distinct generations")

        // A's identity survived the rename, so its tail resumed at the watermark rather than restarting.
        let aCalls = client.calls.filter { $0.generation == client.calls[0].generation }
        XCTAssertEqual(aCalls.count, 2)
        XCTAssertEqual(aCalls[1].byteStart, drainedFromA, "the rotated generation must resume, not restart")
        XCTAssertEqual(aCalls[1].byteEnd, genA.count)

        // B is a different file and must start from 0 — not inherit A's offset.
        let bCalls = client.calls.filter { $0.generation != client.calls[0].generation }
        XCTAssertEqual(bCalls.first?.byteStart, 0, "a fresh generation must start at 0")

        let inflatedA = aCalls.reduce(into: Data()) { $0.append((try! ($1.compressed as NSData).decompressed(using: .zlib)) as Data) }
        XCTAssertEqual(inflatedA, genA, "generation A must arrive whole across the rotation")
    }

    func testRotationDuringADrainCannotSpliceTheWrongGenerationsBytes() async throws {
        // `testRotationResumes…` rotates BETWEEN drains, which is the easy case and cannot catch this.
        // The real gap is INSIDE one drain: `scanGenerations` binds identity to (creationDate, inode),
        // but the read re-opens by PATH, and between them sits a network upload — seconds. A rotation
        // there leaves the path valid and pointing at a DIFFERENT file, so the read silently returns
        // generation B's bytes, which get stapled into A's archive under A's id AND acked — advancing
        // A's watermark past a tail that was never uploaded. Two silent corruptions, no error raised,
        // of the only copy of buffers the strap's ack-trim has already freed.
        let genA = lines(8)
        try append(genA, to: liveURL)
        let client = SpyDeepBufferClient(), marks = MemoryWatermarks()

        // Rotate at the moment the first chunk is in flight — exactly when a 60 MB cap would trip.
        client.onUpload = { [self] in
            client.onUpload = nil                                   // once
            try? FileManager.default.moveItem(at: liveURL, to: rotatedURL)
            try? append(lines(8, startTs: 1_752_900_000), to: liveURL)   // a fresh, DIFFERENT live file
        }

        _ = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir,
                                            maxChunks: 4, maxChunkBytes: 400)

        // The invariant that was broken: every chunk stored under a generation must BE that
        // generation's bytes at the offsets it claims. genA is the only generation with a known
        // ground truth here (the post-rotation live file is a different, freshly-written one).
        XCTAssertFalse(client.calls.isEmpty, "precondition: the drain must actually ship something")
        let aGen = client.calls[0].generation
        let aCalls = client.calls.filter { $0.generation == aGen }.sorted { $0.byteStart < $1.byteStart }
        for c in aCalls {
            let inflated = (try! (c.compressed as NSData).decompressed(using: .zlib)) as Data
            XCTAssertEqual(inflated, genA.subdata(in: c.byteStart..<c.byteEnd),
                           "chunk [\(c.byteStart),\(c.byteEnd)) under \(aGen) must be THAT file's bytes — "
                           + "a rotation mid-drain must never splice another generation in")
        }
        // And no watermark may sit past what was actually shipped for its generation: that difference
        // is a tail nothing will ever re-send, because the watermark says it is already done.
        for (gen, mark) in marks.marks {
            let shipped = client.calls.filter { $0.generation == gen }.map(\.byteEnd).max() ?? 0
            XCTAssertLessThanOrEqual(mark, shipped,
                                     "watermark \(mark) for \(gen) is past the \(shipped) shipped — that tail is lost")
        }
    }

    func testTheRotatedGenerationIsDrainedBeforeTheLiveOne() async throws {
        // `.jsonl.1` is what the NEXT rotation deletes forever, so it is the data most at risk and must
        // go first. It is also the older data, which keeps the archive in wall-clock order.
        try append(lines(2, startTs: 1_752_500_000), to: rotatedURL)
        try append(lines(2, startTs: 1_752_900_000), to: liveURL)
        let client = SpyDeepBufferClient(), marks = MemoryWatermarks()
        _ = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir)

        XCTAssertEqual(client.calls.count, 2)
        let firstInflated = String(decoding: (try! (client.calls[0].compressed as NSData).decompressed(using: .zlib)) as Data, as: UTF8.self)
        XCTAssertTrue(firstInflated.contains("1752500000"), "the rotated (older, at-risk) generation must drain first")
    }

    func testWatermarksArePrunedWhenAGenerationDisappears() async throws {
        try append(lines(2), to: liveURL)
        let client = SpyDeepBufferClient(), marks = MemoryWatermarks(["dead-generation-id": 999])
        _ = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir)
        XCTAssertNil(marks.marks["dead-generation-id"], "a watermark for a file that no longer exists must be dropped")
        XCTAssertEqual(marks.marks.count, 1)
    }

    // MARK: - Failure semantics

    func testAFailedUploadDoesNotAdvanceTheWatermarkAndRetriesTheSameRange() async throws {
        try append(lines(5), to: liveURL)
        let client = SpyDeepBufferClient(), marks = MemoryWatermarks()
        client.failFrom = 0 // fail the very first call

        let failed = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir)
        XCTAssertNotNil(failed.error)
        XCTAssertEqual(failed.chunks, 0)
        XCTAssertTrue(marks.marks.isEmpty, "a failed chunk must leave no watermark behind")

        // The server comes back; the same range is re-sent from the start, losing nothing.
        client.failFrom = nil
        let ok = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir)
        XCTAssertNil(ok.error)
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(client.calls[0].byteStart, 0)
        XCTAssertEqual(client.reassembled(), try Data(contentsOf: liveURL))
    }

    func testAMidDrainFailureKeepsTheChunksThatAlreadyLanded() async throws {
        try append(lines(30), to: liveURL)
        let client = SpyDeepBufferClient(), marks = MemoryWatermarks()
        client.failFrom = 2 // two chunks land, the third throws

        let s = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir,
                                                maxChunks: 100, maxChunkBytes: 600)
        XCTAssertNotNil(s.error)
        XCTAssertEqual(s.chunks, 2, "partial progress must be reported, not rolled back")
        let watermark = marks.marks.values.first
        XCTAssertEqual(watermark, client.calls[1].byteEnd, "the watermark must sit at the last CONFIRMED byte")

        // Recovery resumes from there — no gap, no overlap.
        client.failFrom = nil
        _ = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir,
                                            maxChunks: 100, maxChunkBytes: 600)
        XCTAssertEqual(client.calls[2].byteStart, client.calls[1].byteEnd)
        XCTAssertEqual(client.reassembled(), try Data(contentsOf: liveURL))
    }

    // MARK: - Bounded work per run

    func testDrainStopsAtMaxChunksAndFlagsMoreRemaining() async throws {
        try append(lines(50), to: liveURL)
        let client = SpyDeepBufferClient(), marks = MemoryWatermarks()
        let s = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir,
                                                maxChunks: 2, maxChunkBytes: 400)
        XCTAssertEqual(s.chunks, 2)
        XCTAssertEqual(client.calls.count, 2)
        XCTAssertTrue(s.moreRemaining, "a drain cut short by the chunk cap must say the backlog is not clear")
    }

    func testMoreRemainingIsFalseOnceTheBacklogIsClear() async throws {
        try append(lines(3), to: liveURL)
        let client = SpyDeepBufferClient(), marks = MemoryWatermarks()
        let s = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir)
        XCTAssertFalse(s.moreRemaining)
    }

    func testDuplicateReceiptsAreCounted() async throws {
        try append(lines(2), to: liveURL)
        let client = SpyDeepBufferClient(), marks = MemoryWatermarks()
        client.reportDuplicate = true
        let s = await DeepBufferUploader.drain(client: client, watermarks: marks, directory: dir)
        XCTAssertEqual(s.duplicates, 1)
        XCTAssertEqual(s.chunks, 1, "a duplicate still counts as a shipped chunk — the watermark advances")
    }

    // MARK: - Compression

    func testDeflateRoundTripsThroughApplesOwnDecoder() {
        let body = lines(20)
        let compressed = DeepBufferUploader.deflate(body)
        XCTAssertNotNil(compressed)
        let back = try? (compressed! as NSData).decompressed(using: .zlib) as Data
        XCTAssertEqual(back, body)
    }

    func testHexJsonlBeatsTheHexAlphabetFloorEvenOnIncompressiblePayloads() {
        // The premise of compressing on the phone at all — asserted against the WORST case, not a
        // flattering one. The payload here is uniformly RANDOM, i.e. carries no exploitable structure
        // whatsoever; all deflate can recover is that hex spends 8 bits per 4 bits of entropy, plus the
        // JSON scaffolding. Real strap buffers are 100 Hz IMU with strong sample-to-sample correlation
        // and can only do BETTER than this, so a ratio measured here is a genuine lower bound rather
        // than an artefact of a repetitive fixture. (Deliberately NOT asserting the 3-5x figure the
        // design assumes: that is unverified against a real capture, and a synthetic fixture that
        // "confirms" it would be measuring itself.)
        var body = Data()
        for i in 0..<200 {
            var payload = [UInt8](repeating: 0, count: 1244)
            for j in 0..<payload.count { payload[j] = UInt8.random(in: 0...255) }
            body.append(Data("{\"ts_ms\":\((1_752_600_000 + i) * 1000),\"strap_ts\":\(1_752_600_000 + i),\"size\":1244,\"offload\":true,\"char\":\"6108\",\"hex\":\"\(PuffinDeepBufferLog.hexString(payload))\"}\n".utf8))
        }
        let compressed = DeepBufferUploader.deflate(body)!
        let ratio = Double(body.count) / Double(compressed.count)
        XCTAssertGreaterThan(ratio, 1.5, "even incompressible payloads must beat the hex floor; got \(ratio)x")
    }
}
#endif // CLOUD_SYNC
