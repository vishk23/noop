// Compiled ONLY when the CLOUD_SYNC compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
//
// UPSTREAM BOUNDARY: the CAPTURE half (`Strand/BLE/PuffinDeepBufferLog.swift`) is upstream-safe and
// deliberately knows nothing about this file. Everything that moves a captured byte OFF the device
// lives here, under `Strand/CloudSync/`, behind `#if CLOUD_SYNC` — the same gate as every other
// cloud file. Nothing in `Strand/BLE/` imports, calls, or references anything below.
#if CLOUD_SYNC
import Foundation

/// Pure planning logic for `DeepBufferUploader`: which byte range of the append-only deep-buffer log
/// to ship next, and how to tell one generation of that log from the next. No filesystem, no network,
/// no `UserDefaults` — every function here is a value-in/value-out transform, so the rules that decide
/// "have we already uploaded this?" are unit-testable with no strap, no server, and no device (the
/// BLE path itself cannot be tested at all — see CLAUDE.md's "BLE behavior cannot be CI-tested").
///
/// ## The problem this solves
///
/// `PuffinDeepBufferLog` writes an APPEND-ONLY JSONL file that ALSO ROTATES: at a soft cap it renames
/// `puffin-deepbuffers.jsonl` → `puffin-deepbuffers.jsonl.1` (destroying the previous `.1`) and starts
/// a fresh file. Those two facts together are what make naive "upload from offset N" wrong:
///
/// - Append-only alone would be easy — remember the offset, ship `[offset, size)`, advance.
/// - Rotation breaks that: after a rotation the live file restarts at size 0, so a remembered offset
///   of 90 MB would either skip the whole new generation forever, or (worse, once the new file grows
///   past 90 MB) resume mid-file and ship a byte range from a DIFFERENT generation as though it were
///   a continuation — silently corrupting the archive with no error anywhere.
///
/// So an offset is only meaningful when paired with the identity of the file it indexes into. That
/// pair — `(generation, uploadedOffset)` — is the whole design.
///
/// ## Why the identity is (creationDate, inode)
///
/// `rename(2)` PRESERVES the inode, so a generation keeps its identity across the `.jsonl` → `.jsonl.1`
/// rotation. That is the property that lets a drain that fell behind pick up the un-uploaded tail of a
/// rotated-away generation from `.jsonl.1` at exactly the offset it left off — no special case, no
/// separate bookkeeping, the watermark simply still matches.
///
/// The creation date is in the id because an inode ALONE is not stable over time: rotation
/// `removeItem`s the old `.1`, freeing that inode for the filesystem to hand straight back to the next
/// freshly-created `.jsonl`. Two different generations with the same inode number would collide in the
/// watermark map, and the new generation would inherit the old one's offset — skipping real data. The
/// creation timestamp disambiguates them. `sanitizedWatermark` below is the belt-and-braces backstop
/// for any residual confusion.
///
/// ## Why READ-ONLY, never seal-and-rotate
///
/// The classic log-shipping design seals a segment (rename it aside) and uploads whole sealed files.
/// That is WRONG here: the BLE path holds an open `FileHandle` to the live log, and POSIX semantics
/// mean a writer keeps writing into the renamed inode — so a "sealed" segment would keep growing after
/// it was sealed, and coordinating a close/reopen would mean reaching into the offload ack path. The
/// capture path must never be blocked, slowed, or coupled to the network (see `PuffinDeepBufferLog`'s
/// doc comment on why its hex encoder is hand-rolled: it runs inside the ack path and a few hundred
/// microseconds per buffer already matters). Reading a byte range through a SEPARATE read handle is
/// invisible to the writer: the uploader never mutates the file, never holds the writer's handle, and
/// never needs the writer to know it exists.
enum DeepBufferUploadPlan {

    /// The `<AppSupport>/OpenWhoop/` filename `PuffinDeepBufferLog` writes, and the `.1` its rotation
    /// renames to. DUPLICATED here rather than read from `PuffinDeepBufferLog.logURL()` (which is
    /// `private`) ON PURPOSE: making it internal would edit an upstream-safe BLE file for a
    /// cloud-only reason, and that file must stay free of any reason to think about upload. The path
    /// is a frozen on-disk contract — it is named in `PuffinDeepBufferLog`'s own doc comment and is
    /// where the only copy of already-freed strap buffers lives — so the drift risk is low and
    /// one-directional. `DeepBufferUploaderTests.testLogFilenamesMatchTheCaptureContract` pins it.
    static let liveFilename = "puffin-deepbuffers.jsonl"
    static let rotatedFilename = "puffin-deepbuffers.jsonl.1"
    static let logDirectoryName = "OpenWhoop"

    /// Raw bytes read (and then compressed) per upload. 16 MB raw ≈ 4 MB on the wire at the ~4x these
    /// hex payloads compress to, which is the real constraint: this drains from a `BGAppRefreshTask`,
    /// whose budget is ~30 s of wall clock. A single 90 MB whole-file upload could never finish inside
    /// that window and would be killed and restarted from zero forever; 16 MB slices each land in ~1 s
    /// on LTE, and — because the watermark advances per chunk — a wake that is cut off part-way still
    /// makes permanent forward progress instead of losing everything it did. Chunking is what makes
    /// the background lane viable at all, not just what avoids re-uploading.
    static let maxChunkBytes = 16 * 1024 * 1024

    /// Chunks per drain, bounding one wake's work at 128 MB raw / ~32 MB sent. Enough to clear a
    /// steady-state backlog (the strap banks ~40 KB/s of hex, so even a full day is a handful of runs)
    /// without ever letting a single background wake run unbounded.
    static let maxChunksPerRun = 8

    /// A stable identity for one generation of the log file: `<creation epoch, ms>-<inode>`.
    /// Millisecond precision (not seconds) so a delete/create pair inside the same second still yields
    /// distinct ids if the filesystem also recycles the inode; see the type's doc comment for why
    /// neither component is sufficient alone.
    static func generationId(creationDate: Date?, inode: UInt64) -> String {
        let ms = Int64(((creationDate ?? .distantPast).timeIntervalSince1970 * 1000).rounded())
        return "\(ms)-\(inode)"
    }

    /// Clamp a remembered watermark to what the file can actually support.
    ///
    /// For an append-only file a watermark ABOVE the current size is impossible — the file only ever
    /// grows — so seeing one means the identity is lying to us: an inode got recycled inside the same
    /// millisecond, `UserDefaults` was restored onto a different device, or the file was replaced
    /// out-of-band. Re-uploading a generation from 0 is cheap and idempotent (the server keys objects
    /// by `(generation, byteStart)` and overwrites); resuming from a bogus offset would ship a byte
    /// range that means nothing. Take the safe branch.
    static func sanitizedWatermark(uploaded: Int, fileSize: Int) -> Int {
        (uploaded < 0 || uploaded > fileSize) ? 0 : uploaded
    }

    /// The next byte range to ship for one generation, or nil when the watermark has caught up with
    /// the file. Half-open `[start, end)`, capped at `maxChunk`.
    static func nextRange(uploaded: Int, fileSize: Int, maxChunk: Int = maxChunkBytes) -> Range<Int>? {
        let start = sanitizedWatermark(uploaded: uploaded, fileSize: fileSize)
        guard start < fileSize else { return nil }
        return start..<min(fileSize, start + max(1, maxChunk))
    }

    /// Offset one past the final newline in `data` — i.e. the length of the longest prefix that is
    /// whole JSONL lines — or 0 when `data` holds no complete line at all.
    ///
    /// Two independent reasons this is required, both of which corrupt the archive silently if skipped:
    ///
    /// 1. The writer appends CONCURRENTLY. `stat` can report a size that lands mid-line: `FileHandle`'s
    ///    write of a ~4 KB line is not guaranteed atomic against a reader, so the tail of a read can be
    ///    half a JSON object.
    /// 2. A chunk boundary is arbitrary. `maxChunkBytes` will land in the middle of a line for all but
    ///    a measure-zero set of files.
    ///
    /// Cutting every chunk at a line boundary makes each chunk INDEPENDENTLY VALID JSONL (so the
    /// server can parse it for the manifest without holding neighbouring chunks) while still making
    /// the chunks concatenate back into the exact original file byte-for-byte — the partial line is
    /// not dropped, it is simply left for the next drain, by which time the writer has finished it.
    static func lastCompleteLineEnd(_ data: Data) -> Int {
        guard let idx = data.lastIndex(of: 0x0A) else { return 0 }
        return data.distance(from: data.startIndex, to: idx) + 1
    }

    /// Drop watermarks for generations that no longer exist on disk. Rotation destroys `.jsonl.1`
    /// permanently, so its watermark is dead weight the moment the file is gone; without this the map
    /// grows without bound for the life of the install (one entry per rotation, forever) inside a
    /// `UserDefaults` value that is read and rewritten on every drain.
    static func prunedWatermarks(_ marks: [String: Int], live: Set<String>) -> [String: Int] {
        marks.filter { live.contains($0.key) }
    }
}
#endif // CLOUD_SYNC
