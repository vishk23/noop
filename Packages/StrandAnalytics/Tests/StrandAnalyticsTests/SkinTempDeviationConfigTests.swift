import XCTest
@testable import StrandAnalytics

/// Pins the CONFIG-SEMANTICS bug that made two shipped skin-temp baselines permanently dead.
///
/// `skinTempDevC` stores a ±°C DEVIATION (roughly −1.2…+1.2). The absolute `skin_temp` config sanity-gates
/// every night to 20…42 °C, so folding a deviation series through it rejects EVERY value at
/// `Baselines.update`: `nValid` stays 0, the state never leaves `.calibrating`, and `usable`/`trusted` are
/// false forever. Both the illness watch's skin signal and `AppModel.computeCyclePhase` did exactly that,
/// which made their "baseline is usable" branches unreachable dead code.
final class SkinTempDeviationConfigTests: XCTestCase {

    /// A realistic nightly deviation series (the shape of a real 30-night history, not a user's data).
    private let deviations: [Double?] = [
        -0.2, 0.3, 0.2, 0.4, 0.1, -0.4, -0.9, 0.1, 0.4, 0.8,
        1.2, 0.4, 0.1, -0.1, 0.4, -0.4, -0.2, -0.6, -1.2, -0.4,
        -0.1, -0.5, 0.1, 0.0, -0.2, -0.7, 0.3, 0.2, -0.3, 0.5,
    ]

    /// THE BUG. Every deviation is outside 20…42, so every night is skip-and-held.
    func testAbsoluteConfigRejectsEveryDeviationNight() {
        let cfg = try! XCTUnwrap(Baselines.metricCfg["skin_temp"])
        let state = Baselines.foldHistory(deviations, cfg: cfg)
        XCTAssertEqual(state.nValid, 0, "the absolute config must reject every ±°C deviation")
        XCTAssertEqual(state.status, .calibrating)
        XCTAssertFalse(state.usable, "so `usable` is permanently false — the dead-baseline bug")
        XCTAssertFalse(state.trusted)
    }

    /// THE FIX. The deviation config accepts them and produces a real personal spread.
    func testDeviationConfigFoldsAndBecomesTrusted() {
        let state = Baselines.foldHistory(deviations, cfg: VitalBands.skinTempDeviationCfg)
        XCTAssertEqual(state.nValid, deviations.compactMap { $0 }.count,
                       "every valid deviation night must fold")
        XCTAssertTrue(state.usable)
        XCTAssertTrue(state.trusted, "30 nights is past minNightsTrust, so the caller may act on it")
    }

    /// The spread must be a REAL personal spread, not the floor a fully-rejected series collapses to.
    /// This is what makes the z meaningful: the measured SD of a real WHOOP history is ~0.52 °C, well
    /// clear of the 0.3 floorSpread the old `/ 0.3` divisor mistook for one.
    func testFoldedSpreadLiftsOffTheFloor() {
        let state = Baselines.foldHistory(deviations, cfg: VitalBands.skinTempDeviationCfg)
        XCTAssertGreaterThan(state.spread, VitalBands.skinTempDeviationCfg.floorSpread,
                             "a real history must lift the spread above its floor")
    }

    /// The 0.3 divisor was not "one personal spread": against a real spread it inflates the z. A +0.6 °C
    /// night reads z = 2.0 under the old divisor (firing) but well under it against the real fold.
    func testOldDivisorInflatesTheZRelativeToTheRealFold() {
        let state = Baselines.foldHistory(deviations, cfg: VitalBands.skinTempDeviationCfg)
        let value = 0.6
        let oldZ = value / 0.3
        let realZ = Baselines.deviation(value, state: state).z
        XCTAssertEqual(oldZ, 2.0, accuracy: 1e-9, "the old divisor put +0.6 °C exactly on the fire line")
        XCTAssertLessThan(realZ, oldZ, "the real personal spread must yield a smaller z than the floor did")
    }

    /// A CSV-imported ABSOLUTE history must still fold through the absolute config — the fix must not
    /// simply swap one hardcoded config for another.
    func testAbsoluteHistoryStillFoldsThroughTheAbsoluteConfig() {
        let absolute: [Double?] = Array(repeating: 33.2, count: 20)
        let cfg = try! XCTUnwrap(Baselines.metricCfg["skin_temp"])
        XCTAssertTrue(VitalBands.isAbsoluteSkinTemp(33.2))
        let state = Baselines.foldHistory(absolute, cfg: cfg)
        XCTAssertEqual(state.nValid, 20)
        XCTAssertTrue(state.usable)
    }

    /// And the old fallback was catastrophic on an absolute row: 33.2 / 0.3 is a z of ~110, which would
    /// have fired the signal at full weight every single night.
    func testOldDivisorOnAnAbsoluteRowProducedAnAbsurdZ() {
        XCTAssertGreaterThan(33.2 / 0.3, 100.0)
    }
}
