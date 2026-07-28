import Foundation

/// #423 follow-up: a READ-ONLY probe of the optical **AFE control cluster** — `GET_LED_DRIVE` (40 / 0x28),
/// `GET_TIA_GAIN` (42 / 0x2a) and `GET_AFE_PARAMETERS` (62 / 0x3e).
///
/// ## Why this cluster, and why read-only first
///
/// The 2,140-byte v20 optical record reports, per 422-byte block, an LED **source selector**
/// (`ledASource` / `ledBSource`) and an LED **drive** value (`ledA` / `ledB`). The selectors are plain
/// `UInt8`s with no named enum anywhere in this repo, so the physical emitter each one selects is
/// unknown — which is the single blocker on reading a red/IR pair out of that record.
///
/// Measured on this project's own 29,203-record corpus of those frames, over a 13.72-hour span:
/// `ledASource` is **constant** at 1, 3, 2, 2, 2 for blocks 0–4 and `ledBSource` is **constant** at 4 in
/// every block, in 29,203 / 29,203 records. Nothing about the selector varies while the strap is merely
/// observed. So the record is a read-out of a configuration this project has never been able to move,
/// and observation alone cannot separate the selector values.
///
/// The six-opcode AFE cluster in the repo's own `CommandNumber` table
/// (`Packages/WhoopProtocol/…/Resources/whoop_protocol.json`) is the only named surface that could turn
/// that into a controlled experiment: drive a known emitter, see which block responds. **Nothing in this
/// tree has ever sent any of the six.**
///
/// This probe deliberately implements only the three **GET** verbs. The reason is not timidity, it is
/// information order: nobody knows the parameter body layout for the SET side, so a write would be a
/// guess at bytes that reconfigure the optical front end, while a read that answers costs one round-trip
/// and tells you whether the surface exists at all. **A read that answers is worth more than a write that
/// guesses.**
///
/// ## Body shape is unknown, and that is handled empirically rather than assumed
///
/// No body layout for 40 / 42 / 62 has ever been observed. Rather than assert one, the probe asks each
/// verb three times with the three body shapes this codebase has already seen a WHOOP strap
/// discriminate between: **empty**, `[0x00]`, and `[0x01]`. That is not a new idea here —
/// `GET_CLOCK` is already sent in *both* the empty and the `[0x00]` form by `BLEManager`, precisely
/// because its accepted payload length is firmware-specific (#120), and `GET_BATTERY_LEVEL` is sent with
/// `[0x00]` on one path and `[]` on another. Three bodies × three verbs = 9 round-trips.
///
/// A verb that answers to one body and refuses another has told you its body shape for free. A verb that
/// refuses all three has not been proven absent — only that none of these three shapes satisfies it, and
/// the report says exactly that rather than the stronger thing.
///
/// ## What each outcome means, declared BEFORE the run
///
/// The result codes are the ones a real WHOOP 5 MG has already been observed to use on this transport
/// (0 FAILURE / 1 SUCCESS / 2 PENDING / 3 UNSUPPORTED):
///
/// - **All three verbs `UNSUPPORTED(3)`** — this firmware does not serve the AFE control cluster. That
///   retires the "drive a known LED and watch which channel responds" experiment entirely and leaves the
///   physical front-camera check as the only remaining route to emitter identity. A real, publishable
///   result.
/// - **Any verb `SUCCESS(1)`** — there is a read channel into the optical front end. Only *then* is a
///   paired SET worth designing, and it can be designed against an observed body rather than a guessed
///   one.
/// - **All `FAILURE(0)`** — the verbs are known to the firmware but none of the three body shapes
///   satisfies them. The next step is a body-shape sweep, still read-only. It is **not** a write.
/// - **Silence** — inconclusive, and reported as inconclusive. A verb that never replies has said
///   nothing; do not read a missing reply as a refusal.
///
/// ## The limit of what a GET can ever establish — read this before designing the follow-up
///
/// Even a perfect read of every AFE register returns **selector values and drive levels, not
/// wavelengths.** Learning that `ledASource == 1` in block 0 is already known from the record itself;
/// learning which register a selector writes is a *structural* fact. Inferring a physical property
/// (emitted wavelength) from a structural one is the exact reasoning failure that produced this
/// project's retracted `R5 = IR / R6 = red` claim. This probe therefore **cannot** identify a
/// wavelength, and no report it renders says that it can. What it can do is establish whether the
/// control surface exists, which is the precondition for a controlled experiment that a physical
/// measurement then has to close.
///
/// ## Read-only by construction
///
/// `sendableOpcodes` is the complete set this probe may put on the wire, and `isReadOnlyOpcode` is the
/// predicate the BLE send path is meant to consult — the same discipline as
/// `DeviceConfigReadProbe.isReadOnlyOpcode`: ONE pure predicate, so the unit tests that prove what it
/// rejects are proving it about the wire path rather than about a copy of the rule. The three SET verbs
/// and the two optical stream toggles are named in `excludedWriteOpcodes` for exactly one reason: so the
/// exclusion is testable by name instead of by absence.
///
/// Everything fails closed. A frame whose CRCs do not verify, whose type is not `COMMAND_RESPONSE`, or
/// whose record is too short is REJECTED, never guessed at.
public enum AfeReadProbe {

    // MARK: - Wire constants

    /// `GET_LED_DRIVE` (40 / 0x28). Read-only. Named in the repo's `CommandNumber` table; never sent by
    /// anything in this tree, and possibly unimplemented on this firmware.
    public static let getLedDriveCmd: UInt8 = 40

    /// `GET_TIA_GAIN` (42 / 0x2a). Read-only. The transimpedance-amplifier gain read; the SET twin (41)
    /// is in the table but there is no GET/SET symmetry assumption here — 42 is sent because the table
    /// names it, not because 41 exists.
    public static let getTiaGainCmd: UInt8 = 42

    /// `GET_AFE_PARAMETERS` (62 / 0x3e). Read-only. Sits immediately below `SEND_R10_R11_REALTIME` (63)
    /// in the table; adjacency is a numbering observation and carries no implication about behaviour.
    public static let getAfeParametersCmd: UInt8 = 62

    /// The complete set of opcodes this probe may put on the wire. The BLE send path admits these three
    /// and **only** these three while a probe is in flight.
    public static let sendableOpcodes: Set<UInt8> = [getLedDriveCmd, getTiaGainCmd, getAfeParametersCmd]

    /// The AFE cluster's WRITE verbs and the two optical stream toggles, which this probe must never
    /// emit. Kept as a named set so the read-only contract is testable as a property of the allowlist
    /// rather than as a claim in a comment.
    ///
    /// 39 `SET_LED_DRIVE`, 41 `SET_TIA_GAIN`, 61 `SET_AFE_PARAMETERS` reconfigure the optical front end.
    /// 107 `ENABLE_OPTICAL_DATA` and 108 `TOGGLE_OPTICAL_MODE` change what the strap emits. None of the
    /// five is sent here, and none has an observed body layout in this project.
    public static let excludedWriteOpcodes: Set<UInt8> = [39, 41, 61, 107, 108]

    /// The allowlist predicate. `false` for every SET verb, for both optical toggles, and therefore for
    /// anything a future edit might accidentally route through this path.
    public static func isReadOnlyOpcode(_ opcode: UInt8) -> Bool { sendableOpcodes.contains(opcode) }

    /// The three request bodies each verb is asked with, in order. No layout for these opcodes has ever
    /// been observed, so rather than assert one the probe tries the three shapes this codebase has
    /// already seen a strap discriminate between (`GET_CLOCK` is sent both empty and as `[0x00]`
    /// because the accepted length is firmware-specific — #120).
    public static let bodyShapes: [[UInt8]] = [[], [0x00], [0x01]]

    /// Hard ceiling on round-trips in one probe, independent of the plan. A firmware that answers oddly
    /// must not be able to drive an unbounded write loop on the command characteristic. The plan is
    /// 3 verbs × 3 bodies = 9; a plan that somehow exceeds this stops with a named reason rather than
    /// truncating silently.
    public static let maxSteps = 12

    /// Human label for an opcode this probe knows, taken from the repo's own `CommandNumber` table.
    public static func label(for opcode: UInt8) -> String {
        switch opcode {
        case getLedDriveCmd:       return "GET_LED_DRIVE"
        case getTiaGainCmd:        return "GET_TIA_GAIN"
        case getAfeParametersCmd:  return "GET_AFE_PARAMETERS"
        case 39:  return "SET_LED_DRIVE"
        case 41:  return "SET_TIA_GAIN"
        case 61:  return "SET_AFE_PARAMETERS"
        case 107: return "ENABLE_OPTICAL_DATA"
        case 108: return "TOGGLE_OPTICAL_MODE"
        default:  return "opcode \(opcode)"
        }
    }

    /// Render a body shape for the report.
    public static func bodyLabel(_ body: [UInt8]) -> String {
        body.isEmpty ? "(empty)" : body.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    // MARK: - Corroboration reference (structural only)

    /// The six block-0 `ledA` drive values observed in **29,203 / 29,203** records of this project's own
    /// v20 optical corpus. Used for ONE narrow structural check and nothing else.
    ///
    /// > **What a hit means, and what it does not.** If a `GET_LED_DRIVE` record contains a u16 LE from
    /// > this set, that is evidence the verb reads the same register family the optical record reports —
    /// > a structural link between two surfaces. **It says nothing whatsoever about wavelength**, and a
    /// > numeric coincidence is not an identification. It is reported as a flagged observation, never as
    /// > a conclusion.
    public static let observedBlock0DriveValues: Set<UInt16> = [1150, 1400, 1750, 2200, 2750, 3350]

    /// Every u16 LE in `record` that is a member of `observedBlock0DriveValues`, with its offset. Pure
    /// structural search over a sliding window; no field layout is assumed or implied.
    public static func driveSetMatches(in record: [UInt8]) -> [(offset: Int, value: UInt16)] {
        guard record.count >= 2 else { return [] }
        var hits: [(Int, UInt16)] = []
        for i in 0...(record.count - 2) {
            let v = UInt16(record[i]) | (UInt16(record[i + 1]) << 8)
            if observedBlock0DriveValues.contains(v) { hits.append((i, v)) }
        }
        return hits
    }

    // MARK: - Decoded response

    /// Why a frame was not decoded. Distinct cases so the report can say *what* went wrong instead of
    /// silently dropping a reply. Mirrors `DeviceConfigReadProbe.ParseFailure`.
    public enum ParseFailure: String, Error, Equatable, Sendable {
        /// A CRC did not verify. Bad bytes never drive state (BLE safety contract §2).
        case crc
        /// Not a COMMAND_RESPONSE frame, or too short to hold the envelope.
        case envelope
        /// A COMMAND_RESPONSE for a different command.
        case wrongCommand
        /// The record is shorter than a response record can be.
        case truncated
    }

    /// One decoded AFE-read reply. Deliberately shallow: the record is kept RAW because no field layout
    /// for these three opcodes has ever been observed anywhere in this project.
    public struct AfeResponse: Equatable, Sendable {
        /// Result code byte (`pay[1]`), labelled only on 5/MG where its meaning is pinned
        /// (0 FAILURE / 1 SUCCESS / 2 PENDING / 3 UNSUPPORTED); nil on WHOOP 4.0.
        public let resultCode: Int?
        /// The record bytes behind the 2-byte response header, exactly as received.
        public let record: [UInt8]

        public init(resultCode: Int?, record: [UInt8]) {
            self.resultCode = resultCode
            self.record = record
        }

        /// The firmware explicitly refused the verb — the single most informative outcome available, and
        /// the one that settles "is this opcode implemented at all" in one round-trip.
        public var isUnsupported: Bool { resultCode == 3 }
        /// The firmware answered and reported success.
        public var isSuccess: Bool { resultCode == 1 }
        /// The firmware answered but reported failure — the verb exists, this request did not satisfy it.
        public var isFailure: Bool { resultCode == 0 }

        /// Raw record bytes as lowercase space-separated hex; always reported, whatever else decodes.
        public var recordHex: String { AfeReadProbe.hex(record) }
    }

    /// Decode an AFE-read COMMAND_RESPONSE for `expecting`. CRC-gated: a frame whose checksums fail is
    /// rejected before any field is read.
    public static func parse(frame: [UInt8], family: DeviceFamily,
                             expecting: UInt8) -> Result<AfeResponse, ParseFailure> {
        // BLE safety contract §2: CRC-gate everything. A frame that fails either checksum is not data.
        guard verifyFrame(frame, family: family).ok else { return .failure(.crc) }
        let typeOff = family == .whoop5 ? 8 : 4
        let cmdOff = typeOff + 2
        guard frame.count > cmdOff + 4 else { return .failure(.envelope) }
        guard frame[typeOff] == commandResponseType else { return .failure(.envelope) }
        guard frame[cmdOff] == expecting else { return .failure(.wrongCommand) }
        let payStart = cmdOff + 1
        let payEnd = frame.count - 4          // strip the CRC32 trailer
        guard payEnd > payStart else { return .failure(.truncated) }
        let pay = Array(frame[payStart..<payEnd])
        guard pay.count > responseHeaderBytes else { return .failure(.truncated) }
        let resultCode: Int? = family == .whoop5 ? Int(pay[1]) : nil
        return .success(AfeResponse(resultCode: resultCode, record: Array(pay[responseHeaderBytes...])))
    }

    /// COMMAND_RESPONSE packet type (`PacketType.COMMAND_RESPONSE` = 36 / 0x24).
    static let commandResponseType: UInt8 = 36

    /// Bytes of response header ahead of the packet record. `pay[1]` is the 5/MG result code.
    static let responseHeaderBytes = 2

    /// Lowercase space-separated hex, capped so one oversized record cannot flood the report. The cap is
    /// reported when it bites rather than silently truncating.
    static func hex(_ bytes: [UInt8]) -> String {
        let shown = bytes.prefix(maxHexBytes)
        var out = shown.map { String(format: "%02x", $0) }.joined(separator: " ")
        if bytes.count > maxHexBytes { out += " … (\(bytes.count) bytes)" }
        return out.isEmpty ? "(empty)" : out
    }

    /// Record bytes rendered in the report before the hex is elided.
    static let maxHexBytes = 48

    /// Pad `s` on the right to `width`, used instead of a printf `%-Ns` so Swift and any future Kotlin
    /// twin render the report identically.
    static func padded(_ s: String, to width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
}

// MARK: - Report

/// The running result of one AFE read probe: the plan, each verb's reply, and the copyable transcript.
/// Pure and order-dependent (`nextStep` → `note…` → `nextStep` → …), so `swift test` covers the whole
/// probe — plan, verdict, rendering — without a strap.
public struct AfeReadProbeReport: Equatable, Sendable {

    /// One planned round-trip: an opcode and the body shape to ask it with.
    public struct Step: Equatable, Sendable {
        public let opcode: UInt8
        public let body: [UInt8]
        public init(opcode: UInt8, body: [UInt8]) {
            self.opcode = opcode
            self.body = body
        }
    }

    /// What came back for one step. `resultCode == nil` with `replied == false` means the strap never
    /// answered — recorded as silence, never as a refusal.
    public struct Reading: Equatable, Sendable {
        public let opcode: UInt8
        public let body: [UInt8]
        public let replied: Bool
        public let resultCode: Int?
        public let recordHex: String
        public let recordBytes: Int
        /// Offsets at which the record holds a u16 LE from the observed block-0 drive set. A STRUCTURAL
        /// observation only — see `AfeReadProbe.observedBlock0DriveValues` for what it does not mean.
        public let driveSetHits: [Int]
        /// Set when a reply arrived but could not be decoded, naming why.
        public let parseFailure: AfeReadProbe.ParseFailure?

        public init(opcode: UInt8, body: [UInt8], replied: Bool, resultCode: Int?,
                    recordHex: String, recordBytes: Int, driveSetHits: [Int],
                    parseFailure: AfeReadProbe.ParseFailure?) {
            self.opcode = opcode
            self.body = body
            self.replied = replied
            self.resultCode = resultCode
            self.recordHex = recordHex
            self.recordBytes = recordBytes
            self.driveSetHits = driveSetHits
            self.parseFailure = parseFailure
        }

        /// The result label, or the reason there isn't one. Never invents a category.
        public var resultLabel: String {
            if !replied { return "no reply" }
            if let parseFailure { return "undecodable (\(parseFailure.rawValue))" }
            switch resultCode {
            case 0:  return "FAILURE"
            case 1:  return "SUCCESS"
            case 2:  return "PENDING"
            case 3:  return "UNSUPPORTED"
            case nil: return "replied (no result byte on this family)"
            default: return "result\(resultCode!)"
            }
        }
    }

    /// The probe's conclusion. Every case names an **observation** — a count of result codes — and none
    /// names a mechanism. A verdict that says "gated", "blocked" or "entitlement" would be describing
    /// something no round-trip in this probe can see; that error has already been made once in this
    /// project and retracted.
    public enum Verdict: String, Equatable, Sendable {
        case notRun
        /// Every verb replied UNSUPPORTED to every body shape.
        case allRefused
        /// At least one verb replied SUCCESS.
        case someAnswered
        /// Every verb replied, none with SUCCESS or UNSUPPORTED.
        case allFailed
        /// No verb replied at all.
        case allSilent
        /// Replies arrived but do not fall into one clean bucket.
        case mixed
    }

    public let family: DeviceFamily
    public private(set) var readings: [Reading] = []
    /// Set when the safety cap stopped the plan early, so a short run is never presented as a finished one.
    public private(set) var stoppedReason: String?

    public init(family: DeviceFamily) { self.family = family }

    /// The full plan: every verb × every body shape, verbs in table order.
    public var plan: [Step] {
        var steps: [Step] = []
        for opcode in [AfeReadProbe.getLedDriveCmd, AfeReadProbe.getTiaGainCmd,
                       AfeReadProbe.getAfeParametersCmd] {
            for body in AfeReadProbe.bodyShapes { steps.append(Step(opcode: opcode, body: body)) }
        }
        return steps
    }

    /// The next round-trip to run, or nil when the plan is exhausted or the cap has bitten.
    public mutating func nextStep() -> Step? {
        guard stoppedReason == nil else { return nil }
        guard readings.count < AfeReadProbe.maxSteps else {
            stoppedReason = "safety cap reached (\(AfeReadProbe.maxSteps) round-trips)"
            return nil
        }
        let all = plan
        guard readings.count < all.count else { return nil }
        return all[readings.count]
    }

    /// Record a decoded reply for the step just run.
    public mutating func note(step: Step, response: AfeReadProbe.AfeResponse) {
        readings.append(Reading(
            opcode: step.opcode, body: step.body, replied: true,
            resultCode: response.resultCode, recordHex: response.recordHex,
            recordBytes: response.record.count,
            driveSetHits: AfeReadProbe.driveSetMatches(in: response.record).map(\.offset),
            parseFailure: nil))
    }

    /// Record a reply that arrived but could not be decoded, naming why.
    public mutating func note(step: Step, failure: AfeReadProbe.ParseFailure) {
        readings.append(Reading(
            opcode: step.opcode, body: step.body, replied: true, resultCode: nil,
            recordHex: "(undecodable)", recordBytes: 0, driveSetHits: [], parseFailure: failure))
    }

    /// Record that the strap never answered this step. Silence is recorded as silence.
    public mutating func noteSilence(step: Step) {
        readings.append(Reading(
            opcode: step.opcode, body: step.body, replied: false, resultCode: nil,
            recordHex: "(no reply)", recordBytes: 0, driveSetHits: [], parseFailure: nil))
    }

    /// Result codes seen for one opcode across every body shape asked.
    public func resultCodes(for opcode: UInt8) -> [Int?] {
        readings.filter { $0.opcode == opcode && $0.replied }.map(\.resultCode)
    }

    /// The verdict. Derived only from reply presence and result codes — never from record contents.
    public var verdict: Verdict {
        guard !readings.isEmpty else { return .notRun }
        let replied = readings.filter(\.replied)
        if replied.isEmpty { return .allSilent }
        if replied.contains(where: { $0.resultCode == 1 }) { return .someAnswered }
        if replied.count == readings.count, replied.allSatisfy({ $0.resultCode == 3 }) { return .allRefused }
        if replied.count == readings.count, replied.allSatisfy({ $0.resultCode == 0 }) { return .allFailed }
        return .mixed
    }

    /// One plain sentence for the verdict, stated as an observation with its own sample size.
    public var verdictLine: String {
        let n = readings.count
        switch verdict {
        case .notRun:
            return "not run"
        case .allSilent:
            return "no reply to any of \(n) round-trips — INCONCLUSIVE. Silence is not a refusal."
        case .allRefused:
            // Deliberately worded without the noun "block": in a verdict about an absent signal it reads
            // as a suppression mechanism, and this probe can only ever see result codes. The optical
            // record's 422-byte units are called channels here for that reason alone.
            return "all \(n) round-trips answered UNSUPPORTED(3) — this firmware does not serve the AFE "
                 + "read cluster. The 'drive a known emitter and watch which optical channel responds' "
                 + "experiment is not available over BLE on this strap."
        case .allFailed:
            return "all \(n) round-trips answered FAILURE(0) — the verbs replied, but none of the three "
                 + "body shapes satisfied them. This does NOT establish the opcodes are absent; the next "
                 + "step is a wider body-shape sweep, still read-only."
        case .someAnswered:
            let ok = readings.filter { $0.resultCode == 1 }.count
            return "\(ok) of \(n) round-trips answered SUCCESS(1) — there is a read channel into the "
                 + "optical front end. A paired SET can now be designed against an OBSERVED body rather "
                 + "than a guessed one."
        case .mixed:
            return "mixed replies across \(n) round-trips — read the per-step table; no single-bucket "
                 + "conclusion is supported."
        }
    }

    /// The copyable transcript.
    public func render() -> String {
        var sb = ""
        sb += "AFE READ-CLUSTER PROBE (read-only) — \(family == .whoop5 ? "WHOOP 5/MG" : "WHOOP 4.0")\n"
        sb += "Opcodes sent: 40 GET_LED_DRIVE, 42 GET_TIA_GAIN, 62 GET_AFE_PARAMETERS. "
        sb += "Never sent: 39, 41, 61, 107, 108.\n"
        sb += "\nVerdict: \(verdictLine)\n"
        if let stoppedReason { sb += "STOPPED: \(stoppedReason)\n" }

        sb += "\nPer round-trip:\n"
        sb += "  " + AfeReadProbe.padded("opcode", to: 22) + AfeReadProbe.padded("body", to: 10)
            + AfeReadProbe.padded("result", to: 14) + "record\n"
        for r in readings {
            sb += "  " + AfeReadProbe.padded("\(r.opcode) \(AfeReadProbe.label(for: r.opcode))", to: 22)
                + AfeReadProbe.padded(AfeReadProbe.bodyLabel(r.body), to: 10)
                + AfeReadProbe.padded(r.resultLabel, to: 14)
                + (r.recordBytes > 0 ? "\(r.recordBytes) B: \(r.recordHex)" : r.recordHex) + "\n"
        }

        let hits = readings.filter { !$0.driveSetHits.isEmpty }
        if !hits.isEmpty {
            sb += "\nStructural check — a u16 LE from the observed block-0 drive set "
            sb += "{1150,1400,1750,2200,2750,3350} appears in:\n"
            for r in hits {
                sb += "  \(AfeReadProbe.label(for: r.opcode)) body \(AfeReadProbe.bodyLabel(r.body)) "
                sb += "at record offsets \(r.driveSetHits.map(String.init).joined(separator: ", "))\n"
            }
            sb += "  This is evidence the verb reads the same register family the v20 optical record\n"
            sb += "  reports. It says NOTHING about wavelength — a numeric coincidence is not an\n"
            sb += "  identification, and inferring a physical property from a structural one is the\n"
            sb += "  exact error behind this project's retracted 'R5 = IR / R6 = red' claim.\n"
        }

        sb += "\nWhat this probe cannot do: identify an emitter's wavelength. Even a complete read of\n"
        sb += "every AFE register returns selector values and drive levels. Emitter identity still needs\n"
        sb += "a physical measurement.\n"
        return sb
    }
}
