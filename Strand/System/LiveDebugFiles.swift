import Foundation

/// Continuous, zero-touch auto-persist of the live strap diagnostics into the app's **Documents**
/// directory (#tetherpull), the on-disk twin of the OSLog tether in [LiveState.append(log:)].
///
/// `UIFileSharingEnabled` (iOS) exposes Documents to `devicectl … copy from --domain-type
/// appDataContainer … --source Documents`, so a developer on a tethered Mac can pull these two files
/// off the dev app's container root-free, at ANY time, with no manual share-sheet step and no waiting
/// for the daily [ScheduledDebugExport] timer — the files are kept current AS data flows:
///
/// - `noop-live-strap-log.txt` — the current strap connection-log tail, rewritten (throttled) as new
///   lines accumulate. Capped to the live ring (`LiveState.maxLogLines`), so the same bounded ~24h
///   window the in-app log holds.
/// - `noop-live-puffin.ndjson` — the raw 5/MG "puffin" frames as newline-delimited JSON, append-only.
///   Each captured frame is one JSON line, so the FULL stream (including overnight type-47 historical
///   records) lands on disk continuously and survives the in-memory `PuffinCapture` cap. An overnight
///   session is ~10 MB, which is acceptable here.
///
/// Fixed (un-timestamped) names on purpose: a developer's `devicectl copy from` and any watch/tail
/// script can hard-code the path because it never rotates. This is PURELY ADDITIVE — it sits beside the
/// in-app log buffer, the manual "Export…" buttons, and the daily [ScheduledDebugExport] timestamped
/// drops, none of which it touches. On-device only; nothing is sent anywhere.
enum LiveDebugFiles {

    /// Current strap connection-log tail, refreshed (throttled) as new lines accumulate.
    static let strapLogName = "noop-live-strap-log.txt"
    /// Raw 5/MG puffin frames, newline-delimited JSON, append-only.
    static let puffinName = "noop-live-puffin.ndjson"

    /// The app's Documents directory URL — resolved the SAME way [ScheduledDebugExport] does, the folder
    /// `UIFileSharingEnabled` exposes to devicectl. `nonisolated` (touches only FileManager) so the
    /// throttled log writer and the recorder's per-frame append can both reach it off the main actor.
    nonisolated static func documentsURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// Full URL of the live strap-log file, or nil if Documents can't be resolved.
    nonisolated static func strapLogURL() -> URL? {
        documentsURL()?.appendingPathComponent(strapLogName)
    }

    /// Full URL of the live puffin NDJSON file, or nil if Documents can't be resolved.
    nonisolated static func puffinURL() -> URL? {
        documentsURL()?.appendingPathComponent(puffinName)
    }

    /// Append one already-encoded NDJSON line (no trailing newline; this adds it) to the live puffin
    /// file, creating it on first use. Append-only and best-effort: a failed write just drops that one
    /// line rather than disturbing the in-memory capture or the manual export. Opening the handle per
    /// call keeps the recorder free of long-lived file state and is cheap at puffin frame rates.
    nonisolated static func appendPuffinLine(_ line: String) {
        guard let url = puffinURL() else { return }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Best-effort: a failed append drops one line; the next frame retries.
        }
    }
}
