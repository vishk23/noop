import Foundation
import CoreBluetooth
import WhoopProtocol
import StrandAnalytics

/// Durable append-only log of WHOOP 5.0/MG **high-rate deep buffers** — the large type-0x2F (R22)
/// packets that carry tens-of-Hz sensor data (motion + optical) rather than the 1 Hz historical
/// rollup NOOP already decodes (#423).
///
/// On-strap probing (#423) established that the 5/MG has no live raw-IMU stream, but it DOES bank
/// high-rate motion (accel content verified: int16-ish triples sphere-fitting to ~1 g at the 1/4096
/// scale) and ships it inside big type-0x2F buffers during the connect-time offload burst — 124 B
/// (≈1 Hz record), 1244 B and 2140 B (≈32 and ≈59 sub-records per timestamped second). NOOP's
/// historical decoder pulls the 1 Hz gravity vector out and DISCARDS the high-rate remainder. Those
/// bursts are ephemeral and backlog-gated, so a byte-perfect decoder can't be captured on demand — it
/// needs many (raw buffer, wall-clock) pairs accumulated across days of ordinary wear + labeled
/// activity. This log keeps ONLY the big (≥`minBufferBytes`) type-0x2F buffers, in its own file that
/// the bulk `PuffinFrameRecorder` eviction never touches, so they survive long enough to reverse.
///
/// Gated on the same Settings toggle as the frame recorder (`PuffinFrameRecorder.enabledKey`) —
/// capture is passive/read-only with respect to the strap and adds no new setting. One JSONL line per
/// buffer (`{"ts_ms":…,"strap_ts":…,"size":…,"offload":…,"char":…,"hex":"…"[,"imu":{…}]}`); `strap_ts`
/// is the unix second the strap stamped at payload offset 15 (frame byte 15), the load-bearing key for
/// aligning a buffer with what the wearer was doing. The optional `imu` object is the decoded activity
/// summary present only on the 1244-B 6-axis buffer (see `decodedImuField`). Rotates at a soft cap keeping one previous
/// generation, the same idiom as `PuffinEventLog`. Swift-only for now (experimental #423 instrument);
/// a Kotlin twin follows if this graduates past reverse-engineering.
@MainActor
final class PuffinDeepBufferLog {

    /// The 2140-B buffers are ~4.3 KB of hex each and arrive in bursts, so a bigger cap than the
    /// EVENT log: 60 MB live keeps roughly a few hours of accumulated high-rate bursts, ample to
    /// reverse the layout, and rotation bounds total disk at ~120 MB.
    ///
    /// Overridable via the `PuffinDeepBufferSoftCapMB` default because the 60 MB figure is sized for
    /// "a few hours of bursts", which is the STEADY-STATE case. Recovering a dead-strap backlog is the
    /// other case: the strap banks one 1244-B + one 2140-B buffer per SECOND of history, so a 16 h
    /// backlog is ~190 MB raw / ~380 MB of hex — it would rotate away most of itself before the drain
    /// ends, and the ack-trim frees those buffers from the strap permanently as it goes. A one-shot
    /// raise is the only way to keep a full backlog intact. 0 or unset keeps the 60 MB default.
    private static var softCapBytes: Int {
        let mb = UserDefaults.standard.integer(forKey: "PuffinDeepBufferSoftCapMB")
        return (mb > 0 ? mb : 60) * 1024 * 1024
    }

    /// WHOOP 5/MG inner-record type byte for the R22 deep packets (type 47 / 0x2F), at offset 8 (the
    /// same position `BLEManager.isOffloadFrame` / `PuffinEventLog` index). The 1 Hz historical rollup
    /// is also type-0x2F but small; `minBufferBytes` keeps only the high-rate buffers.
    private static let deepTypeByte: UInt8 = 0x2F
    private static let innerRecordOffset = 8
    /// Skip the ~124-B ≈1 Hz record; keep the 1244-/2140-B high-rate buffers.
    private static let minBufferBytes = 1000

    /// Lowercase hex, table-driven. NOT cosmetic: this runs on the MainActor inside the offload ack path,
    /// and the obvious `frame.map { String(format: "%02x", $0) }.joined()` costs one Foundation formatter
    /// call + one String allocation PER BYTE — ~3 ms for a 2140-B buffer. The strap banks one 1244-B and
    /// one 2140-B buffer per second of history, so draining a backlog at 5x real-time formats ~170
    /// buffers/sec ≈ 400 ms of every second, and the strap sits idle waiting for the ack behind it. A
    /// nibble lookup into a byte array is ~80x cheaper and allocates once.
    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)
    nonisolated static func hexString(_ bytes: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(hexDigits[Int(b >> 4)])
            out.append(hexDigits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Pure predicate: is `frame` a WHOOP 5/MG high-rate deep buffer? A reassembled frame's inner-record
    /// type byte sits at offset 8, so this needs `count > 8` before indexing. Extracted so the offset-8
    /// magic number is unit-testable without a strap.
    nonisolated static func isDeepBuffer(_ frame: [UInt8]) -> Bool {
        frame.count > innerRecordOffset
            && frame.count >= minBufferBytes
            && frame[innerRecordOffset] == deepTypeByte
    }

    private var handle: FileHandle?
    private var disabled = false

    private var isEnabled: Bool {
        // LOCAL personal-capture build: force-ON + 600 MB cap to catch the 2026-07-14 dead-strap backlog
        // whole (~380 MB of hex) before the ack-trim frees it from the strap. Never commit this.
        UserDefaults.standard.set(600, forKey: "PuffinDeepBufferSoftCapMB")
        return true
    }

    /// `<AppSupport>/OpenWhoop/puffin-deepbuffers.jsonl` — OUTSIDE `puffin-captures/`, whose soft-cap
    /// eviction deletes oldest files wholesale.
    private static func logURL() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("puffin-deepbuffers.jsonl")
    }

    /// The strap's own unix-second stamp at frame offset 15 (u32 LE), or nil if the frame is too short.
    /// This is the timestamp the high-rate records inside the buffer are relative to.
    private static func strapTs(_ frame: [UInt8]) -> UInt32? {
        guard frame.count > 18 else { return nil }
        return UInt32(frame[15]) | (UInt32(frame[16]) << 8) | (UInt32(frame[17]) << 16) | (UInt32(frame[18]) << 24)
    }

    /// Decoded-IMU field for the JSONL line: `,"imu":{…features…}` when `frame` is the 1244-B 6-axis
    /// IMU buffer, else `""` (the 2140-B optical buffer and everything else). Pure and non-throwing —
    /// a decode miss just omits the field, so a diagnostics-only summary can never disturb the capture
    /// path. `ImuActivityFeatures` is `Codable`, so this is its canonical JSON.
    nonisolated static func decodedImuField(_ frame: [UInt8]) -> String {
        guard frame.count == Whoop5RawImu.bufferLength,
              let decoded = Whoop5RawImu.decode(frame) else { return "" }
        let features = ImuFeatureExtractor.extract(decoded.samples, sampleRateHz: decoded.sampleRateHz)
        guard let data = try? JSONEncoder().encode(features),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return ",\"imu\":\(json)"
    }

    /// Append `frame` if it is a WHOOP 5 high-rate deep buffer and capture is enabled. Cheap for every
    /// other frame: a length + single-byte compare, no parse, BEFORE the `isEnabled` read. Call for both
    /// live and offload frames (`isOffload` recorded so the reverse pass can separate a real-time buffer
    /// from a replayed historical one).
    func appendIfDeepBuffer(frame: [UInt8], char: CBUUID, isOffload: Bool) {
        guard !disabled, Self.isDeepBuffer(frame), isEnabled else { return }
        let tsMs = Int(Date().timeIntervalSince1970 * 1000)
        let strapTs = Self.strapTs(frame).map { String($0) } ?? "null"
        let hex = Self.hexString(frame)
        // #423/#455: run the raw-IMU decoder on the 1244-B buffer so every captured IMU frame carries
        // its decoded activity summary (cadence/energy/jerk/gyro) inline beside the raw hex. This is the
        // first CALLER of `Whoop5RawImu.decode` outside its own tests — it exercises the decoder on real
        // device captures and makes each JSONL line self-checking (raw ↔ decode) with NO stored table,
        // migration, or downstream gate. Instrumentation only, per the derived-signal rule; the 2140-B
        // optical buffer stays raw-only (its layout isn't decoded yet).
        // LIVE frames only — a hygiene measure, NOT a throughput fix. Keeping the honest numbers here so
        // nobody re-derives the wrong conclusion from this file a third time:
        //
        // A real 19 h drain (3,018 buffers / 208 s) shows a mean gap of 89.1 ms after a 1244-B buffer vs
        // 49.0 ms after a 2140-B one. That asymmetry is NOT this decode — it is pure airtime, and reading
        // it as a stall is an off-by-one. A gap is the time for the NEXT frame(s) to arrive, not the
        // previous frame's processing, and the ~124-B v18 record sits between the two logged buffers
        // (it's below `minBufferBytes`, so it is invisible here). So the gap after the 1244-B spans
        // 124+2140 = 2264 B and the gap after the 2140-B spans only 1244 B. One free parameter — the link
        // rate — fixed by the total (3508 B / 138.1 ms = 25.4 KB/s) then predicts the SPLIT with zero
        // further freedom: 89.13 ms and 48.97 ms, against 89.1 and 49.0 observed. The two gaps
        // independently agree on the byte rate to 0.09%. The link is a metronome; there is no stall.
        // Removing this decode measured 7.2x -> 7.7x, consistent with its true ~7 ms cost, not 40 ms.
        //
        // It is still right to skip during offload: it is per-frame work on the MainActor in the delivery
        // path, it buys nothing there, and the raw `hex` on this very line is the decoder's own input — so
        // the summary is recomputable offline from the archive at any time. Live frames arrive ~1/s, where
        // the inline summary is free and makes each line self-checking. Capture captures; analysis is
        // downstream. The real duty-cycle costs are the idle watchdog and the auto-continue cap.
        let imu = isOffload ? "" : Self.decodedImuField(frame)
        let line = "{\"ts_ms\":\(tsMs),\"strap_ts\":\(strapTs),\"size\":\(frame.count),"
            + "\"offload\":\(isOffload),\"char\":\"\(char.uuidString.lowercased())\",\"hex\":\"\(hex)\"\(imu)}\n"
        do {
            var h = try openHandle()
            if try h.offset() > UInt64(Self.softCapBytes) {
                close()
                h = try openHandle()
            }
            try h.write(contentsOf: Data(line.utf8))
        } catch {
            // A diagnostics log must never affect the connection path: disable for this launch.
            disabled = true
        }
    }

    /// Close the handle (e.g. on disconnect) so the file is safe to share/export immediately.
    func close() {
        try? handle?.close()
        handle = nil
    }

    private func openHandle() throws -> FileHandle {
        if let handle = handle { return handle }
        let url = try Self.logURL()
        let fm = FileManager.default
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > Self.softCapBytes {
            let old = url.deletingPathExtension().appendingPathExtension("jsonl.1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
        return h
    }
}
