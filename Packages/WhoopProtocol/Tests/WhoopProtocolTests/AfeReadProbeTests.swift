import XCTest
@testable import WhoopProtocol

/// #423: the read-only AFE control-cluster probe — its allowlist, request plan, parse and report.
///
/// Fixtures are SYNTHETIC and built with real CRCs by the two helpers below (the WHOOP 4.0 harvard
/// envelope and the 5/MG puffin envelope). **No strap has ever answered opcode 40, 42 or 62 in this
/// project's hands** — establishing whether one does is the entire point of the probe — so these tests
/// pin the decode, the plan, the verdict and the rendering, including every "the verb is not
/// implemented" path the BLE handler must survive.
final class AfeReadProbeTests: XCTestCase {

    // MARK: - Frame builders (mirror the two envelopes verifyFrame(_:family:) validates)

    /// WHOOP 4.0 COMMAND_RESPONSE: [0xAA][len u16 LE][crc8(len)][type=36][seq][cmd][payload…][crc32 LE].
    private func whoop4Response(cmd: UInt8, payload: [UInt8], seq: UInt8 = 1) -> [UInt8] {
        let inner: [UInt8] = [36, seq, cmd] + payload
        let length = UInt16(inner.count + 4)
        let lenBytes: [UInt8] = [UInt8(length & 0xFF), UInt8(length >> 8)]
        var frame: [UInt8] = [0xAA] + lenBytes + [crc8(lenBytes)] + inner
        let c = crc32(inner)
        frame += [UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF), UInt8((c >> 16) & 0xFF), UInt8((c >> 24) & 0xFF)]
        return frame
    }

    /// WHOOP 5/MG COMMAND_RESPONSE in the puffin envelope: type @8, seq @9, cmd @10, record from @11.
    private func whoop5Response(cmd: UInt8, payload: [UInt8], seq: UInt8 = 1) -> [UInt8] {
        var inner: [UInt8] = [36, seq, cmd] + payload
        let pad = (4 - inner.count % 4) % 4
        if pad > 0 { inner += [UInt8](repeating: 0, count: pad) }
        let declLen = inner.count + 4
        var frame: [UInt8] = [0xAA, 0x01, UInt8(declLen & 0xFF), UInt8((declLen >> 8) & 0xFF), 0x00, 0x01]
        let c16 = crc16Modbus(Array(frame[0..<6]))
        frame += [UInt8(c16 & 0xFF), UInt8((c16 >> 8) & 0xFF)]
        frame += inner
        let c32 = crc32(inner)
        frame += [UInt8(c32 & 0xFF), UInt8((c32 >> 8) & 0xFF), UInt8((c32 >> 16) & 0xFF), UInt8((c32 >> 24) & 0xFF)]
        return frame
    }

    /// The 2-byte response header every COMMAND_RESPONSE carries ahead of its record, then the record.
    private func payload(result: UInt8, record: [UInt8]) -> [UInt8] { [0x0A, result] + record }

    // MARK: - The read-only allowlist (the hard safety constraint)

    func testSendableOpcodesAreExactlyTheThreeGetVerbs() {
        XCTAssertEqual(AfeReadProbe.sendableOpcodes, [40, 42, 62])
    }

    /// The whole safety property, proven over the entire opcode space rather than by spot check: every
    /// one of the 256 opcodes is rejected except the three GET verbs.
    func testEveryOtherOpcodeIsRejected() {
        for raw in UInt8.min...UInt8.max {
            let allowed = AfeReadProbe.isReadOnlyOpcode(raw)
            if raw == 40 || raw == 42 || raw == 62 {
                XCTAssertTrue(allowed, "opcode \(raw) must be sendable")
            } else {
                XCTAssertFalse(allowed, "opcode \(raw) must NOT be sendable by the AFE read probe")
            }
        }
    }

    /// The AFE write verbs and the two optical stream toggles are rejected by name, so the exclusion is
    /// testable rather than incidental.
    func testAfeWriteVerbsAndOpticalTogglesAreExcludedByName() {
        XCTAssertEqual(AfeReadProbe.excludedWriteOpcodes, [39, 41, 61, 107, 108])
        for opcode in AfeReadProbe.excludedWriteOpcodes {
            XCTAssertFalse(AfeReadProbe.isReadOnlyOpcode(opcode),
                           "\(AfeReadProbe.label(for: opcode)) (\(opcode)) must never be sendable")
        }
        XCTAssertTrue(AfeReadProbe.sendableOpcodes.isDisjoint(with: AfeReadProbe.excludedWriteOpcodes))
    }

    /// `SEND_R10_R11_REALTIME` (63) is adjacent to `GET_AFE_PARAMETERS` (62) in the table. Adjacency is
    /// not membership: the probe must not send it.
    func testOpcode63IsNotSendable() {
        XCTAssertFalse(AfeReadProbe.isReadOnlyOpcode(63))
    }

    // MARK: - The plan

    func testPlanIsThreeVerbsTimesThreeBodyShapes() {
        let report = AfeReadProbeReport(family: .whoop5)
        let plan = report.plan
        XCTAssertEqual(plan.count, 9)
        XCTAssertEqual(Set(plan.map(\.opcode)), [40, 42, 62])
        // Verbs in table order, each asked with all three bodies before the next verb.
        XCTAssertEqual(plan.map(\.opcode), [40, 40, 40, 42, 42, 42, 62, 62, 62])
        XCTAssertEqual(plan.prefix(3).map(\.body), [[], [0x00], [0x01]])
        XCTAssertLessThanOrEqual(plan.count, AfeReadProbe.maxSteps)
    }

    func testPlanNeverEmitsAnExcludedOpcode() {
        let report = AfeReadProbeReport(family: .whoop5)
        for step in report.plan {
            XCTAssertTrue(AfeReadProbe.isReadOnlyOpcode(step.opcode))
            XCTAssertFalse(AfeReadProbe.excludedWriteOpcodes.contains(step.opcode))
        }
    }

    func testStepsAreHandedOutInOrderThenExhaust() {
        var report = AfeReadProbeReport(family: .whoop5)
        var seen: [UInt8] = []
        while let step = report.nextStep() {
            seen.append(step.opcode)
            report.noteSilence(step: step)
        }
        XCTAssertEqual(seen, [40, 40, 40, 42, 42, 42, 62, 62, 62])
        XCTAssertNil(report.nextStep())
    }

    // MARK: - Parse

    func testParsesA5MGSuccessReply() {
        let frame = whoop5Response(cmd: 40, payload: payload(result: 1, record: [0x7e, 0x04]))
        guard case .success(let r) = AfeReadProbe.parse(frame: frame, family: .whoop5, expecting: 40)
        else { return XCTFail("expected a decode") }
        XCTAssertEqual(r.resultCode, 1)
        XCTAssertTrue(r.isSuccess)
        // The 5/MG envelope pads the inner payload to a 4-byte boundary, so trailing NULs may be
        // envelope padding rather than data — the record is reported raw, never trimmed silently.
        XCTAssertEqual(Array(r.record.prefix(2)), [0x7e, 0x04])
    }

    func testUnsupportedIsTheDecisiveOutcomeAndIsDecoded() {
        let frame = whoop5Response(cmd: 62, payload: payload(result: 3, record: []))
        guard case .success(let r) = AfeReadProbe.parse(frame: frame, family: .whoop5, expecting: 62)
        else { return XCTFail("expected a decode") }
        XCTAssertTrue(r.isUnsupported)
        XCTAssertFalse(r.isSuccess)
    }

    func testFailureAndUnsupportedAreDistinguished() {
        let fail = whoop5Response(cmd: 42, payload: payload(result: 0, record: []))
        guard case .success(let f) = AfeReadProbe.parse(frame: fail, family: .whoop5, expecting: 42)
        else { return XCTFail("expected a decode") }
        XCTAssertTrue(f.isFailure)
        XCTAssertFalse(f.isUnsupported)
    }

    func testRejectsABadCRC() {
        var frame = whoop5Response(cmd: 40, payload: payload(result: 1, record: [0x01]))
        frame[frame.count - 1] ^= 0xFF          // corrupt the CRC32 trailer
        guard case .failure(let why) = AfeReadProbe.parse(frame: frame, family: .whoop5, expecting: 40)
        else { return XCTFail("a bad CRC must never decode") }
        XCTAssertEqual(why, .crc)
    }

    func testRejectsAReplyForADifferentCommand() {
        let frame = whoop5Response(cmd: 62, payload: payload(result: 1, record: [0x01]))
        guard case .failure(let why) = AfeReadProbe.parse(frame: frame, family: .whoop5, expecting: 40)
        else { return XCTFail("a reply for another command must not decode as ours") }
        XCTAssertEqual(why, .wrongCommand)
    }

    func testRejectsANonCommandResponseFrame() {
        // Type 47 HISTORICAL_DATA in a well-formed puffin envelope: valid CRCs, wrong packet type.
        var inner: [UInt8] = [47, 1, 40, 0x0A, 0x01]
        let pad = (4 - inner.count % 4) % 4
        if pad > 0 { inner += [UInt8](repeating: 0, count: pad) }
        let declLen = inner.count + 4
        var frame: [UInt8] = [0xAA, 0x01, UInt8(declLen & 0xFF), UInt8((declLen >> 8) & 0xFF), 0x00, 0x01]
        let c16 = crc16Modbus(Array(frame[0..<6]))
        frame += [UInt8(c16 & 0xFF), UInt8((c16 >> 8) & 0xFF)]
        frame += inner
        let c32 = crc32(inner)
        frame += [UInt8(c32 & 0xFF), UInt8((c32 >> 8) & 0xFF), UInt8((c32 >> 16) & 0xFF), UInt8((c32 >> 24) & 0xFF)]
        guard case .failure(let why) = AfeReadProbe.parse(frame: frame, family: .whoop5, expecting: 40)
        else { return XCTFail("a non-COMMAND_RESPONSE must not decode") }
        XCTAssertEqual(why, .envelope)
    }

    func testWhoop4RepliesCarryNoResultCode() {
        let frame = whoop4Response(cmd: 40, payload: payload(result: 1, record: [0x01, 0x02]))
        guard case .success(let r) = AfeReadProbe.parse(frame: frame, family: .whoop4, expecting: 40)
        else { return XCTFail("expected a decode") }
        // The result byte's meaning is pinned on 5/MG only; on WHOOP 4.0 it is deliberately not claimed.
        XCTAssertNil(r.resultCode)
        XCTAssertFalse(r.isSuccess)
        XCTAssertFalse(r.isUnsupported)
    }

    // MARK: - The structural drive-set check

    func testDriveSetMatchFindsAnObservedBlock0Value() {
        // 3350 = 0x0D16 -> little-endian 0x16 0x0D, at offset 1.
        let hits = AfeReadProbe.driveSetMatches(in: [0xFF, 0x16, 0x0D, 0xFF])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].offset, 1)
        XCTAssertEqual(hits[0].value, 3350)
    }

    func testDriveSetMatchIsSilentOnUnrelatedBytes() {
        XCTAssertTrue(AfeReadProbe.driveSetMatches(in: [0x00, 0x01, 0x02, 0x03]).isEmpty)
        XCTAssertTrue(AfeReadProbe.driveSetMatches(in: []).isEmpty)
        XCTAssertTrue(AfeReadProbe.driveSetMatches(in: [0x16]).isEmpty)
    }

    func testDriveSetIsTheSixValuesObservedInTheCorpus() {
        XCTAssertEqual(AfeReadProbe.observedBlock0DriveValues, [1150, 1400, 1750, 2200, 2750, 3350])
    }

    // MARK: - Verdicts (each named outcome, declared in advance, is reachable)

    private func runAll(_ report: inout AfeReadProbeReport,
                        reply: (AfeReadProbeReport.Step) -> UInt8?) {
        while let step = report.nextStep() {
            if let result = reply(step) {
                let frame = whoop5Response(cmd: step.opcode, payload: payload(result: result, record: []))
                guard case .success(let r) = AfeReadProbe.parse(frame: frame, family: .whoop5,
                                                               expecting: step.opcode)
                else { return XCTFail("fixture must decode") }
                report.note(step: step, response: r)
            } else {
                report.noteSilence(step: step)
            }
        }
    }

    func testVerdictNotRunBeforeAnyStep() {
        XCTAssertEqual(AfeReadProbeReport(family: .whoop5).verdict, .notRun)
    }

    func testVerdictAllRefusedWhenEveryVerbAnswersUnsupported() {
        var report = AfeReadProbeReport(family: .whoop5)
        runAll(&report) { _ in 3 }
        XCTAssertEqual(report.verdict, .allRefused)
        XCTAssertTrue(report.verdictLine.contains("does not serve the AFE read cluster"))
    }

    func testVerdictSomeAnsweredWhenOneVerbSucceeds() {
        var report = AfeReadProbeReport(family: .whoop5)
        runAll(&report) { $0.opcode == 40 && $0.body == [0x01] ? 1 : 3 }
        XCTAssertEqual(report.verdict, .someAnswered)
        XCTAssertTrue(report.verdictLine.contains("read channel into the optical front end"))
    }

    func testVerdictAllFailedDoesNotClaimTheOpcodesAreAbsent() {
        var report = AfeReadProbeReport(family: .whoop5)
        runAll(&report) { _ in 0 }
        XCTAssertEqual(report.verdict, .allFailed)
        // The §0.2 discipline: FAILURE is not "no such opcode".
        XCTAssertTrue(report.verdictLine.contains("does NOT establish the opcodes are absent"))
    }

    func testVerdictAllSilentIsReportedAsInconclusive() {
        var report = AfeReadProbeReport(family: .whoop5)
        runAll(&report) { _ in nil }
        XCTAssertEqual(report.verdict, .allSilent)
        XCTAssertTrue(report.verdictLine.contains("INCONCLUSIVE"))
        XCTAssertTrue(report.verdictLine.contains("Silence is not a refusal"))
    }

    func testVerdictMixedWhenRepliesDoNotFallInOneBucket() {
        var report = AfeReadProbeReport(family: .whoop5)
        runAll(&report) { $0.opcode == 40 ? 3 : ($0.opcode == 42 ? 0 : nil) }
        XCTAssertEqual(report.verdict, .mixed)
    }

    /// §9.8's lesson, enforced by test: a verdict may name an OBSERVATION, never a MECHANISM the probe
    /// cannot see. The probe reads result codes and packet presence and nothing else.
    func testNoVerdictLineNamesAMechanismTheProbeCannotObserve() {
        let banned = ["gate", "gated", "blocked", "block", "entitlement", "subscription", "deviceflag",
                      "device-flag", "device flag"]
        for result: UInt8? in [0, 1, 2, 3, nil] {
            var report = AfeReadProbeReport(family: .whoop5)
            runAll(&report) { _ in result }
            let line = report.verdictLine.lowercased()
            for word in banned {
                XCTAssertFalse(line.contains(word),
                               "verdict for result \(String(describing: result)) names '\(word)', "
                             + "which no round-trip in this probe can observe")
            }
        }
    }

    // MARK: - Safety cap and rendering

    func testSafetyCapCannotBeExceededAndSaysSoWhenItBites() {
        var report = AfeReadProbeReport(family: .whoop5)
        var steps = 0
        while let step = report.nextStep() {
            report.noteSilence(step: step)
            steps += 1
            XCTAssertLessThanOrEqual(steps, AfeReadProbe.maxSteps)
        }
        // The 9-step plan finishes inside the 12-step cap, so the cap must NOT report as having bitten.
        XCTAssertEqual(steps, 9)
        XCTAssertNil(report.stoppedReason)
    }

    func testRenderNamesWhatItSendsAndWhatItNeverSends() {
        var report = AfeReadProbeReport(family: .whoop5)
        runAll(&report) { _ in 3 }
        let text = report.render()
        XCTAssertTrue(text.contains("40 GET_LED_DRIVE"))
        XCTAssertTrue(text.contains("42 GET_TIA_GAIN"))
        XCTAssertTrue(text.contains("62 GET_AFE_PARAMETERS"))
        XCTAssertTrue(text.contains("Never sent: 39, 41, 61, 107, 108."))
        // Nine table rows, each labelled UNSUPPORTED. Counted off the readings rather than off the
        // rendered text, because the verdict line names the code too and would inflate a text count.
        XCTAssertEqual(report.readings.filter { $0.resultLabel == "UNSUPPORTED" }.count, 9)
    }

    /// The report must always carry the limit of what a GET can establish, whatever the outcome — this
    /// is the sentence that stops a future reader turning a selector value into a wavelength.
    func testRenderAlwaysCarriesTheWavelengthCaveat() {
        for result: UInt8? in [0, 1, 3, nil] {
            var report = AfeReadProbeReport(family: .whoop5)
            runAll(&report) { _ in result }
            XCTAssertTrue(report.render().contains("cannot do: identify an emitter's wavelength"))
        }
    }

    func testDriveSetHitIsRenderedWithItsCaveatAttached() {
        var report = AfeReadProbeReport(family: .whoop5)
        guard let step = report.nextStep() else { return XCTFail("expected a step") }
        let frame = whoop5Response(cmd: step.opcode,
                                   payload: payload(result: 1, record: [0x16, 0x0D, 0x00, 0x00]))
        guard case .success(let r) = AfeReadProbe.parse(frame: frame, family: .whoop5,
                                                       expecting: step.opcode)
        else { return XCTFail("fixture must decode") }
        report.note(step: step, response: r)
        XCTAssertEqual(report.readings[0].driveSetHits, [0])
        let text = report.render()
        XCTAssertTrue(text.contains("says NOTHING about wavelength"))
        XCTAssertTrue(text.contains("R5 = IR / R6 = red"))
    }
}
