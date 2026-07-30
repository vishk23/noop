import StrandAnalytics
import XCTest

@testable import sleepbench

/// `sleepSession.stagesJSON` has more than one producer and they disagree on how to spell wake: the
/// on-device stager writes `"wake"`, the noop-cloud stage-edit vocabulary writes `"awake"`. The harness
/// used to compare against a bare `"wake"` literal, so an `"awake"` epoch was scored as SLEEP — biasing
/// wake DOWN and sleep UP in exactly the metrics the project has repeatedly re-measured and got wrong
/// signs on (wake-minute error, wake over-call, sleep/wake kappa).
///
/// Every test here scores the SAME night written two ways and demands the two agree. No database, no
/// health data, no `--db` argument.
final class StageVocabularyTests: XCTestCase {

    private func run(_ stage: String, _ n: Int) -> [String] { [String](repeating: stage, count: n) }

    /// One night, two spellings: 40 epochs wake, 100 light, 20 deep, 20 rem, then 20 more wake.
    private var deviceSpelling: [String] {
        run("wake", 40) + run("light", 100) + run("deep", 20) + run("rem", 20) + run("wake", 20)
    }
    private var cloudSpelling: [String] {
        run("awake", 40) + run("light", 100) + run("deep", 20) + run("rem", 20) + run("awake", 20)
    }

    // MARK: - The closed stage set

    /// The harness classifies by "everything that is not wake is sleep", which is sound only while the
    /// canonical vocabulary is these four. A fifth label must break this test, not land in the sleep bucket.
    func testStageOrderIsTheClosedCanonicalSet() {
        XCTAssertEqual(Set(stageOrder), SleepStageVocabulary.canonicalStages)
        XCTAssertEqual(stageOrder, ["wake", "light", "deep", "rem"])
        XCTAssertFalse(stageOrder.contains("awake"), "\"awake\" is an input spelling, never a canonical class")
    }

    func testIsWakeAcceptsBothSpellingsAndRejectsSleepStages() {
        for w in ["wake", "awake", "Awake", "  WAKE "] { XCTAssertTrue(isWake(w), "\(w) should read as wake") }
        for s in ["light", "deep", "rem"] { XCTAssertFalse(isWake(s)) }
    }

    // MARK: - The two spellings must score identically

    func testWakeMinutesAreIdenticalAcrossSpellings() {
        XCTAssertEqual(wakeMinutes(cloudSpelling), wakeMinutes(deviceSpelling), accuracy: 1e-9)
        // 60 wake epochs x 30 s = 30 min. The pre-fix harness returned 0 for the cloud spelling.
        XCTAssertEqual(wakeMinutes(cloudSpelling), 30.0, accuracy: 1e-9)
    }

    func testSleepMinutesAreIdenticalAcrossSpellings() {
        XCTAssertEqual(sleepMinutes(cloudSpelling), sleepMinutes(deviceSpelling), accuracy: 1e-9)
        // 140 sleep epochs x 30 s = 70 min. The pre-fix harness counted all 200 epochs (100 min) as sleep.
        XCTAssertEqual(sleepMinutes(cloudSpelling), 70.0, accuracy: 1e-9)
    }

    func testToSleepWakeIsIdenticalAcrossSpellings() {
        XCTAssertEqual(toSleepWake(cloudSpelling), toSleepWake(deviceSpelling))
        // The pre-fix collapse mapped every "awake" epoch to "sleep", producing a reference that claims
        // the wearer never woke — which is what section C's sleep/wake kappa was scored against.
        XCTAssertEqual(toSleepWake(cloudSpelling).filter { $0 == "wake" }.count, 60)
    }

    func testOnsetAndFinalWakeAreIdenticalAcrossSpellings() {
        let cloud = onsetAndFinalWake(cloudSpelling), device = onsetAndFinalWake(deviceSpelling)
        XCTAssertEqual(cloud.onset, device.onset)
        XCTAssertEqual(cloud.final, device.final)
        // Onset is the first sleep epoch (index 40), final wake the last (index 179). Pre-fix, onset landed
        // on index 0 — the first "awake" epoch — collapsing the whole 20 min sleep latency to zero.
        XCTAssertEqual(cloud.onset, 40)
        XCTAssertEqual(cloud.final, 179)
    }

    func testStagePercentagesAndBiasAreIdenticalAcrossSpellings() {
        let cloud = stagePercentages(cloudSpelling), device = stagePercentages(deviceSpelling)
        for s in stageOrder { XCTAssertEqual(cloud[s]!, device[s]!, accuracy: 1e-9, "stage \(s)") }
        XCTAssertEqual(cloud["wake"]!, 30.0, accuracy: 1e-9)   // 60 of 200 epochs
        // Pre-fix, "awake" opened a fifth key no caller reads and "wake" stayed at 0 — so a night the human
        // scored 30% awake was reported as a 30 pp UNDER-call of wake against any replay that got it right.
        XCTAssertNil(cloud["awake"])

        // A recipe scored against the two spellings of the same reference must get the same bias.
        let pred = run("wake", 60) + run("light", 140)
        let bCloud = stageBias(ref: cloudSpelling, pred: pred)
        let bDevice = stageBias(ref: deviceSpelling, pred: pred)
        for s in stageOrder { XCTAssertEqual(bCloud[s]!, bDevice[s]!, accuracy: 1e-9, "bias \(s)") }
        XCTAssertEqual(bCloud["wake"]!, 0.0, accuracy: 1e-9, "same wake fraction ⇒ zero bias")
    }

    func testFirstRemLatencyIsIdenticalAcrossSpellings() {
        XCTAssertEqual(firstRemLatencyMinutes(cloudSpelling)!,
                       firstRemLatencyMinutes(deviceSpelling)!, accuracy: 1e-9)
        // Onset at epoch 40, REM at epoch 160 ⇒ 120 epochs x 30 s = 60 min. Pre-fix the cloud spelling put
        // onset at epoch 0 and reported 80 min.
        XCTAssertEqual(firstRemLatencyMinutes(cloudSpelling)!, 60.0, accuracy: 1e-9)
    }

    // MARK: - Agreement scoring

    /// The nastiest pre-fix failure mode: an `"awake"` reference epoch matched no class in `stageOrder`, so
    /// `Confusion.add` dropped it entirely. The epochs did not go to the wrong cell — they left the matrix,
    /// silently shrinking the denominator under every accuracy and kappa in the run.
    func testConfusionKeepsEveryEpochRegardlessOfSpelling() {
        let pred = deviceSpelling
        let cloud = confusion(ref: cloudSpelling, pred: pred)
        let device = confusion(ref: deviceSpelling, pred: pred)
        XCTAssertEqual(cloud.total, 200, "no epoch may be dropped for spelling wake \"awake\"")
        XCTAssertEqual(cloud.total, device.total)
        XCTAssertEqual(cloud.m, device.m)
        XCTAssertEqual(cloud.accuracy, 1.0, accuracy: 1e-9)
    }

    /// Section C's kappa, which scores each recipe against the strap's own band sleep_state, is computed on
    /// the 2-class collapse — so the fold decides it outright.
    func testSleepWakeKappaIsIdenticalAcrossSpellings() {
        let pred = toSleepWake(deviceSpelling)
        let cloud = confusion(ref: toSleepWake(cloudSpelling), pred: pred, classes: ["wake", "sleep"])
        let device = confusion(ref: toSleepWake(deviceSpelling), pred: pred, classes: ["wake", "sleep"])
        XCTAssertEqual(cloud.kappa, device.kappa, accuracy: 1e-9)
        XCTAssertEqual(cloud.kappa, 1.0, accuracy: 1e-9, "a hypnogram scored against itself is perfect agreement")
    }

    // MARK: - The load path

    /// Canonicalisation has to happen on the way in from `StageSegment`, not only in the predicates — this
    /// is the shape the harness actually reads out of `stagesJSON`.
    func testEpochLabelsCanonicaliseCloudSpelledSegments() {
        let start = 1_700_000_000
        let cloud = [
            StageSegment(start: start, end: start + 1800, stage: "awake"),
            StageSegment(start: start + 1800, end: start + 3600, stage: "light"),
            StageSegment(start: start + 3600, end: start + 5400, stage: "rem"),
        ]
        let device = cloud.map {
            StageSegment(start: $0.start, end: $0.end, stage: $0.stage == "awake" ? "wake" : $0.stage)
        }
        let lc = epochLabels(cloud, start: start, end: start + 5400)
        let ld = epochLabels(device, start: start, end: start + 5400)
        XCTAssertEqual(lc, ld)
        XCTAssertFalse(lc.contains("awake"), "expansion must emit canonical labels only")
        XCTAssertEqual(wakeMinutes(lc), 30.0, accuracy: 1e-9)
        XCTAssertEqual(firstRemLatencyMinutes(lc)!, 30.0, accuracy: 1e-9)
    }

    /// A JSON round-trip through the exact `[{start,end,stage}]` shape the cloud mirror serves, to pin that
    /// the decode path the harness uses carries the alias all the way to a scored metric.
    func testCloudSpelledStagesJSONDecodesToTheSameMetrics() throws {
        let start = 1_700_000_000
        let json = """
        [{"start":\(start),"end":\(start + 1800),"stage":"awake"},
         {"start":\(start + 1800),"end":\(start + 5400),"stage":"light"}]
        """
        let segs = try JSONDecoder().decode([StageSegment].self, from: Data(json.utf8))
        XCTAssertEqual(segs.first?.stage, "awake", "the decoder itself must not silently rewrite the label")
        let labels = epochLabels(segs, start: start, end: start + 5400)
        XCTAssertEqual(wakeMinutes(labels), 30.0, accuracy: 1e-9)
        XCTAssertEqual(sleepMinutes(labels), 60.0, accuracy: 1e-9)
    }
}
