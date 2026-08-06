import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Unit tests for the WHOOP 5.0/MG skin-temperature pipeline in AnalyticsEngine
/// (macOS parity with the Android SkinTempAnalyticsTest).
///
/// Two parts:
///  1. `AnalyticsEngine.wornNightlySkinTempC` — the wear-gated nightly-mean logic (the part
///     that turns raw skin_temp_raw@73 samples into a trustworthy per-night value).
///  2. The seed→deviation flow over `Baselines.foldHistory`/`Baselines.deviation` with the
///     standard `skin_temp` config — pinning the honest cold-start gate (<4 nights ⇒ no
///     skinTempDevC) and that a real elevation surfaces as a positive deviation once seeded.
///
/// SCALE NOTE: the firmware stores CENTIDEGREES in skin_temp_raw@73 — °C = raw/100, matching
/// the Android decoder/tests. (The earlier /128 "AS6221-native" assumption was disproven by the
/// real captures in Whoop5HistoricalTests: worn raw 3057 / off-wrist 2247 are 30.6 °C skin and
/// 22.5 °C room ambient under /100, but an impossible 23.9 °C "skin" under /128 — below the worn
/// gate, silently dropping every real night. PR #97 review / #166.) Worn nightly values on real
/// hardware are ~30–35 °C, off-wrist/charging ~22–27 °C — exactly the contamination the
/// wear-gate excludes. All values APPROXIMATE.
final class SkinTempAnalyticsTests: XCTestCase {

    private func session(start: Int, durSec: Int) -> SleepSession {
        SleepSession(start: start, end: start + durSec, efficiency: 0.9,
                     stages: [], restingHR: 50, avgHRV: 60.0)
    }

    private func hr(_ ts: Int, bpm: Int = 55) -> HRSample { HRSample(ts: ts, bpm: bpm) }
    /// raw = °C × 100 (centidegrees, firmware scale): 34 °C → 3400, 36 °C → 3600, 22 °C → 2200.
    private func skin(_ ts: Int, rawX100: Int) -> SkinTempSample { SkinTempSample(ts: ts, raw: rawX100) }

    // MARK: - wornNightlySkinTempC

    func testMeanOverWornInBedSamples() throws {
        let start = 1_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { skin(start + $0, rawX100: 3400) }  // 34.00 °C
        let mean = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps))
        XCTAssertEqual(mean, 34.0, accuracy: 1e-9)
    }

    func testExcludesSamplesWithoutConcurrentWornHr() {
        // The strap streams HR only on-wrist; skin-temp samples with no concurrent worn BPM drop.
        let start = 2_000_000
        let sess = [session(start: start, durSec: 600)]
        let temps = (0..<600).map { skin(start + $0, rawX100: 3400) }
        XCTAssertNil(AnalyticsEngine.wornNightlySkinTempC(sess, hr: [], skinTemp: temps))
    }

    func testExcludesDaytimeSamplesOutsideTheSleepSession() throws {
        // Daytime samples are in worn range (36 °C) AND have worn HR, but fall OUTSIDE the in-bed
        // session window, so only the in-bed 34 °C samples count. Isolates the session-window gate.
        let night = 3_000_000
        let sess = [session(start: night, durSec: 600)]
        let inBedHr = (0..<600).map { hr(night + $0) }
        let inBedTemp = (0..<600).map { skin(night + $0, rawX100: 3400) }
        let day = night + 10_000
        let dayHr = (0..<600).map { hr(day + $0) }
        let dayTemp = (0..<600).map { skin(day + $0, rawX100: 3600) }  // 36 °C, worn-range, daytime
        let mean = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(
            sess, hr: inBedHr + dayHr, skinTemp: inBedTemp + dayTemp))
        XCTAssertEqual(mean, 34.0, accuracy: 1e-9)
    }

    func testExcludesOnChargerAmbientEvenInBed() {
        // Mid-night on charger: HR still has stray worn-range values but skin temp drifts to
        // ambient (~22 °C) — which passes the strap's looser decode gate but is below the worn
        // floor of 28 °C.
        let start = 4_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { skin(start + $0, rawX100: 2200) }  // 22 °C ambient
        XCTAssertNil(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps))
    }

    func testBelowMinSamplesIsNil() {
        let start = 5_000_000
        let sess = [session(start: start, durSec: 100)]
        let hrs = (0..<100).map { hr(start + $0) }
        let temps = (0..<100).map { skin(start + $0, rawX100: 3400) }  // 100 < minSkinTempSamples
        XCTAssertNil(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps))
    }

    func testEmptyInputsAreNil() {
        XCTAssertNil(AnalyticsEngine.wornNightlySkinTempC([], hr: [], skinTemp: []))
    }

    // MARK: - skin-temp funnel diagnostic (#752)

    /// The kept-path: the funnel's mean is byte-identical to `wornNightlySkinTempC`, and the drop buckets +
    /// kept sum to the total (every sample is accounted for exactly once).
    func testFunnelKeptPathMatchesMeanAndAccountsForEverySample() throws {
        let start = 6_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { skin(start + $0, rawX100: 3400) }  // 34 °C, all worn + in-window
        let f = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps)
        XCTAssertEqual(f.totalSamples, 600)
        XCTAssertEqual(f.kept, 600)
        XCTAssertEqual(f.droppedNotWorn + f.droppedOutOfWindow + f.droppedOutOfRange + f.kept, f.totalSamples)
        XCTAssertEqual(try XCTUnwrap(f.mean), 34.0, accuracy: 1e-9)
        XCTAssertFalse(f.isAbsent)
        // The mean exactly matches the public wrapper (they share gate logic, so can't diverge).
        XCTAssertEqual(f.mean, AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps))
    }

    /// 4.0-style "skin temp absent" triage: samples exist but NONE are worn (no concurrent live HR), so the
    /// funnel attributes the whole loss to `droppedNotWorn` and the mean is absent.
    func testFunnelAllNotWornExplainsAbsence() {
        let start = 7_000_000
        let sess = [session(start: start, durSec: 600)]
        let temps = (0..<600).map { skin(start + $0, rawX100: 3400) }
        let f = AnalyticsEngine.skinTempFunnel(sess, hr: [], skinTemp: temps)
        XCTAssertEqual(f.totalSamples, 600)
        XCTAssertEqual(f.droppedNotWorn, 600)
        XCTAssertEqual(f.kept, 0)
        XCTAssertTrue(f.isAbsent)
        XCTAssertTrue(f.summary.contains("notWorn=600"), "the summary names the dominant gate: \(f.summary)")
    }

    /// Worn + in-window samples that drift to ambient (~22 °C, on-charger) all fail the worn-range gate, so
    /// the loss is attributed to `droppedOutOfRange` - the user can see it was off-wrist drift, not a bug.
    func testFunnelOutOfRangeIsAttributedToRangeGate() {
        let start = 8_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { skin(start + $0, rawX100: 2200) }  // 22 °C ambient
        let f = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps)
        XCTAssertEqual(f.droppedOutOfRange, 600)
        XCTAssertEqual(f.droppedNotWorn, 0)
        XCTAssertEqual(f.kept, 0)
        XCTAssertTrue(f.isAbsent)
    }

    /// Worn samples outside every detected in-bed span are attributed to `droppedOutOfWindow`. With NO
    /// session at all, every sample is out of window (matching the old early-return-nil behaviour).
    func testFunnelOutOfWindowAndNoSession() {
        let start = 9_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + 100_000 + $0) }            // worn, but far from the session
        let temps = (0..<600).map { skin(start + 100_000 + $0, rawX100: 3400) }
        let f = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps)
        XCTAssertEqual(f.droppedOutOfWindow, 600)
        XCTAssertEqual(f.kept, 0)
        XCTAssertTrue(f.isAbsent)
        // No session → every sample is out of window, and the mean is absent (legacy early-return parity).
        let none = AnalyticsEngine.skinTempFunnel([], hr: hrs, skinTemp: temps)
        XCTAssertEqual(none.droppedOutOfWindow, 600)
        XCTAssertTrue(none.isAbsent)
    }

    /// Below the min-samples floor: every sample is kept but the mean is still absent (the last gate), and
    /// `kept` reports the survivor count so the user sees "only N < min" rather than a silent nil.
    func testFunnelBelowMinSamplesKeepsButMeanAbsent() {
        let start = 10_000_000
        let sess = [session(start: start, durSec: 100)]
        let hrs = (0..<100).map { hr(start + $0) }
        let temps = (0..<100).map { skin(start + $0, rawX100: 3400) }  // 100 < minSkinTempSamples
        let f = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps)
        XCTAssertEqual(f.kept, 100)
        XCTAssertGreaterThan(f.minSamples, 100)
        XCTAssertTrue(f.isAbsent, "kept < minSamples → no trusted mean")
    }

    // MARK: - device-family-aware conversion (#938)

    /// A WHOOP 4.0 v24 worn night (raw ~826–860, the reporter's steady worn baseline) produced NO nightly
    /// mean under the old family-blind /100 (raw 826 → 8.3 °C, below the 28 °C worn gate, kept=0). With the
    /// `.whoop4` scale those same raw values land ~33 °C and the night is kept — the fix.
    func testWhoop4WornNightProducesMeanUnderFamilyAwareScale() throws {
        let start = 11_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        // Steady worn 4.0 raw ~840 — impossible 8.4 °C under /100, plausible ~33.7 °C under the 4.0 map.
        let temps = (0..<600).map { SkinTempSample(ts: start + $0, raw: 840) }
        // Old behaviour (family-blind /100 == `.whoop5`): dropped, no mean.
        XCTAssertNil(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps, family: .whoop5))
        // Fixed behaviour (`.whoop4`): a trusted nightly mean in the plausible worn band.
        let mean = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps, family: .whoop4))
        XCTAssertGreaterThan(mean, 28.0)
        XCTAssertLessThan(mean, 42.0)
    }

    /// A 5/MG worn night is byte-identical whether `family` is defaulted or passed explicitly — the fix
    /// changes nothing for the proven centidegree path.
    func testWhoop5NightUnchangedByFamilyParameter() throws {
        let start = 12_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { skin(start + $0, rawX100: 3400) }  // 34 °C centidegrees
        let defaulted = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps))
        let explicit = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps, family: .whoop5))
        XCTAssertEqual(defaulted, 34.0, accuracy: 1e-9)
        XCTAssertEqual(defaulted, explicit)
    }

    /// The funnel diagnostic reports the SAME family-aware outcome: a worn 4.0 night is kept under `.whoop4`
    /// but all-out-of-range (dropped) under the family-blind `.whoop5` scale.
    func testFunnelFamilyAwareAttribution() {
        let start = 13_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { SkinTempSample(ts: start + $0, raw: 840) }
        let w5 = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps, family: .whoop5)
        XCTAssertEqual(w5.droppedOutOfRange, 600, "under /100 the 4.0 worn raw reads ~8 °C, all out of range")
        XCTAssertTrue(w5.isAbsent)
        let w4 = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps, family: .whoop4)
        XCTAssertEqual(w4.kept, 600)
        XCTAssertFalse(w4.isAbsent)
    }

    // MARK: - per-device worn anchor, end-to-end (#938 second capture)

    /// A second real 4.0 strap: worn raws ~1250–1330 (nightly mean raw ~1290). Under the GLOBAL 826 anchor
    /// those map to ~54–58 °C, all failing the 28–42 °C worn gate (kept=0, no mean). With the device's OWN
    /// learned anchor the worn band lands ~33 °C and the night is kept.
    func testHighRegisterDeviceKeptWithLearnedAnchor() throws {
        let start = 20_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        // 600 worn samples sweeping raw 1250..1329 (nightly mean ~1290), a whole session inside worn seconds.
        let temps = (0..<600).map { SkinTempSample(ts: start + $0, raw: 1250 + ($0 % 80)) }
        let anchor = try XCTUnwrap(Whoop4SkinTemp.deviceAnchorRaw(temps.map { $0.raw }))
        // GLOBAL anchor (nil → 826): every worn raw maps to ~54–58 °C, all out of range → absent.
        XCTAssertNil(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps, family: .whoop4, anchorRaw: nil))
        // LEARNED anchor: kept, and the mean sits in the plausible worn band ≈ 33 °C.
        let mean = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps, family: .whoop4, anchorRaw: anchor))
        XCTAssertGreaterThan(mean, 28.0)
        XCTAssertLessThan(mean, 42.0)
        XCTAssertEqual(mean, 33.0, accuracy: 1.5)
    }

    /// Two nights whose raw means differ by +20, converted with the SAME window-wide anchor → nightly °C
    /// means differ by exactly +1.0 (20 × 0.05 slope). This is WHY the anchor is window-wide, not per-night:
    /// the shared constant offset cancels, leaving the true cross-night deviation intact.
    func testDeviationPreservedAcrossNightsWithSameAnchor() throws {
        let anchor = 1290.0
        func nightMean(_ startTs: Int, raw: Int) throws -> Double {
            let sess = [session(start: startTs, durSec: 600)]
            let hrs = (0..<600).map { hr(startTs + $0) }
            let temps = (0..<600).map { SkinTempSample(ts: startTs + $0, raw: raw) }
            return try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps, family: .whoop4, anchorRaw: anchor))
        }
        let n1 = try nightMean(21_000_000, raw: 1290)
        let n2 = try nightMean(22_000_000, raw: 1310) // +20 raw
        XCTAssertEqual(n2 - n1, 1.0, accuracy: 1e-9)
    }

    /// Byte-compat: WHOOP4 with anchorRaw=nil and reporter-band raws (~826) produces the IDENTICAL mean as
    /// the explicit global anchor (`Whoop4SkinTemp.anchorRaw`=826) — the pre-per-device behaviour.
    func testWhoop4NilAnchorByteIdenticalToGlobal() throws {
        let start = 23_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { SkinTempSample(ts: start + $0, raw: 826) }
        let nilAnchor = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps, family: .whoop4, anchorRaw: nil))
        let explicitGlobal = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps, family: .whoop4, anchorRaw: Whoop4SkinTemp.anchorRaw))
        XCTAssertEqual(nilAnchor, 33.0, accuracy: 1e-9) // raw 826 → exactly the 33.0 °C anchor
        XCTAssertEqual(nilAnchor, explicitGlobal, accuracy: 1e-12)
    }

    /// WHOOP5 is unchanged by the anchor parameter: a centidegree night is byte-identical with or without one.
    func testWhoop5IgnoresAnchor() throws {
        let start = 24_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { skin(start + $0, rawX100: 3400) } // 34 °C centidegrees
        let noAnchor = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps, family: .whoop5, anchorRaw: nil))
        let withAnchor = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps, family: .whoop5, anchorRaw: 1290.0))
        XCTAssertEqual(noAnchor, 34.0, accuracy: 1e-9)
        XCTAssertEqual(noAnchor, withAnchor, accuracy: 1e-12)
    }

    /// Doff-floor (509) and pegged-saturation (2047) samples on a WHOOP4 night count as `droppedOutOfRange`
    /// (dropped BEFORE the anchor map) and the four buckets + kept still sum to totalSamples.
    func testWhoop4FloorAndSaturationCountAsOutOfRange() throws {
        let start = 25_000_000
        let sess = [session(start: start, durSec: 900)]
        let hrs = (0..<900).map { hr(start + $0) }
        let worn = (0..<600).map { SkinTempSample(ts: start + $0, raw: 1290) }      // in-band worn
        let floor = (600..<750).map { SkinTempSample(ts: start + $0, raw: 509) }    // no-contact floor
        let pegged = (750..<900).map { SkinTempSample(ts: start + $0, raw: 2047) }  // 11-bit saturation
        let temps = worn + floor + pegged
        let anchor = try XCTUnwrap(Whoop4SkinTemp.deviceAnchorRaw(temps.map { $0.raw })) // learned from the 600 in-band raws
        let f = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps, family: .whoop4, anchorRaw: anchor)
        XCTAssertEqual(f.totalSamples, 900)
        XCTAssertEqual(f.droppedOutOfRange, 300) // 150 floor + 150 saturation, out of the plausible worn ADC band
        XCTAssertEqual(f.kept, 600)
        XCTAssertEqual(f.droppedNotWorn + f.droppedOutOfWindow + f.droppedOutOfRange + f.kept, f.totalSamples)
    }

    // MARK: - seed → deviation (skin_temp baseline)

    private let skinCfg = Baselines.metricCfg["skin_temp"]!

    func testColdStartBelowSeedBaselineNotUsable() {
        // 3 nightly means (< minNightsSeed = 4): still CALIBRATING → skinTempDevC stays nil.
        let nights: [Double?] = [33.5, 33.6, 33.4]
        XCTAssertFalse(Baselines.foldHistory(nights, cfg: skinCfg).usable)
    }

    func testAtSeedUsableElevationShowsPositiveDeviation() {
        // 4 baseline nights ~33.5 °C; a +0.8 °C night surfaces as a clearly positive deviation —
        // the signal the illness watch reads as its skin-temp flag (fires at ≥ +0.6 °C).
        let nights: [Double?] = [33.5, 33.4, 33.6, 33.5]
        let base = Baselines.foldHistory(nights, cfg: skinCfg)
        XCTAssertTrue(base.usable, "4 valid nights must seed a usable skin-temp baseline")
        let dev = Baselines.deviation(34.3, state: base).delta
        XCTAssertGreaterThan(dev, 0.5, "a +0.8 °C night must read as a clear positive deviation")
    }

    /// #skin-diag: WHOOP 4.0 raw-band + resolved-anchor visibility. A worn night whose raws sit at 1290
    /// (in the 550–2040 worn band) maps to ~56 °C under the GLOBAL 826 anchor → every worn sample fails the
    /// 28–42 °C gate (absent), but to 33 °C under the per-device anchor → kept. The new fields surface the
    /// raw band + which anchor resolved. Twin of Kotlin funnelSurfacesRawBandAndResolvedAnchorWhoop4.
    func testFunnelSurfacesRawBandAndResolvedAnchorWhoop4() {
        let start = 10_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { skin(start + $0, rawX100: 1290) }

        // Global 826 fallback (no anchor passed): p50 1290 → ~56 °C → all out of range, mean absent.
        let g = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps, family: .whoop4)
        XCTAssertEqual(g.rawMin, 1290)
        XCTAssertEqual(g.rawMedian, 1290)
        XCTAssertEqual(g.rawMax, 1290)
        XCTAssertEqual(g.inBandCount, 600)
        XCTAssertEqual(g.resolvedAnchorRaw, Whoop4SkinTemp.anchorRaw)
        XCTAssertGreaterThan(g.medianMappedC ?? 0, 42.0)
        XCTAssertEqual(g.droppedOutOfRange, 600)
        XCTAssertTrue(g.isAbsent)
        XCTAssertTrue(g.summary.contains("skin-temp-raw: raw[min=1290 p50=1290 max=1290]"), g.summary)

        // Per-device anchor 1290: p50 → 33 °C → in range → kept, mean present.
        let d = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps, family: .whoop4, anchorRaw: 1290)
        XCTAssertEqual(d.resolvedAnchorRaw, 1290)
        XCTAssertEqual(d.medianMappedC ?? 0, 33.0, accuracy: 0.01)
        XCTAssertEqual(d.kept, 600)
        XCTAssertFalse(d.isAbsent)
    }

    /// #skin-diag: the new observation fields never perturb the gate/mean — a kept-path night's mean stays
    /// byte-identical to `wornNightlySkinTempC`, and 5/MG carries no anchor.
    func testFunnelRawBandFieldsDoNotChangeMean() {
        let start = 11_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { skin(start + $0, rawX100: 3400) }
        let f = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps)  // whoop5 default
        XCTAssertEqual(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps), f.mean)
        XCTAssertNil(f.resolvedAnchorRaw, "5/MG centidegree path has no anchor")
        XCTAssertEqual(f.rawMedian, 3400)
    }

    // MARK: - on-wrist charging contamination

    private func event(_ ts: Int, _ kind: String) -> WhoopEvent {
        WhoopEvent(ts: ts, kind: kind, payload: [:])
    }

    /// The WHOOP 5/MG battery pack slides onto the strap while it stays ON THE WRIST, so a charge does NOT
    /// drift to cold ambient — it HEATS the sensor. Reproduces the real shape of VK's 2026-07-29→30 night
    /// (device evidence): worn HR throughout, one in-bed span, ~39 °C while the pack is attached and
    /// ~33.5 °C after it comes off. Every pre-existing gate ADMITS the hot samples (worn HR streams, the
    /// timestamps are in-bed, and 39 °C sits inside the 28–42 °C window), so without a charge gate the
    /// nightly mean is dragged up by the artifact.
    func testChargeIntervalDroppedSoNightlyMeanReflectsUnchargedPortionOnly() throws {
        let start = 13_000_000
        let chargeStart = start + 600            // pack on 10 min in…
        let chargeEnd = start + 3_600            // …and off 50 min later
        let sess = [session(start: start, durSec: 4_800)]
        let hrs = (0..<4_800).map { hr(start + $0) }    // worn the WHOLE time, charging included
        let temps = (0..<4_800).map { t -> SkinTempSample in
            let ts = start + t
            let onCharger = ts >= chargeStart && ts < chargeEnd
            return skin(ts, rawX100: onCharger ? 3_900 : 3_350)   // 39.0 °C vs 33.5 °C
        }
        let charge = [(start: chargeStart, end: chargeEnd)]

        // Baseline: without the charge gate the artifact is admitted and inflates the mean.
        let contaminated = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps))
        XCTAssertGreaterThan(contaminated, 34.0, "the 39 °C on-charger span must be what poisons the mean")

        // Fixed: the charge window drops out and the mean is exactly the uncharged portion's 33.5 °C.
        let mean = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(
            sess, hr: hrs, skinTemp: temps, chargeIntervals: charge))
        XCTAssertEqual(mean, 33.5, accuracy: 1e-9)

        // …and the funnel attributes the loss to the charge bucket, with every sample still accounted for.
        let f = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps, chargeIntervals: charge)
        XCTAssertEqual(f.droppedCharging, 3_000, "the whole [chargeStart, chargeEnd) span drops")
        XCTAssertEqual(f.kept, 1_800)
        XCTAssertEqual(f.droppedNotWorn, 0, "HR streams throughout — this is NOT an off-wrist night")
        XCTAssertEqual(f.droppedOutOfRange, 0, "39 °C is inside 28–42 °C — the range gate cannot catch this")
        let accounted: Int = f.droppedNotWorn + f.droppedOutOfWindow + f.droppedCharging
            + f.droppedOutOfRange + f.kept
        XCTAssertEqual(accounted, f.totalSamples)
        XCTAssertTrue(f.summary.contains("charging=3000"), "the summary names the charge gate: \(f.summary)")
    }

    /// No charge intervals ⇒ byte-identical to the pre-change behaviour (the default-empty contract every
    /// existing caller and test relies on).
    func testEmptyChargeIntervalsAreByteIdenticalToPriorBehaviour() throws {
        let start = 14_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { skin(start + $0, rawX100: 3_400) }
        let defaulted = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps))
        let explicitEmpty = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(
            sess, hr: hrs, skinTemp: temps, chargeIntervals: []))
        XCTAssertEqual(defaulted, explicitEmpty)
        XCTAssertEqual(AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps).droppedCharging, 0)
    }

    /// THE TRAP this fix has to survive, straight from the real night: CHARGING_ON/CHARGING_OFF toggled 15
    /// times inside ONE continuous BATTERY_PACK_CONNECTED→REMOVED span, and the sensor stayed hot through
    /// every CHARGING_OFF gap — the pack is still physically attached and thermally coupled, the charge
    /// current merely paused. Pairing CHARGING_ON/OFF alone would re-admit those gaps; the pack span must
    /// cover the whole window.
    func testPackSpanCoversChargingOffGaps() {
        let t = 1_785_386_564
        let events = [
            event(t, "BATTERY_PACK_CONNECTED(21)"),
            event(t, "CHARGING_ON(7)"),
            event(t + 898, "CHARGING_OFF(8)"),        // current pauses…
            event(t + 1_520, "CHARGING_ON(7)"),       // …and resumes 10 min later, pack never removed
            event(t + 1_895, "CHARGING_OFF(8)"),
            event(t + 15_342, "BATTERY_PACK_REMOVED(22)"),
        ]
        let intervals = AnalyticsEngine.chargeIntervals(events: events, windowStart: t - 1, windowEnd: t + 20_000)
        XCTAssertEqual(intervals.count, 1, "the toggles merge into the single pack span: \(intervals)")
        XCTAssertEqual(intervals[0].start, t)
        XCTAssertEqual(intervals[0].end, t + 15_342)
    }

    /// CHARGING_ON without a pack event still opens an interval (a 4.0 puck emits no pack events), and a
    /// span still open at the end of the read window closes at `windowEnd` — mirroring `offWristIntervals`.
    func testChargingOnlyEventsAndUnclosedSpan() {
        let t = 2_000_000
        let closed = AnalyticsEngine.chargeIntervals(
            events: [event(t, "CHARGING_ON(7)"), event(t + 300, "CHARGING_OFF(8)")], windowStart: t - 1, windowEnd: t + 9_999)
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed[0].end, t + 300)
        // Still on the charger when the window ends → closes at windowEnd, never left open.
        let open = AnalyticsEngine.chargeIntervals(
            events: [event(t, "BATTERY_PACK_CONNECTED(21)")], windowStart: t - 1, windowEnd: t + 5_000)
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open[0].end, t + 5_000)
        // Unrelated events contribute nothing.
        XCTAssertTrue(AnalyticsEngine.chargeIntervals(
            events: [event(t, "WRIST_OFF(10)"), event(t + 10, "BOOT(1)")], windowStart: t - 1, windowEnd: t + 100).isEmpty)
    }

    /// THE LEADING EDGE, from the real 2026-07-30 night. `BATTERY_PACK_CONNECTED` fired at 04:42:44 UTC, ten
    /// minutes BEFORE the 04:52:58 session start, and `BATTERY_PACK_REMOVED` at 08:58:26 during the session.
    /// A session-bounded event read therefore sees ONLY the closer. Before this heal the whole interval was
    /// dropped: charge coverage read 18 % instead of 55 %, and the funnel reported 35.46 °C for a night whose
    /// real gated mean is 33.39 °C — a 2.07 °C miss in the one function whose contract is to explain that
    /// exact mean. A closer with no opener now opens at `windowStart`.
    func testCloserWithoutOpenerOpensAtWindowStart() {
        let sessionStart = 1_785_387_178                    // 2026-07-30T04:52:58Z
        let packRemoved = sessionStart + 14_728             // 08:58:26Z, 4h05m into the session
        let sessionEnd = sessionStart + 26_710              // 12:18:08Z
        let intervals = AnalyticsEngine.chargeIntervals(
            events: [event(packRemoved, "BATTERY_PACK_REMOVED(22)")],
            windowStart: sessionStart, windowEnd: sessionEnd)
        XCTAssertEqual(intervals.count, 1, "the orphan closer must still produce an interval: \(intervals)")
        XCTAssertEqual(intervals[0].start, sessionStart, "opens at the window edge, not at the closer")
        XCTAssertEqual(intervals[0].end, packRemoved)
        // 55 % of the night, matching the real coverage — not the 18 % a dropped interval left behind.
        let covered = Double(intervals[0].end - intervals[0].start) / Double(sessionEnd - sessionStart)
        XCTAssertEqual(covered, 0.55, accuracy: 0.01)
    }

    /// The heal must not fire twice. A repeated closer AFTER a properly matched pair is a no-op — re-opening
    /// it back at `windowStart` would swallow the clean pre-charge stretch that the matched pair deliberately
    /// left in.
    func testRepeatedCloserAfterMatchedPairDoesNotReopenAtWindowStart() {
        let t = 5_000_000
        let intervals = AnalyticsEngine.chargeIntervals(
            events: [event(t + 1_000, "BATTERY_PACK_CONNECTED(21)"),
                     event(t + 2_000, "BATTERY_PACK_REMOVED(22)"),
                     event(t + 3_000, "BATTERY_PACK_REMOVED(22)")],   // duplicate closer
            windowStart: t, windowEnd: t + 9_000)
        XCTAssertEqual(intervals.count, 1, "duplicate closer must not open a second interval: \(intervals)")
        XCTAssertEqual(intervals[0].start, t + 1_000, "must not slide back to windowStart")
        XCTAssertEqual(intervals[0].end, t + 2_000)
    }

    /// The events-missing fallback. On the real night the decoded `battery_charging` bit read FALSE on every
    /// reading while SoC climbed 9.4 → 100 %, and the per-reading steps (~0.2–0.8 pp at a ~30 s cadence)
    /// never cleared `StrapChargeInference`'s fixed 1.0 pp threshold — so this is a RATE test (pp per hour),
    /// which separates a ~20 pp/h charge from a ~1.65 pp/h discharge at any cadence.
    func testSocRiseInfersChargeWhenEventsAreMissing() {
        let t = 3_000_000
        // 9.4 % → 100 % over 4.5 h in 30 s steps: exactly the real night's shape.
        let rising = stride(from: 0, through: 16_200, by: 30).map { (ts: t + $0, soc: 9.4 + Double($0) * 0.0056) }
        let inferred = AnalyticsEngine.chargeIntervalsFromSoc(rising)
        XCTAssertEqual(inferred.count, 1, "a sustained rise is ONE charge interval: \(inferred)")
        XCTAssertLessThanOrEqual(inferred[0].start, t + 60)
        XCTAssertGreaterThanOrEqual(inferred[0].end, t + 16_000)
        // A normal overnight discharge must NOT be mistaken for a charge.
        let falling = stride(from: 0, through: 28_800, by: 30).map { (ts: t + $0, soc: 90.0 - Double($0) * 0.00046) }
        XCTAssertTrue(AnalyticsEngine.chargeIntervalsFromSoc(falling).isEmpty,
                      "a ~1.65 pp/h discharge is not a charge")
    }
}
