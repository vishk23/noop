# Sleep night-stitch (#364) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A night split by a short mid-night wake presents as ONE night — one `.inBed` span per bridged night in the Apple Health / Health Connect exports with the gap as a `wake` stage, and the gap rendered as a wake segment (and counted as awake minutes) in both sleep screens.

**Architecture:** One new pure primitive in the analytics layer (`bridgedNightGroups` — the existing #561 bridge loop extracted so it returns EVERY bridged group plus each group's inter-fragment gaps), a pure merged-plan builder per write path (`HealthWriteback.mergedSleepPlan` in StrandImport; `HealthExportPlan.sleepSessions` grows grouping in Kotlin), and four thin consumers. Detector and stored sessions untouched; grouping is read-time.

**Tech Stack:** Swift 5.9 packages (StrandAnalytics, StrandImport; `swift test` on macOS), app-target Swift (HealthKit, SwiftUI — compile via `xcodebuild`, no default CI), Kotlin/JVM (JUnit4 via `testFullDebugUnitTest` — no local toolchain, verified on fork Android CI), Health Connect SDK.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-12-sleep-night-stitch-design.md`; maintainer direction on issue #364.
- Reuse `gapBridgeMaxMin` (60) + `nightTailBridgeMaxMin` (90) + `isOvernightOnset` — NO new threshold.
- The `mainNightGroupIndices` refactor must be byte-identical (the #561/#861 golden tests pin it).
- Cross-platform parity: `bridgedNightGroups` Swift↔Kotlin identical semantics; same fixtures + expected values in both test suites.
- HealthKit dedup: merged samples keyed by the group's EARLIEST fragment's immutable `startTs`; the delete predicate must carry EVERY fragment's key. Health Connect: same rule via `clientRecordId`, plus explicit `deleteRecords` for absorbed fragment ids (HC does not auto-remove).
- Spans use `effectiveStartTs` (edited onset); keys use immutable `startTs`. Kotlin `SleepInput` must gain that split (it currently conflates them).
- `Packages/` may not import AppKit/UIKit/HealthKit; StrandImport does NOT depend on StrandAnalytics (grouping happens in the caller; the plan builders take pre-grouped fragments / compute their own seams).
- No Claude attribution anywhere. Commit style: `feat(sleep): …` / `fix(sleep): …` lowercase.
- Work happens on branch `feat/sleep-night-stitch-364` off `upstream/main` in a worktree (VK's `main` is ~72 ahead of upstream; the PR must be clean).

---

### Task 1: Swift analytics primitive — `bridgedNightGroups` (+ refactor `mainNightGroupIndices`)

**Files:**
- Modify: `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStageTotals.swift` (insert after `bridgeAdjacent`, ~line 306; refactor `mainNightGroupIndices` ~line 325)
- Test: `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/BridgedNightGroupsTests.swift` (create)

**Interfaces:**
- Consumes: existing `NightBlock`, `gapBridgeMaxMin`, `nightTailBridgeMaxMin`, `isOvernightOnset`.
- Produces (later tasks rely on these exact names):

```swift
public struct BridgedNightGroup: Equatable {
    /// Indices into the ORIGINAL input array, ascending by effective onset.
    public let indices: [Int]
    /// Inter-fragment wake seams inside this group, ascending: (prev bridged end, next fragment start).
    public let gaps: [GapSpan]
    public struct GapSpan: Equatable {
        public let start: Int, end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
    }
    public init(indices: [Int], gaps: [GapSpan]) { self.indices = indices; self.gaps = gaps }
}

/// EVERY bridged night group over `blocks` (not just the main night): the same two-tier bridge
/// `mainNightGroupIndices` applies (#561/#861), minus the winner pick. Groups ordered by start.
public static func bridgedNightGroups(_ blocks: [NightBlock], offsetSec: Int) -> [BridgedNightGroup]
```

- [ ] **Step 1: Write the failing tests** (`BridgedNightGroupsTests.swift`)

```swift
import XCTest
@testable import StrandAnalytics

/// Pins the all-groups bridge (#364): the SAME two-tier gap bridge the main-night selector applies,
/// returned for EVERY group so the Health write-back and the sleep screens can present each bridged
/// night as one night with its wake seams explicit.
final class BridgedNightGroupsTests: XCTestCase {
    private typealias B = SleepStageTotals.NightBlock
    // 2026-01-02 00:00 UTC for readable fixtures.
    private let t0 = 1_767_312_000

    func testShortWakeBridgesTwoFragmentsWithOneGap() {
        // 23:00→02:00, 16-min wake, 02:16→06:00 — the #364 example shape.
        let a = B(start: t0 - 3_600, end: t0 + 2 * 3_600)
        let b = B(start: t0 + 2 * 3_600 + 16 * 60, end: t0 + 6 * 3_600)
        let groups = SleepStageTotals.bridgedNightGroups([a, b], offsetSec: 0)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].indices, [0, 1])
        XCTAssertEqual(groups[0].gaps, [.init(start: a.end, end: b.start)])
    }

    func testDaytimeNapStaysItsOwnGroup() {
        let night = B(start: t0 - 3_600, end: t0 + 6 * 3_600)          // 23:00→06:00
        let nap = B(start: t0 + 14 * 3_600, end: t0 + 15 * 3_600)      // 14:00→15:00
        let groups = SleepStageTotals.bridgedNightGroups([night, nap], offsetSec: 0)
        XCTAssertEqual(groups.map(\.indices), [[0], [1]])
        XCTAssertTrue(groups.allSatisfy { $0.gaps.isEmpty })
    }

    func testNightTailBridgesOvernightGapOverSixtyMinutes() {
        // 75-min gap, second fragment onset 04:15 (overnight band) → bridged by the #861 night-tail rule.
        let a = B(start: t0 - 3_600, end: t0 + 3 * 3_600)
        let b = B(start: t0 + 3 * 3_600 + 75 * 60, end: t0 + 7 * 3_600)
        let groups = SleepStageTotals.bridgedNightGroups([a, b], offsetSec: 0)
        XCTAssertEqual(groups.map(\.indices), [[0, 1]])
        XCTAssertEqual(groups[0].gaps, [.init(start: a.end, end: b.start)])
    }

    func testThreeFragmentNightYieldsTwoGaps() {
        let a = B(start: t0, end: t0 + 3_600)
        let b = B(start: t0 + 3_600 + 600, end: t0 + 2 * 3_600)
        let c = B(start: t0 + 2 * 3_600 + 900, end: t0 + 3 * 3_600)
        let groups = SleepStageTotals.bridgedNightGroups([a, b, c], offsetSec: 0)
        XCTAssertEqual(groups.map(\.indices), [[0, 1, 2]])
        XCTAssertEqual(groups[0].gaps, [.init(start: a.end, end: b.start),
                                        .init(start: b.end, end: c.start)])
    }

    func testContainedFragmentProducesNoGap() {
        // b sits inside a (gap < 0): bridged, no seam emitted.
        let a = B(start: t0, end: t0 + 4 * 3_600)
        let b = B(start: t0 + 3_600, end: t0 + 2 * 3_600)
        let groups = SleepStageTotals.bridgedNightGroups([a, b], offsetSec: 0)
        XCTAssertEqual(groups.map(\.indices), [[0, 1]])
        XCTAssertTrue(groups[0].gaps.isEmpty)
    }

    func testUnsortedInputIndicesReferOriginalPositions() {
        let late = B(start: t0 + 2 * 3_600 + 16 * 60, end: t0 + 6 * 3_600)
        let early = B(start: t0 - 3_600, end: t0 + 2 * 3_600)
        let groups = SleepStageTotals.bridgedNightGroups([late, early], offsetSec: 0)
        XCTAssertEqual(groups.map(\.indices), [[0, 1]])   // ascending original indices [1(early)…] sorted → [0,1]? NO:
        // indices are into the ORIGINAL array: early is index 1, late is index 0 → group indices sorted ascending [0, 1].
        XCTAssertEqual(groups[0].gaps, [.init(start: early.end, end: late.start)])
    }

    func testEmptyInputYieldsNoGroups() {
        XCTAssertTrue(SleepStageTotals.bridgedNightGroups([], offsetSec: 0).isEmpty)
    }

    /// The refactor guard: the main-night pick over the new all-groups pass must stay byte-identical
    /// to the existing golden behaviour (the #561 suite pins the rest).
    func testMainNightGroupIndicesUnchangedForBiphasicPlusNap() {
        let a = B(start: t0 - 3_600, end: t0 + 2 * 3_600)
        let b = B(start: t0 + 2 * 3_600 + 16 * 60, end: t0 + 6 * 3_600)
        let nap = B(start: t0 + 14 * 3_600, end: t0 + 15 * 3_600)
        XCTAssertEqual(SleepStageTotals.mainNightGroupIndices([a, b, nap], offsetSec: 0), [0, 1])
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `swift test --package-path Packages/StrandAnalytics --filter BridgedNightGroupsTests` → FAIL: `bridgedNightGroups` unresolved.

- [ ] **Step 3: Implement** — insert `BridgedNightGroup` + `bridgedNightGroups` after `bridgeAdjacent` (~line 306). Extract the existing loop from `mainNightGroupIndices` verbatim, adding gap capture:

```swift
    /// One bridged night group over the whole input: the fragments (as ORIGINAL indices) plus the
    /// inter-fragment wake seams. Produced by `bridgedNightGroups` for the write-back / display
    /// consumers that must present a briefly-interrupted night as ONE night (#364).
    public struct BridgedNightGroup: Equatable {
        public let indices: [Int]
        public let gaps: [GapSpan]
        public struct GapSpan: Equatable {
            public let start: Int, end: Int
            public init(start: Int, end: Int) { self.start = start; self.end = end }
        }
        public init(indices: [Int], gaps: [GapSpan]) { self.indices = indices; self.gaps = gaps }
    }

    /// EVERY bridged group over `blocks` — the same two-tier bridge `mainNightGroupIndices` applies
    /// (#561 short-wake + #861 overnight night-tail), WITHOUT the winner pick, so the Health
    /// write-back and the sleep screens group ALL nights exactly as the day totals do. Each group's
    /// `gaps` are the seams between consecutive bridged fragments (empty when fragments touch or
    /// overlap) — folded in as `wake` by the consumers. Groups ordered by start; indices are into
    /// the ORIGINAL array, ascending. Pure + deterministic; Kotlin twin `bridgedNightGroups`. (#364)
    public static func bridgedNightGroups(_ blocks: [NightBlock], offsetSec: Int) -> [BridgedNightGroup] {
        guard !blocks.isEmpty else { return [] }
        let order = blocks.indices.sorted { blocks[$0].start < blocks[$1].start }
        let bridgeS = gapBridgeMaxMin * 60
        let nightTailBridgeS = nightTailBridgeMaxMin * 60
        var bridged: [NightBlock] = []
        var groups: [[Int]] = []
        var gaps: [[BridgedNightGroup.GapSpan]] = []
        for idx in order {
            let b = blocks[idx]
            if let last = bridged.last {
                let gap = b.start - last.end
                let bridges = gap >= 0
                    && (gap < bridgeS
                        || (gap < nightTailBridgeS && isOvernightOnset(b.start, offsetSec: offsetSec)))
                if bridges {
                    if gap > 0 {
                        gaps[gaps.count - 1].append(.init(start: last.end, end: b.start))
                    }
                    bridged[bridged.count - 1] = NightBlock(start: last.start, end: max(last.end, b.end))
                    groups[groups.count - 1].append(idx)
                    continue
                }
                // A CONTAINED fragment (negative gap) still belongs to the night it sits inside.
                if gap < 0 {
                    bridged[bridged.count - 1] = NightBlock(start: last.start, end: max(last.end, b.end))
                    groups[groups.count - 1].append(idx)
                    continue
                }
            }
            bridged.append(b)
            groups.append([idx])
            gaps.append([])
        }
        return zip(groups, gaps).map { BridgedNightGroup(indices: $0.sorted(), gaps: $1) }
    }
```

  **CAREFUL — byte-identity check before refactoring `mainNightGroupIndices`:** the existing loop treats `gap < 0` via `gap >= 0 &&` → a contained fragment does NOT bridge there and starts its own bridged span. Verify against the #561 golden tests what the current behaviour is for overlapping fragments; if the existing suite pins "negative gap → separate group", DROP the `gap < 0` containment branch above and emit a `GapSpan` only when `gap > 0` (matching `testContainedFragmentProducesNoGap` would then need `[[0],[1]]` — adjust that one test to pin the ACTUAL legacy semantics). The refactored `mainNightGroupIndices` becomes:

```swift
    public static func mainNightGroupIndices(_ blocks: [NightBlock], offsetSec: Int,
                                             habitualMidsleepSec: Int? = nil) -> [Int]? {
        guard !blocks.isEmpty else { return nil }
        let all = bridgedNightGroups(blocks, offsetSec: offsetSec)
        let bridgedSpans = all.map { g -> NightBlock in
            let s = g.indices.map { blocks[$0].start }.min() ?? 0
            let e = g.indices.map { blocks[$0].end }.max() ?? 0
            return NightBlock(start: s, end: e)
        }
        guard let winner = mainNightIndex(bridgedSpans, offsetSec: offsetSec,
                                          habitualMidsleepSec: habitualMidsleepSec) else { return nil }
        return all[winner].indices
    }
```

  Only perform this refactor if the FULL StrandAnalytics suite stays green; otherwise keep the original body and have `bridgedNightGroups` be a sibling (duplicated loop, one comment cross-referencing) — byte-identity of the pick outranks DRY here.

- [ ] **Step 4: Run** — `swift test --package-path Packages/StrandAnalytics` → ALL green (new + #561/#861 goldens).
- [ ] **Step 5: Commit** — `feat(sleep): bridgedNightGroups — the #561 bridge over EVERY night, with wake seams (#364)`

---

### Task 2: Kotlin analytics twin — `bridgedNightGroups`

**Files:**
- Modify: `android/app/src/main/java/com/noop/analytics/SleepStageTotals.kt` (after `bridgeAdjacent`, ~line 246)
- Test: `android/app/src/test/java/com/noop/analytics/SleepStageTotalsTest.kt` (append; file exists)

**Interfaces (produces):**

```kotlin
data class BridgedNightGroup(val indices: List<Int>, val gaps: List<Pair<Long, Long>>)
fun bridgedNightGroups(blocks: List<NightBlock>, offsetSec: Long): List<BridgedNightGroup>
```

- [ ] **Step 1: Transcribe the implementation** — same loop as Swift (Long timestamps), same doc comment marking it the Swift twin, same containment decision as resolved in Task 1 Step 3. Refactor Kotlin `mainNightGroupIndices` the same way ONLY if the Kotlin golden tests are also confirmed green on CI at the end; otherwise sibling.
- [ ] **Step 2: Transcribe the tests** — same seven cases, same fixture timestamps (`1_767_312_000L`), same expected indices/gaps, JUnit4 `assertEquals`. Local red/green is impossible (no JVM toolchain) — parity with the Swift twin (which DID fail-then-pass) is the evidence; fork Android CI at Task 8 is the executable check. Note this deviation in the PR.
- [ ] **Step 3: Commit** — `feat(sleep): kotlin bridgedNightGroups twin (#364)`

---

### Task 3: StrandImport — `HealthWriteback.mergedSleepPlan`

**Files:**
- Modify: `Packages/StrandImport/Sources/StrandImport/HealthWriteback.swift`
- Test: `Packages/StrandImport/Tests/StrandImportTests/HealthWritebackTests.swift` (exists as the stageIntervals suite — append; if the file is named differently, `grep -rln stageIntervals Packages/StrandImport/Tests`)

**Interfaces:**
- Consumes: existing `stageIntervals`, `StageInterval`, `StageKind`.
- Produces:

```swift
public enum HealthWriteback {
    // StageKind gains: case unspecified   (bridge maps it to .asleepUnspecified)

    public struct SleepFragment: Equatable {
        public let startTs: Int            // immutable detected key
        public let effectiveStartTs: Int   // edited onset when present
        public let endTs: Int
        public let stagesJSON: String?
        public init(startTs: Int, effectiveStartTs: Int, endTs: Int, stagesJSON: String?)
    }
    public struct MergedSleepEntry: Equatable {
        public let keyStartTs: Int        // group representative = earliest fragment's startTs
        public let spanStart: Int         // earliest effectiveStartTs
        public let spanEnd: Int           // latest endTs
        public let intervals: [StageInterval]  // fragments' stages (unspecified when undecodable) + wake seams
        public let allKeyStartTs: [Int]   // every fragment's startTs — the delete-key set
    }
    /// `groups`: fragments already grouped by `SleepStageTotals.bridgedNightGroups` (each inner
    /// array ascending by effectiveStartTs).
    public static func mergedSleepPlan(groups: [[SleepFragment]]) -> [MergedSleepEntry]
}
```

- [ ] **Step 1: Write the failing tests** (append to the writeback suite)

```swift
    // MARK: - mergedSleepPlan (#364 night-stitch)

    private func frag(_ start: Int, _ end: Int, stages: String? = nil, eff: Int? = nil) -> HealthWriteback.SleepFragment {
        .init(startTs: start, effectiveStartTs: eff ?? start, endTs: end, stagesJSON: stages)
    }
    private func stagesJSON(_ segs: [(Int, Int, String)]) -> String {
        "[" + segs.map { "{\"start\":\($0.0),\"end\":\($0.1),\"stage\":\"\($0.2)\"}" }.joined(separator: ",") + "]"
    }

    func testMergedPlanFoldsTwoFragmentsWithWakeSeam() {
        let t = 1_767_312_000
        let a = frag(t, t + 7_200, stages: stagesJSON([(t, t + 7_200, "light")]))
        let b = frag(t + 7_200 + 960, t + 14_400, stages: stagesJSON([(t + 7_200 + 960, t + 14_400, "deep")]))
        let plan = HealthWriteback.mergedSleepPlan(groups: [[a, b]])
        XCTAssertEqual(plan.count, 1)
        let e = plan[0]
        XCTAssertEqual(e.keyStartTs, t)
        XCTAssertEqual(e.spanStart, t)
        XCTAssertEqual(e.spanEnd, t + 14_400)
        XCTAssertEqual(e.allKeyStartTs, [t, t + 7_200 + 960])
        // The seam sits EXACTLY on [prev.end, next.effectiveStart] as .awake.
        XCTAssertTrue(e.intervals.contains(.init(start: t + 7_200, end: t + 7_200 + 960, kind: .awake)))
        XCTAssertEqual(e.intervals.first?.kind, .light)
        XCTAssertEqual(e.intervals.last?.kind, .deep)
    }

    func testMergedPlanSingleFragmentMatchesLegacyShape() {
        let t = 1_767_312_000
        let a = frag(t, t + 7_200, stages: stagesJSON([(t, t + 3_600, "light"), (t + 3_600, t + 7_200, "rem")]))
        let e = HealthWriteback.mergedSleepPlan(groups: [[a]])[0]
        XCTAssertEqual(e.keyStartTs, t)
        XCTAssertEqual(e.allKeyStartTs, [t])
        XCTAssertEqual(e.intervals, HealthWriteback.stageIntervals(stagesJSON: a.stagesJSON,
                                                                   sessionStart: t, sessionEnd: t + 7_200))
    }

    func testMergedPlanUnstagedFragmentsDegradeToUnspecifiedPlusSeam() {
        let t = 1_767_312_000
        let a = frag(t, t + 7_200)                       // no stagesJSON
        let b = frag(t + 7_200 + 960, t + 14_400)        // no stagesJSON
        let e = HealthWriteback.mergedSleepPlan(groups: [[a, b]])[0]
        XCTAssertEqual(e.intervals, [
            .init(start: t, end: t + 7_200, kind: .unspecified),
            .init(start: t + 7_200, end: t + 7_200 + 960, kind: .awake),
            .init(start: t + 7_200 + 960, end: t + 14_400, kind: .unspecified),
        ])
    }

    func testMergedPlanEditedOnsetMovesSpanButNotKey() {
        let t = 1_767_312_000
        let a = frag(t, t + 7_200, eff: t + 600)     // user moved bedtime 10 min later
        let e = HealthWriteback.mergedSleepPlan(groups: [[a]])[0]
        XCTAssertEqual(e.keyStartTs, t)              // immutable key
        XCTAssertEqual(e.spanStart, t + 600)         // edited onset drives the span
    }
```

- [ ] **Step 2: Run to verify failure** — `swift test --package-path Packages/StrandImport --filter HealthWriteback` → FAIL (`SleepFragment` unresolved).
- [ ] **Step 3: Implement** — add `case unspecified` to `StageKind`; add the two structs; implement:

```swift
    /// Fold one bridged night group (#364) into a single write-back entry: the span, the merged
    /// stage timeline (each fragment's decoded stages, or one honest `.unspecified` block for a
    /// fragment with no timing, with every inter-fragment seam as `.awake`), the representative
    /// immutable key, and the COMPLETE per-fragment key set so a night previously exported as two
    /// entries deletes both before the merged write.
    public static func mergedSleepPlan(groups: [[SleepFragment]]) -> [MergedSleepEntry] {
        var out: [MergedSleepEntry] = []
        for group in groups where !group.isEmpty {
            let frags = group.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
            var intervals: [StageInterval] = []
            var prevEnd: Int? = nil
            for f in frags {
                guard f.endTs > f.effectiveStartTs else { continue }
                if let p = prevEnd, f.effectiveStartTs > p {
                    intervals.append(StageInterval(start: p, end: f.effectiveStartTs, kind: .awake))
                }
                let stages = stageIntervals(stagesJSON: f.stagesJSON,
                                            sessionStart: f.effectiveStartTs, sessionEnd: f.endTs)
                if stages.isEmpty {
                    intervals.append(StageInterval(start: f.effectiveStartTs, end: f.endTs, kind: .unspecified))
                } else {
                    intervals.append(contentsOf: stages)
                }
                prevEnd = max(prevEnd ?? f.endTs, f.endTs)
            }
            guard let first = frags.first, let spanEnd = frags.map(\.endTs).max(), spanEnd > first.effectiveStartTs
            else { continue }
            out.append(MergedSleepEntry(
                keyStartTs: frags.map(\.startTs).min() ?? first.startTs,
                spanStart: first.effectiveStartTs,
                spanEnd: spanEnd,
                intervals: intervals,
                allKeyStartTs: frags.map(\.startTs).sorted()))
        }
        return out
    }
```

- [ ] **Step 4: Run** — full `swift test --package-path Packages/StrandImport` green (existing stageIntervals suite must not regress from the `StageKind` addition — it's additive).
- [ ] **Step 5: Commit** — `feat(sleep): mergedSleepPlan — one write-back entry per bridged night, seams as wake (#364)`

---

### Task 4: iOS consumer — `HealthKitBridge.writeSleep` groups by bridged night

**Files:**
- Modify: `StrandiOS/Health/HealthKitBridge.swift:600-655` (`writeSleep`)

**Interfaces:** consumes `SleepStageTotals.bridgedNightGroups` + `HealthWriteback.mergedSleepPlan`. Check the file's imports; add `import StrandAnalytics` if missing (the app target links it — SleepView already imports it).

- [ ] **Step 1: Rewrite `writeSleep`** (doc comment updated to describe the one-entry-per-night shape and the #364 rationale):

```swift
    private func writeSleep(sessions: [CachedSleepSession]) async throws {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
              store.authorizationStatus(for: type) == .sharingAuthorized else { return }
        // Group fragments into bridged nights (#364): a night split by a brief mid-night wake exports
        // as ONE .inBed span with the gap as an in-hypnogram wake segment — matching what the daily
        // totals already score (#561) and what Oura / Apple Watch write. Naps never bridge.
        let blocks = sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) }
        let offsetSec = TimeZone.current.secondsFromGMT()
        let groups = SleepStageTotals.bridgedNightGroups(blocks, offsetSec: offsetSec).map { g in
            g.indices.map { i -> HealthWriteback.SleepFragment in
                let s = sessions[i]
                return .init(startTs: s.startTs, effectiveStartTs: s.effectiveStartTs,
                             endTs: s.endTs, stagesJSON: s.stagesJSON)
            }
        }
        var samples: [HKCategorySample] = []
        var keys: [String] = []
        for entry in HealthWriteback.mergedSleepPlan(groups: groups) {
            let key = "noop:\(noopDeviceId):sleep:\(entry.keyStartTs)"
            let meta = [HKMetadataKeyExternalUUID: key]
            // Delete keys cover EVERY fragment, so a night previously written as two entries fully
            // clears when it becomes one (the absorbed fragment's old key would otherwise orphan).
            keys.append(contentsOf: entry.allKeyStartTs.map { "noop:\(noopDeviceId):sleep:\($0)" })
            samples.append(HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                                            start: Date(timeIntervalSince1970: TimeInterval(entry.spanStart)),
                                            end: Date(timeIntervalSince1970: TimeInterval(entry.spanEnd)),
                                            metadata: meta))
            for seg in entry.intervals {
                let value: HKCategoryValueSleepAnalysis
                switch seg.kind {
                case .awake:       value = .awake
                case .light:       value = .asleepCore
                case .deep:        value = .asleepDeep
                case .rem:         value = .asleepREM
                case .unspecified: value = .asleepUnspecified
                }
                samples.append(HKCategorySample(
                    type: type, value: value.rawValue,
                    start: Date(timeIntervalSince1970: TimeInterval(seg.start)),
                    end: Date(timeIntervalSince1970: TimeInterval(seg.end)),
                    metadata: meta))
            }
        }
        guard !samples.isEmpty else { return }
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: keys),
        ])
        _ = try? await store.deleteObjects(of: type, predicate: pred)
        try await store.save(samples)
    }
```

- [ ] **Step 2: Compile** — `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` (HealthKitBridge is iOS-only). Expected: BUILD SUCCEEDED.
- [ ] **Step 3: Commit** — `fix(health): export a wake-split night as ONE Apple Health entry with the gap as awake (#364)`

---

### Task 5: macOS/iOS display — gap-wake segments + awake minutes in `SleepView.mergeDay`

**Files:**
- Modify: `Strand/Screens/SleepView.swift:1981-2019` (`mergeDay`)

- [ ] **Step 1: Splice the seams** — inside `mergeDay`, after the per-fragment loop and before `guard stages.asleep > 0`:

```swift
        // #364: the inter-fragment wake seams belong to the night — draw them as wake segments and
        // count them as awake minutes, so the hero hypnogram has no hole and the card's minutes match
        // the day totals (which already add the gap via interFragmentAwakeSeconds, #777/#705).
        let ordered = Array(group)
        for (prev, next) in zip(ordered, ordered.dropFirst()) {
            let gapStart = prev.endTs, gapEnd = next.effectiveStartTs
            guard gapEnd > gapStart else { continue }
            stages.awake += Double(gapEnd - gapStart) / 60.0
            segs.append(SleepInterval(stage: .awake, start: TimeInterval(gapStart), end: TimeInterval(gapEnd)))
        }
```

  **Pin the exact `SleepInterval` init at implementation time** (`grep -n "struct SleepInterval" Strand/`): match its stage enum case (`.awake` vs `.wake`) and start/end types (TimeInterval vs Int) to the real definition — the snippet above assumes `TimeInterval`; adjust to whatever `decodeSegments` appends. `ordered` must use the SAME `group` (post-stub-drop) the fragment loop used. Gap uses `prev.endTs` (not running max) because group fragments are ascending and non-overlapping in practice; if Task 1 resolved containment as "bridged", guard with `guard gapEnd > gapStart` (already present) so contained fragments emit nothing.
- [ ] **Step 2: Check the in-bed subtitle** — find `stageCard`'s subtitle source (~line 635). If it renders `night.stages.total`, the gap now counts (correct — matches engine). If it renders the onset→wake span, it already included the gap. Either way NO further edit; just confirm which and note it in the PR body.
- [ ] **Step 3: Compile BOTH apps** — `xcodebuild -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` AND the NOOPiOS build from Task 4 Step 2 (SleepView is shared).
- [ ] **Step 4: Commit** — `feat(sleep): draw the night's wake seams in the hero hypnogram + count them as awake (#364)`

---

### Task 6: Android write path — grouping in `HealthExportPlan` + absorbed-id deletion in `HealthConnectWriter`

**Files:**
- Modify: `android/app/src/main/java/com/noop/ingest/HealthExportPlan.kt` (sleep section, lines 77-128)
- Modify: `android/app/src/main/java/com/noop/ingest/HealthConnectWriter.kt` (`writeSleep`, ~lines 199-227)
- Test: `android/app/src/test/java/com/noop/ingest/HealthExportPlanTest.kt` (append)

**Interfaces:**

```kotlin
// SleepInput gains the immutable key / effective-onset split (iOS parity):
data class SleepInput(val keyStartTs: Long, val startTs: Long, val endTs: Long, val stagesJSON: String?)
data class SleepPlan(
    val clientId: String,          // "noop-sleep-<earliest keyStartTs>"
    val startSec: Long, val endSec: Long,
    val stages: List<StagePlan>,   // fragments' AWAKE/SLEEPING plans + seams as StagePlan(asleep=false)
    val absorbedClientIds: List<String>,  // non-representative fragments' old ids → writer deletes
)
fun sleepSessions(sessions: List<SleepInput>, nowSec: Long, offsetSec: Long): List<SleepPlan>
```

- [ ] **Step 1: Write the JVM tests** (append to `HealthExportPlanTest.kt`; same fixture numbers as Task 3):

```kotlin
    @Test
    fun sleepPlanFoldsBridgedFragmentsWithAwakeSeam() {
        val t = 1_767_312_000L
        val a = HealthExportPlan.SleepInput(t, t, t + 7_200,
            """[{"start":$t,"end":${t + 7_200},"stage":"light"}]""")
        val b = HealthExportPlan.SleepInput(t + 8_160, t + 8_160, t + 14_400,
            """[{"start":${t + 8_160},"end":${t + 14_400},"stage":"deep"}]""")
        val plans = HealthExportPlan.sleepSessions(listOf(a, b), nowSec = t + 86_400, offsetSec = 0)
        assertEquals(1, plans.size)
        val p = plans[0]
        assertEquals("noop-sleep-$t", p.clientId)
        assertEquals(t, p.startSec); assertEquals(t + 14_400, p.endSec)
        assertEquals(listOf("noop-sleep-${t + 8_160}"), p.absorbedClientIds)
        assertTrue(p.stages.contains(HealthExportPlan.StagePlan(t + 7_200, t + 8_160, asleep = false)))
    }

    @Test
    fun napStaysItsOwnPlanWithNoAbsorbedIds() {
        val t = 1_767_312_000L
        val night = HealthExportPlan.SleepInput(t, t, t + 21_600, null)
        val nap = HealthExportPlan.SleepInput(t + 50_400, t + 50_400, t + 54_000, null)
        val plans = HealthExportPlan.sleepSessions(listOf(night, nap), nowSec = t + 86_400, offsetSec = 0)
        assertEquals(2, plans.size)
        assertTrue(plans.all { it.absorbedClientIds.isEmpty() })
    }

    @Test
    fun editedOnsetMovesSpanButClientIdStaysImmutable() {
        val t = 1_767_312_000L
        val edited = HealthExportPlan.SleepInput(t, t + 600, t + 7_200, null)
        val p = HealthExportPlan.sleepSessions(listOf(edited), nowSec = t + 86_400, offsetSec = 0)[0]
        assertEquals("noop-sleep-$t", p.clientId)
        assertEquals(t + 600, p.startSec)
    }
```

- [ ] **Step 2: Implement** — group via `com.noop.analytics.SleepStageTotals.bridgedNightGroups` (map inputs to `NightBlock(startTs, endTs)` — effective onset), fold each group: seams → `StagePlan(gapStart, gapEnd, asleep = false)`; unstaged fragments contribute no stages (HC convention unchanged); clientId from the earliest fragment's `keyStartTs`; absorbedClientIds = the rest. Update `writeSleep` call site: map `SleepInput(it.startTs, it.effectiveStartTs ?: it.startTs, it.endTs, it.stagesJSON)` — pin the actual Room entity's adjusted-onset field name (`grep -n "effectiveStart\|startTsAdjusted" android/app/src/main/java/com/noop/data/` at implementation). After `insertChunked`, delete absorbed ids:

```kotlin
        val absorbed = plans.flatMap { it.absorbedClientIds }
        if (absorbed.isNotEmpty()) {
            client.deleteRecords(SleepSessionRecord::class, recordIdsList = emptyList(), clientRecordIdsList = absorbed)
        }
```

- [ ] **Step 3: Commit** — `fix(health): android — one Health Connect session per bridged night, absorbed fragments deleted (#364)`

---

### Task 7: Android display — seams in `selectNight`

**Files:**
- Modify: `android/app/src/main/java/com/noop/ui/SleepScreen.kt:2827-2851` (`groupSegments` / `sumGroupStages` / `groupInBedMin`)

- [ ] **Step 1: Splice seams into `groupSegments`** — after the flatMap, insert a `PersistedSegment(stage = "wake", start = prev.endTs, end = next.effectiveStartTs)` between consecutive `heroGroup` fragments (guard `end > start`; pin `PersistedSegment`'s exact constructor by grepping its definition). Add the same seam minutes to `sumGroupStages`'s awake figure and to `groupInBedMin` (gaps now count — matching the engine's `interFragmentAwakeSeconds` day totals and iOS's span-based in-bed).
- [ ] **Step 2: Commit** — `feat(sleep): android — wake seams in the hero hypnogram + gap-inclusive minutes (#364)`

---

### Task 8: Verification sweep

- [ ] `swift test` — StrandAnalytics, StrandImport (and StrandDesign/WhoopStore if touched — they shouldn't be).
- [ ] `xcodegen generate && xcodebuild` — `Strand` (macOS) AND `NOOPiOS` (iOS), both `CODE_SIGNING_ALLOWED=NO build`.
- [ ] Push branch to fork; dispatch `android.yml` (assemble + JVM tests — covers Tasks 2/6 red-free) and `app-build.yml` (both app targets on clean `project.yml`).
- [ ] `swift-packages.yml` runs automatically on the PR.

### Task 9: PR

- [ ] One PR to `ryanbr/noop` from `vishk23:feat/sleep-night-stitch-364`, title `fix(sleep): present a wake-split night as one night — export + hypnogram, both platforms (#364)`. Body: Ryan's recommended shape restated (display-time via the existing bridge, `gapBridgeMaxMin` reused, one `.inBed`/`SleepSessionRecord` per bridged night, seams as wake), the dedup 2→1 rule, the in-bed/awake minutes now matching the engine's #777/#705 totals, Proposal 2 deferred, verification section (swift tests, both app builds, fork CI links). No attribution.

### Task 10: Sync local main

- [ ] `git merge feat/sleep-night-stitch-364` into VK's `main` (keeps his device builds current); run `swift test` on the two packages post-merge.
