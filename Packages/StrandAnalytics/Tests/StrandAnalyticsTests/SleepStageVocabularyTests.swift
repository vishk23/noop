import XCTest

@testable import StrandAnalytics

/// The wake-spelling fold is the only thing standing between a cloud-authored hypnogram (`"awake"`) and
/// every consumer that compares against the device spelling (`"wake"`). Pinned here rather than only in
/// the harness because `Packages/**` is the sole tree default CI actually runs.
final class SleepStageVocabularyTests: XCTestCase {

    func testBothSpellingsOfWakeCanonicaliseTogether() {
        XCTAssertEqual(SleepStageVocabulary.canonical("wake"), "wake")
        XCTAssertEqual(SleepStageVocabulary.canonical("awake"), "wake")
        XCTAssertTrue(SleepStageVocabulary.isWake("wake"))
        XCTAssertTrue(SleepStageVocabulary.isWake("awake"))
    }

    /// Case and surrounding whitespace must not decide whether an epoch counts as wake. A hand-edited or
    /// hand-built hypnogram is the realistic source of `"Awake"`, and the failure it causes is silent.
    func testCanonicalisationIsCaseAndWhitespaceInsensitive() {
        for spelling in ["Awake", "AWAKE", "  awake  ", "Wake", "WAKE", "\twake\n"] {
            XCTAssertTrue(SleepStageVocabulary.isWake(spelling), "\(spelling) should read as wake")
            XCTAssertEqual(SleepStageVocabulary.canonical(spelling), "wake")
        }
    }

    func testSleepStagesAreNotWakeAndArePreserved() {
        for stage in ["light", "deep", "rem"] {
            XCTAssertFalse(SleepStageVocabulary.isWake(stage))
            XCTAssertEqual(SleepStageVocabulary.canonical(stage), stage)
            XCTAssertEqual(SleepStageVocabulary.canonical(stage.uppercased()), stage)
        }
    }

    /// The closed set is load-bearing: consumers classify by "everything that is not wake is sleep", which
    /// is only sound while these four are the whole vocabulary. A new producer adding a fifth label must
    /// break this test rather than silently land in the sleep bucket.
    func testCanonicalStageSetIsClosedAndSelfConsistent() {
        XCTAssertEqual(SleepStageVocabulary.canonicalStages, ["wake", "light", "deep", "rem"])
        for stage in SleepStageVocabulary.canonicalStages {
            XCTAssertEqual(SleepStageVocabulary.canonical(stage), stage, "\(stage) must be its own canonical form")
        }
        // "awake" is an accepted INPUT spelling but is not itself canonical — it must fold, not survive.
        XCTAssertFalse(SleepStageVocabulary.canonicalStages.contains("awake"))
    }

    /// An unrecognised token stays visible instead of being coerced into a stage it is not — a decode bug
    /// should look like a decode bug, not like sleep.
    func testUnknownLabelsArePassedThroughNotCoerced() {
        XCTAssertEqual(SleepStageVocabulary.canonical("restless"), "restless")
        XCTAssertFalse(SleepStageVocabulary.isWake("restless"))
        XCTAssertFalse(SleepStageVocabulary.canonicalStages.contains(SleepStageVocabulary.canonical("restless")))
    }

    /// The concrete regression: the noop-cloud stage-edit vocabulary. `CloudEditApplier` folds these on the
    /// way onto a device, but a corpus assembled from the cloud mirror never passes through it.
    func testCloudEditVocabularyFoldsOntoTheDeviceVocabulary() {
        let cloud = ["awake", "light", "deep", "rem"]
        let device = ["wake", "light", "deep", "rem"]
        XCTAssertEqual(cloud.map(SleepStageVocabulary.canonical), device)
    }
}
