import Foundation
import CoreBluetooth
import WhoopProtocol

/// App-side glue around the pure `PuffinCapture`: gates on a user toggle, stamps each frame with a
/// wall-clock time and the live (standard-profile) heart rate, and persists the growing capture to a
/// JSON file under Application Support. Read-only with respect to the strap — it only records frames
/// that already arrived, it never writes to the device — so it is always safe to leave on.
///
/// `@MainActor` because it reads `LiveState.heartRate` and updates published capture status; the
/// BLEManager delegate callbacks that feed it are already on the main queue.
@MainActor
final class PuffinFrameRecorder {
    /// UserDefaults flag, mirrored by the Settings toggle (`@AppStorage`). Separate from the puffin
    /// *probe* switch (`PuffinExperiment`): capturing is passive/safe, probing actively guesses.
    static let enabledKey = "noopPuffinCapture"

    /// Flush to disk every this-many frames so a crash/yank loses at most a handful of frames.
    private static let flushEvery = 25

    /// Soft cap on the total size of the puffin-captures directory (#27). One file is written per app
    /// launch and never trimmed, so without a cap the directory grows without bound — an experimental
    /// capture toggle a 5/MG user left on reached 19 GB. After each flush, oldest files are evicted
    /// (by filename, which is timestamp-sorted) until the total is back under the cap. Never deletes
    /// the file the current session is still writing.
    private static let directorySoftCapBytes = 50 * 1024 * 1024

    private weak var state: LiveState?
    private let buffer = PuffinCapture()
    private var sinceFlush = 0
    private var fileURL: URL?

    /// Compact (single-line) encoder for the append-only NDJSON live file (#tetherpull). Distinct from
    /// `PuffinCapture.encodedJSON()`'s pretty-printed whole-array output: NDJSON needs each record on ONE
    /// line. `sortedKeys` keeps each line's key order stable; no `.prettyPrinted` so there are no embedded
    /// newlines to break the one-record-per-line contract.
    private static let ndjsonEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return enc
    }()

    init(state: LiveState) {
        self.state = state
    }

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// `<AppSupport>/OpenWhoop/puffin-captures/`, created on demand.
    private static func captureDirectory() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
            .appendingPathComponent("puffin-captures", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Record one puffin frame (off `fd4b0003/0004/0005/0007`). No-op unless capture is enabled.
    func capture(frame: [UInt8], char: CBUUID) {
        guard isEnabled else { return }
        let tsMs = Int(Date().timeIntervalSince1970 * 1000)
        let record = buffer.record(frame: frame, char: char.uuidString.lowercased(),
                                   tsMs: tsMs, hr: state?.heartRate)
        // Continuous live mirror (#tetherpull): ALSO append this frame as one NDJSON line to
        // `Documents/noop-live-puffin.ndjson`, so the FULL raw stream — including any overnight type-47
        // historical records — lands on disk as it arrives and survives the in-memory `PuffinCapture` cap,
        // pullable by `devicectl copy from` at any time with no manual export. Additive: the buffered
        // capture + the periodic `flush()` to the Application Support file are untouched.
        if let line = try? Self.ndjsonEncoder.encode(record),
           let text = String(data: line, encoding: .utf8) {
            LiveDebugFiles.appendPuffinLine(text)
        }
        sinceFlush += 1
        state?.puffinCaptureCount = buffer.count
        if sinceFlush >= Self.flushEvery { flush() }
    }

    /// Write the full capture to disk (best-effort, atomic). Called periodically and on disconnect.
    func flush() {
        guard buffer.count > 0 else { return }
        do {
            let url = try sessionFileURL()
            let data = try buffer.encodedJSON()
            try data.write(to: url, options: .atomic)
            sinceFlush = 0
            state?.puffinCaptureURL = url
            // Bound on-disk growth (#27): evict oldest captures beyond the soft cap, never the
            // file this session is still writing.
            Self.evictOldCaptures(keeping: url)
        } catch {
            // Best-effort: a failed flush just means the next one rewrites the whole file.
        }
    }

    /// Enforce the directory soft cap by deleting the oldest capture files (best-effort). Filenames are
    /// `puffin-yyyyMMdd-HHmmss.json`, so lexicographic order is chronological — delete from the front
    /// until the total is back under the cap. `keep` (the active session file) is never deleted.
    private static func evictOldCaptures(keeping keep: URL) {
        let fm = FileManager.default
        guard let dir = try? captureDirectory() else { return }
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return }
        // Sort oldest-first by name (timestamped). Pair each with its size up front.
        let files = entries
            .filter { $0.pathExtension == "json" }
            .map { (url: $0, size: (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files {
            guard total > directorySoftCapBytes else { break }
            if file.url == keep { continue }   // never delete the active session file
            do {
                try fm.removeItem(at: file.url)
                total -= file.size
            } catch {
                // Best-effort: skip a file we couldn't remove; the next flush retries.
            }
        }
    }

    /// One file per recorder lifetime (i.e. per app launch), named on first use. Re-flushing rewrites
    /// the same file, so the capture file always holds the complete session.
    private func sessionFileURL() throws -> URL {
        if let url = fileURL { return url }
        let stamp = Self.fileStampFormatter.string(from: Date())
        let url = try Self.captureDirectory().appendingPathComponent("puffin-\(stamp).json")
        fileURL = url
        return url
    }

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
