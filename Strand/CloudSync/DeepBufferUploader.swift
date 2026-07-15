// Compiled ONLY when the CLOUD_SYNC compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
//
// UPSTREAM BOUNDARY: see DeepBufferUploadPlan.swift's header. The capture half never references this.
#if CLOUD_SYNC
import Foundation
import Compression

/// Abstracts the deep-buffer chunk POST so `DeepBufferUploader` is testable with no network — the same
/// seam shape as `CloudIngesting` (`CloudSyncUploader`) and `CloudEditFetching` (`CloudSyncCoordinator`).
/// `CloudSyncClient` conforms in `CloudSyncClient+DeepBuffer.swift`.
protocol DeepBufferIngesting {
    func uploadDeepBuffer(generation: String, byteStart: Int, byteEnd: Int,
                          compressed: Data) async throws -> DeepBufferUploadReceipt
}
extension CloudSyncClient: DeepBufferIngesting {}

/// What the server says it did with a chunk. `duplicate` is not a failure: the drain is at-least-once
/// (the watermark only advances on a confirmed 2xx, so a response lost in flight re-sends the same
/// range), and the server keys objects by `(generation, byteStart)` — so a re-send is an idempotent
/// overwrite, and saying so lets the drain log the difference instead of double-counting bytes.
struct DeepBufferUploadReceipt: Equatable {
    let storedBytes: Int
    let lines: Int
    let duplicate: Bool
}

/// One generation of the on-disk log, as `scanGenerations` found it.
struct DeepBufferGeneration: Equatable {
    let id: String
    let url: URL
    let size: Int
}

/// The outcome of one drain, for the status line and the tests.
struct DeepBufferDrainSummary: Equatable {
    var chunks = 0
    var rawBytes = 0
    var sentBytes = 0
    var lines = 0
    var duplicates = 0
    /// True when the drain stopped because it hit `maxChunksPerRun`, not because it ran out of data —
    /// i.e. there is more backlog and the next wake should run again immediately rather than wait.
    var moreRemaining = false
    var error: String?

    var isEmpty: Bool { chunks == 0 && error == nil }
}

/// Where the per-generation byte watermarks live. A protocol so tests get a deterministic in-memory
/// map instead of racing the test host's real `UserDefaults`.
protocol DeepBufferWatermarkStoring: AnyObject {
    func watermarks() -> [String: Int]
    func setWatermarks(_ marks: [String: Int])
}

/// Production watermark storage. `UserDefaults`, not a `WhoopStore` cursor — the same call as
/// `CloudSyncModel.lastUploadTokenKey` (see its doc comment): this is per-device bookkeeping about an
/// upload THIS device performed, not data the store owns, and `cursors` only holds `Int` values keyed
/// by a single name anyway, where this needs a whole generation→offset map.
final class DeepBufferUserDefaultsWatermarks: DeepBufferWatermarkStoring {
    static let key = "cloudsync.deepbuf.watermarks"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func watermarks() -> [String: Int] {
        (defaults.dictionary(forKey: Self.key) as? [String: Int]) ?? [:]
    }
    func setWatermarks(_ marks: [String: Int]) {
        defaults.set(marks, forKey: Self.key)
    }
}

/// Ships `PuffinDeepBufferLog`'s append-only JSONL to the noop-cloud server in compressed,
/// line-aligned byte-range chunks, resuming from a per-generation watermark so nothing is ever sent
/// twice and nothing is skipped. The correctness argument for the `(generation, offset)` pair, and for
/// reading the live file rather than sealing segments, is in `DeepBufferUploadPlan`'s doc comment.
///
/// A namespace of static functions with no state of its own, like `CloudSyncUploader` — the only
/// durable state is the watermark map, which is injected.
///
/// NEVER touches the BLE path: it opens its own read-only `FileHandle`, reads a bounded byte range,
/// and closes it. `PuffinDeepBufferLog` (which is `@MainActor`, and whose `appendIfDeepBuffer` runs
/// inside the offload ack path) is not referenced, imported, or awaited from anywhere in here. This
/// type is deliberately NOT `@MainActor`: the read + deflate of a 16 MB slice is real CPU work and
/// belongs on a cooperative thread, not on the actor the capture path is trying to use.
enum DeepBufferUploader {

    /// `<AppSupport>/OpenWhoop/` — the directory `PuffinDeepBufferLog` writes into. Resolved here
    /// rather than borrowed from that (upstream-safe, `private`) type; see
    /// `DeepBufferUploadPlan.liveFilename`'s doc comment for why the duplication is deliberate.
    static func defaultLogDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent(DeepBufferUploadPlan.logDirectoryName, isDirectory: true)
    }

    /// The generations present in `dir`, ROTATED FIRST then live.
    ///
    /// Rotated-first is the load-bearing order: `.jsonl.1` is the generation the NEXT rotation deletes
    /// forever, so it is the data most at risk and must drain first. It is also the chronologically
    /// older one, so this keeps the uploaded archive in wall-clock order for free.
    ///
    /// Deduped by generation id: rotation runs on the MainActor while this scan runs off it, so a scan
    /// that interleaves with a rename can in principle observe one inode under both filenames. Keeping
    /// the first occurrence (the rotated path) rather than uploading the same generation twice under
    /// two names costs nothing and removes the race from every caller's reasoning.
    static func scanGenerations(in dir: URL) -> [DeepBufferGeneration] {
        var seen = Set<String>()
        var out: [DeepBufferGeneration] = []
        for name in [DeepBufferUploadPlan.rotatedFilename, DeepBufferUploadPlan.liveFilename] {
            let url = dir.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.intValue,
                  let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else { continue }
            let id = DeepBufferUploadPlan.generationId(creationDate: attrs[.creationDate] as? Date,
                                                        inode: inode)
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(DeepBufferGeneration(id: id, url: url, size: size))
        }
        return out
    }

    /// Read `range` from `url` through a private read handle, then cut the result back to its last
    /// complete line (see `DeepBufferUploadPlan.lastCompleteLineEnd`). Returns nil when the range
    /// yields no complete line — e.g. a single in-progress line longer than the read, or a file that
    /// vanished under a rotation between the scan and here.
    ///
    /// `expecting` is the generation id the caller scanned, and this re-checks it THROUGH THE OPEN
    /// DESCRIPTOR. That is the whole point: the scan binds a generation's identity to (creationDate,
    /// inode), but this opens by PATH, and the gap between the two spans a network upload — seconds,
    /// not microseconds. `PuffinDeepBufferLog` rotates by renaming `.jsonl` -> `.jsonl.1`, so a
    /// rotation landing in that gap leaves the path perfectly valid and pointing at a DIFFERENT file.
    /// The read then succeeds and returns the wrong generation's bytes, which the caller staples into
    /// the previous generation's archive under its id AND acks — advancing that generation's watermark
    /// past a tail it never uploaded. Two silent corruptions, no error anywhere, and the archive is the
    /// only copy of buffers the strap's ack-trim has already freed.
    ///
    /// A rename cannot change what an open fd refers to, so fstat-ing the descriptor after opening is
    /// authoritative where a path re-check would still race. Mismatch => bail; the next drain rescans
    /// and picks the generation up at its true watermark.
    static func readLineAlignedChunk(url: URL, range: Range<Int>, expecting generation: String?) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if let expected = generation {
            var st = stat()
            guard fstat(handle.fileDescriptor, &st) == 0 else { return nil }
            let birth = Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec)
                + TimeInterval(st.st_birthtimespec.tv_nsec) / 1_000_000_000)
            guard DeepBufferUploadPlan.generationId(creationDate: birth, inode: UInt64(st.st_ino)) == expected,
                  range.upperBound <= Int(st.st_size) else { return nil }
        }
        guard (try? handle.seek(toOffset: UInt64(range.lowerBound))) != nil,
              let raw = try? handle.read(upToCount: range.count), !raw.isEmpty else { return nil }
        let end = DeepBufferUploadPlan.lastCompleteLineEnd(raw)
        guard end > 0 else { return nil }
        return raw.prefix(end)
    }

    /// Raw DEFLATE, via Apple's Compression framework.
    ///
    /// `.zlib` here is a MISNOMER in Apple's own API: `COMPRESSION_ZLIB` emits a RAW DEFLATE stream
    /// with NO zlib header or Adler-32 trailer, which is why the server inflates it with
    /// `zlib.inflateRawSync` and not `inflateSync`. Getting this pair wrong fails at runtime with an
    /// "incorrect header check", never at compile time, on both sides — it is pinned end-to-end by
    /// `DeepBufferCompressionTests` (Swift side) and `test/deepbuf.test.ts` (the Node inflate of real
    /// Swift-produced bytes).
    ///
    /// The phone has CPU to spare for this and it is nowhere near the BLE critical path (see the type's
    /// doc comment) — the whole point of paying it here is that hex JSONL is the most compressible
    /// thing this app produces: every payload byte is two ASCII nibbles, so half the entropy is
    /// structural before the IMU's own sample-to-sample correlation is considered.
    static func deflate(_ data: Data) -> Data? {
        try? (data as NSData).compressed(using: .zlib) as Data
    }

    /// Drain every generation from its watermark up to the file's current end, oldest first, stopping
    /// at `maxChunks`.
    ///
    /// The watermark advances ONLY after a confirmed 2xx, and only for the range that call actually
    /// acknowledged. That single rule is what makes the whole lane safe under failure: a dropped
    /// connection, a killed background task, a 500, or a phone that runs out of budget mid-drain all
    /// leave the watermark exactly where the last CONFIRMED byte ended, so the next run re-sends that
    /// range and nothing else. Combined with the server's `(generation, byteStart)` idempotency this is
    /// at-least-once delivery onto an idempotent sink — i.e. effectively exactly-once — without the
    /// phone having to track anything but one integer per generation.
    ///
    /// A per-generation failure STOPS that generation (its later bytes cannot be shipped before its
    /// earlier ones without leaving a hole the watermark can't express) but the summary still reports
    /// whatever landed before it, so partial progress is never rolled back.
    @discardableResult
    static func drain(client: any DeepBufferIngesting,
                      watermarks: any DeepBufferWatermarkStoring,
                      directory: URL? = nil,
                      maxChunks: Int = DeepBufferUploadPlan.maxChunksPerRun,
                      maxChunkBytes: Int = DeepBufferUploadPlan.maxChunkBytes) async -> DeepBufferDrainSummary {
        var summary = DeepBufferDrainSummary()
        let dir: URL
        do { dir = try directory ?? defaultLogDirectory() } catch {
            summary.error = "Couldn't locate the deep-buffer log directory. \(error.localizedDescription)"
            return summary
        }
        let generations = scanGenerations(in: dir)
        guard !generations.isEmpty else { return summary }

        // Prune BEFORE draining, against the generations actually on disk right now — a rotation that
        // destroyed `.jsonl.1` also destroyed any reason to remember its offset.
        var marks = DeepBufferUploadPlan.prunedWatermarks(watermarks.watermarks(),
                                                           live: Set(generations.map(\.id)))

        for generation in generations {
            while summary.chunks < maxChunks {
                let uploaded = marks[generation.id] ?? 0
                guard let range = DeepBufferUploadPlan.nextRange(uploaded: uploaded,
                                                                  fileSize: generation.size,
                                                                  maxChunk: maxChunkBytes) else { break }
                guard let chunk = readLineAlignedChunk(url: generation.url, range: range,
                                                       expecting: generation.id) else {
                    // No complete line in this range: either the writer is mid-line at the very tail
                    // (normal — the next drain gets it once the line is finished) or the file rotated
                    // away underneath us. Neither is an error; move to the next generation.
                    break
                }
                guard let body = deflate(chunk) else {
                    summary.error = "Couldn't compress the deep-buffer chunk."
                    watermarks.setWatermarks(marks)
                    return summary
                }
                let byteStart = range.lowerBound
                let byteEnd = byteStart + chunk.count // the LINE-ALIGNED end, not range.upperBound
                do {
                    let receipt = try await client.uploadDeepBuffer(generation: generation.id,
                                                                     byteStart: byteStart,
                                                                     byteEnd: byteEnd,
                                                                     compressed: body)
                    marks[generation.id] = byteEnd
                    watermarks.setWatermarks(marks) // persist per chunk: a kill mid-drain keeps progress
                    summary.chunks += 1
                    summary.rawBytes += chunk.count
                    summary.sentBytes += body.count
                    summary.lines += receipt.lines
                    if receipt.duplicate { summary.duplicates += 1 }
                } catch {
                    summary.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    watermarks.setWatermarks(marks)
                    return summary
                }
            }
            if summary.chunks >= maxChunks { break }
        }
        watermarks.setWatermarks(marks)
        // Anything still behind its file's end means the cap cut us short, not that we finished.
        summary.moreRemaining = generations.contains { (marks[$0.id] ?? 0) < $0.size }
        return summary
    }
}
#endif // CLOUD_SYNC
