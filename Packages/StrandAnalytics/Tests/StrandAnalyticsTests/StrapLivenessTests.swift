import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// Every fixture here is the shape of a real, verified span from the 2026-06-26→08-06 corpus. The three
/// states are the whole point, so each is pinned against the episode that motivated it.
final class StrapLivenessTests: XCTestCase {

    private func beat(_ ts: Int) -> WhoopEvent {
        WhoopEvent(ts: ts, kind: "STRAP_CONDITION_REPORT(29)", payload: [:])
    }
    private func hr(_ ts: Int) -> HRSample { HRSample(ts: ts, bpm: 60) }

    /// Worn and collecting: the heartbeat beats and HR flows.
    func testHeartbeatWithHRIsCollecting() {
        let t = 1_785_000_000
        let events = stride(from: 0, to: 3_600, by: 600).map { beat(t + $0) }
        let samples = stride(from: 0, to: 3_600, by: 1).map { hr(t + $0) }
        let bins = StrapLiveness.timeline(events: events, hr: samples,
                                          windowStart: t, windowEnd: t + 3_600)
        XCTAssertEqual(bins.count, 4)                       // 3600 / 900
        XCTAssertTrue(bins.allSatisfy { $0.state == .collecting }, "\(bins.map(\.state))")
        XCTAssertEqual(StrapLiveness.summarize(bins).collectingSeconds, 3_600)
    }

    /// THE CASE THIS TYPE EXISTS FOR — the real 2026-08-01T22:53:30Z→08-02T01:40:18Z off-wrist episode.
    /// 167 minutes bounded to the second by WRIST_OFF/WRIST_ON, during which the strap logged 16
    /// STRAP_CONDITION_REPORTs and HR was absent. That is `aliveNotWorn`: an honest absence, NOT a gap to
    /// go hunting for. Before this, it was indistinguishable from a dead strap.
    func testHeartbeatWithoutHRIsAliveNotWorn() {
        let start = 1_785_624_810                           // 2026-08-01T22:53:30Z
        let end = start + 10_008                            // 08-02T01:40:18Z, the verified 10,008 s
        let events = stride(from: 0, to: 10_008, by: 600).map { beat(start + $0) }
        XCTAssertEqual(events.count, 17, "the real episode carried ~16 reports at a ~600 s cadence")
        let bins = StrapLiveness.timeline(events: events, hr: [], windowStart: start, windowEnd: end)
        XCTAssertTrue(bins.allSatisfy { $0.state == .aliveNotWorn }, "\(bins.map(\.state))")
        let s = StrapLiveness.summarize(bins)
        XCTAssertEqual(s.aliveNotWornSeconds, 10_008)
        XCTAssertEqual(s.collectingSeconds, 0)
        XCTAssertEqual(s.silentSeconds, 0)
    }

    /// THE REGRESSION THE REAL DATA CAUGHT. That same 167-minute off-wrist episode carried exactly ONE HR
    /// sample in 10,008 s. Under an "any HR at all" rule that single stray sample flipped the entire episode
    /// to `.collecting`, which is the precise confusion this type exists to remove. Coverage — not presence
    /// — is the test.
    func testOneStrayHRSampleDoesNotDefeatAliveNotWorn() {
        let start = 1_785_624_810
        let end = start + 10_008
        let events = stride(from: 0, to: 10_008, by: 600).map { beat(start + $0) }
        let bins = StrapLiveness.timeline(events: events, hr: [hr(start + 5_000)],
                                          windowStart: start, windowEnd: end)
        XCTAssertTrue(bins.allSatisfy { $0.state == .aliveNotWorn },
                      "one sample in 167 min is not 'worn': \(bins.map(\.state))")
        XCTAssertEqual(StrapLiveness.summarize(bins).aliveNotWornSeconds, 10_008)
    }

    /// The threshold sits in a measured empty gap: across the corpus no bin fell between 5 % and 20 %
    /// coverage, so any value in [0.05, 0.20) classifies identically. Pin both sides of it.
    func testCoverageThresholdSeparatesWornFromNotWorn() {
        let t = 1_785_000_000
        let events = [beat(t), beat(t + 600)]
        // 4 % coverage (36 samples in 900 s) — below the bar, not worn.
        let sparse = (0..<36).map { hr(t + $0 * 25) }
        XCTAssertEqual(StrapLiveness.timeline(events: events, hr: sparse,
                                              windowStart: t, windowEnd: t + 900).first?.state,
                       .aliveNotWorn)
        // 50 % coverage (450 samples in 900 s) — above the bar, worn.
        let dense = (0..<450).map { hr(t + $0 * 2) }
        XCTAssertEqual(StrapLiveness.timeline(events: events, hr: dense,
                                              windowStart: t, windowEnd: t + 900).first?.state,
                       .collecting)
        XCTAssertEqual(StrapLiveness.wornHRCoverage, 0.10, accuracy: 0.0001)
    }

    /// The 2026-07-05T04:31:23Z→07-09T23:23:48Z dead span: 114 h 52 m in which the strap emitted 10
    /// heartbeats where the cadence predicts ~689, and 2026-07-06/07/08 carried ZERO events and ZERO HR.
    /// This is the one state that means "go look for missing data".
    func testNoHeartbeatIsSilentEvenThoughSomeEventsExist() {
        let start = 1_783_225_883                           // 2026-07-05T04:31:23Z
        let end = start + 413_545                           // 07-09T23:23:48Z
        // Ten beats clustered at the very start, then nothing for the remaining ~114 h.
        let events = (0..<10).map { beat(start + $0 * 600) }
        let bins = StrapLiveness.timeline(events: events, hr: [], windowStart: start, windowEnd: end)
        let s = StrapLiveness.summarize(bins)
        XCTAssertGreaterThan(s.silentSeconds, 400_000, "the span must read overwhelmingly silent")
        XCTAssertEqual(s.heartbeats, 10)
        XCTAssertEqual(s.expectedHeartbeats, 689, "413,545 s / 600 s — the ratio is what makes it legible")
        XCTAssertTrue(s.summary.contains("Diagnostic only"), s.summary)
    }

    /// Jitter must not fake a death. The real cadence is ~600 s but only ~35 % of inter-arrivals are exactly
    /// 600, so a 600 s bin can straddle two beats and leave one empty. At the 1.5× default a beat drifting
    /// by ±5 s (the observed 595–605 s band) never empties a bin.
    func testCadenceJitterDoesNotProduceFalseSilent() {
        let t = 1_785_000_000
        var ts = t
        var events: [WhoopEvent] = []
        // Alternate 595 / 605 s — the observed extremes of the band.
        for i in 0..<40 { events.append(beat(ts)); ts += (i % 2 == 0) ? 595 : 605 }
        let samples = stride(from: 0, to: 24_000, by: 1).map { hr(t + $0) }
        let bins = StrapLiveness.timeline(events: events, hr: samples,
                                          windowStart: t, windowEnd: t + 24_000)
        XCTAssertFalse(bins.contains { $0.state == .silent },
                       "jitter inside 595–605 s must not read as silent: \(bins.filter { $0.state == .silent })")
    }

    /// Bins tile the window exactly: contiguous, half-open, and the LAST ONE ABSORBS the remainder rather
    /// than being clipped short. A clipped 200 s tail could not contain a ~600 s-cadence beat, so it would
    /// report `.silent` at the end of every healthy window for a purely arithmetic reason.
    func testLastBinAbsorbsTheRemainderInsteadOfBeingClipped() {
        let t = 1_000_000
        let span = 2_000                                     // 2 × 900 + 200
        let bins = StrapLiveness.timeline(events: [], hr: [], windowStart: t, windowEnd: t + span)
        XCTAssertEqual(bins.count, 2, "the 200 s remainder is absorbed, not left as a third bin: \(bins)")
        XCTAssertEqual(bins[0].start, t)
        XCTAssertEqual(bins.last?.end, t + span)
        XCTAssertEqual(bins.last!.end - bins.last!.start, 1_100, "the last bin is 900 + the 200 remainder")
        XCTAssertEqual(bins.map { $0.end - $0.start }.reduce(0, +), span)
        for (a, b) in zip(bins, bins.dropFirst()) { XCTAssertEqual(a.end, b.start, "bins must be contiguous") }
        XCTAssertEqual(StrapLiveness.summarize(bins).totalSeconds, span)
        // Every bin is at least `binSeconds` wide — the property the 1.5×-cadence choice rests on.
        XCTAssertTrue(bins.allSatisfy { $0.end - $0.start >= StrapLiveness.defaultBinSeconds })
        // A window shorter than one bin is a single bin, not zero and not a sliver.
        let short = StrapLiveness.timeline(events: [], hr: [], windowStart: t, windowEnd: t + 120)
        XCTAssertEqual(short.count, 1)
        XCTAssertEqual(short[0].end - short[0].start, 120)
    }

    /// Liveness asks whether the strap emitted anything, not whether the beat was plausible. An
    /// out-of-band bpm still proves the strap was on a wrist and reporting, so it must NOT read as
    /// `aliveNotWorn` — that would recreate the exact ambiguity this type removes.
    func testImplausibleBpmStillCountsAsCollecting() {
        let t = 1_785_000_000
        // Fully covered, but every bpm is outside the 30–220 band the scoring paths gate on.
        let wild = (0..<900).map { HRSample(ts: t + $0, bpm: 250) }
        let bins = StrapLiveness.timeline(events: [beat(t)], hr: wild,
                                          windowStart: t, windowEnd: t + 900)
        XCTAssertEqual(bins.first?.state, .collecting,
                       "liveness asks whether the strap emitted, not whether the beat was plausible")
    }

    /// Unsorted input, an empty window and an inverted window must all behave.
    func testUnsortedInputAndDegenerateWindows() {
        let t = 1_785_000_000
        let shuffled = [beat(t + 800), beat(t + 100), beat(t + 400)]
        let bins = StrapLiveness.timeline(events: shuffled, hr: [], windowStart: t, windowEnd: t + 900)
        XCTAssertEqual(bins.count, 1)
        XCTAssertEqual(bins[0].heartbeats, 3, "sorting is internal; callers need not pre-sort")
        XCTAssertTrue(StrapLiveness.timeline(events: shuffled, hr: [],
                                             windowStart: t, windowEnd: t).isEmpty)
        XCTAssertTrue(StrapLiveness.timeline(events: shuffled, hr: [],
                                             windowStart: t, windowEnd: t - 5).isEmpty)
    }

    /// Non-heartbeat events contribute nothing — the corpus banks 36 event kinds and only one is the
    /// heartbeat.
    func testOtherEventKindsAreIgnored() {
        let t = 1_785_000_000
        let noise = [WhoopEvent(ts: t + 1, kind: "BATTERY_LEVEL(3)", payload: [:]),
                     WhoopEvent(ts: t + 2, kind: "WRIST_OFF(10)", payload: [:]),
                     WhoopEvent(ts: t + 3, kind: "SET_RTC(16)", payload: [:])]
        let bins = StrapLiveness.timeline(events: noise, hr: [hr(t + 5)],
                                          windowStart: t, windowEnd: t + 900)
        XCTAssertEqual(bins.first?.state, .silent, "HR without a heartbeat is still silent")
        XCTAssertEqual(bins.first?.heartbeats, 0)
    }
}
