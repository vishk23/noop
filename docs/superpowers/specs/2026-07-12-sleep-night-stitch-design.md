# Sleep night-stitch: present a wake-split night as one night — design

**Date:** 2026-07-12
**Issue:** [#364](https://github.com/ryanbr/noop/issues/364)
**Scope:** Both platforms. Swift core in `Packages/StrandAnalytics` (`SleepStageTotals`) + two
app-target consumers (`StrandiOS/Health/HealthKitBridge.swift`, `Strand/Screens/SleepView.swift`);
Kotlin twins in `android/…/analytics/SleepStageTotals.kt` + `HealthConnectWriter.kt` +
`ui/SleepScreen.kt`. Detector and stored sessions are **untouched** — this is presentation only.

## Problem

When the sleep detector sees a sustained mid-night wake it ends the session and starts a new one, so
one night reaches storage as two `SleepSession` rows. A 16-minute wake at ~3 AM produces a main block
plus a second fragment. The daily totals are already correct — `SleepStageTotals.mainNightGroupIndices`
(#561/#525/#861) bridges fragments separated by a gap `< gapBridgeMaxMin` (60 min, plus a 90-min
night-tail bridge for overnight-onset fragments) into one **main-night group** for scoring. But two
consumers still read the raw split sessions:

- **Apple Health write-back** (`HealthKitBridge.writeSleep`) iterates raw sessions → one `.inBed`
  HealthKit entry per fragment → the reported two-entry export.
- **Sleep screen** (`SleepView` / Android `SleepScreen`) surfaces the second fragment as its own card
  instead of a wake segment inside the one night.

Prior art (WHOOP, Oura, Apple Watch) renders one night with the wake folded in as awake time; only
naps / genuinely separate sleeps split.

## Approach

One shared grouping/merge primitive in the analytics package; four thin consumers. The
correctness-critical logic — which fragments are one night, and the merged stage timeline with the
wake gap — lives where `swift test` / JVM tests cover it. Consumers render/emit only.

Rejected: (B) group inline in each consumer — duplicates the bridge across four app-target surfaces
with no CI, guaranteed drift; (C) merge at the detector/storage layer — breaks sleep-time edits
(#318), union dedup, and the Apple Health round-trip. Ryan ruled out (C) explicitly on #364.

## The primitive

`mainNightGroupIndices` today builds bridged groups then scores and returns only the **winning** main
night. The consumers need **every** night grouped (main night merged, naps standalone, prior nights
merged), so the grouping pass ([`SleepStageTotals.swift:333-356`](../../../Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStageTotals.swift)) is extracted into a reusable, pure function:

```
groupBridgedNights(sessions) -> [DisplayedNight]
```

where each `DisplayedNight` carries only **pure grouping/time data — no stage decoding** (so the
grouping layer gains no dependency on the stage vocabulary or the HealthKit decoder):
- `fragmentIndices: [Int]` — indices into the input, ascending;
- `spanStart / spanEnd` — earliest `effectiveStartTs` → latest `endTs` across the group;
- `gapWakes: [(start, end)]` — the inter-fragment seams, one per gap (`start = prevFragment.end`,
  `end = nextFragment.start`). These, folded in as `wake`, are the *only* new stage content a merged
  night introduces; each fragment's own decoded stages are unchanged.

Grouping uses the **same** `gapBridgeMaxMin` + night-tail overnight rule the scorer already applies —
no new threshold — so display/export group *consistently with the corrected daily totals*. Naps and
genuinely separate sleeps do not bridge, so they remain their own `DisplayedNight` (own card / own
HealthKit entry). Pure and deterministic; shared verbatim by the Kotlin twin for cross-platform
parity.

The existing `mainNightGroupIndices` is refactored to call `groupBridgedNights` and then score+pick,
so there is exactly one grouping implementation and the #561 tests still pin it.

Assembling a merged night's timeline is then "concatenate each fragment's existing decoded stages,
then splice in `gapWakes`" over `[spanStart, spanEnd]`. For the **write path** this assembly is a pure
helper in `Packages/StrandImport` `HealthWriteback` (reusing the tested `stageIntervals` per-fragment
decoder), so it gets `swift test` coverage. The **display path** does the same interleave in its
hypnogram builder (UI layer, compile-checked). A group whose fragments all lack decoded stages yields
one `asleepUnspecified` span over `[spanStart, spanEnd]` plus the `gapWakes`, exactly as `writeSleep`
degrades today.

## The four consumers

1. **`writeSleep`** (`HealthKitBridge`) — iterate `groupBridgedNights(sessions)` instead of raw
   sessions; one `.inBed` sample over `spanStart→spanEnd` plus one `HKCategorySample` per
   `mergedStages` segment (`wake→.awake`, `light→.asleepCore`, `deep→.asleepDeep`, `rem→.asleepREM`).
2. **`SleepView`** (macOS+iOS, shared) — list `DisplayedNight`s; the secondary fragment renders as a
   wake segment within the night's hypnogram instead of a separate card. The delicate surface: nap
   cards, sleep-time edit/undo (#318), and per-session selection all live here and must keep working —
   naps stay their own `DisplayedNight`, and edit/undo still act on the underlying stored session.
3. **`HealthConnectWriter`** (Android) — twin of #1 (`SleepSessionRecord` + stage records).
4. **`SleepScreen`** (Android Compose) — twin of #2.

## Correctness subtlety: HealthKit dedup across the 2→1 transition

The idempotency key is `noop:<deviceId>:sleep:<startTs>` per session. A night previously written as
**two** entries must not orphan the second when it becomes **one**. So:

- The merged entry's samples are keyed by the group's **representative** `startTs` — the earliest
  fragment's immutable detected onset (not `effectiveStartTs`, so a user edit keeps identity).
- The delete-then-write predicate's `allowedValues` must include **every** fragment's per-`startTs`
  key across all groups (not just the representatives), so a prior per-fragment write is fully
  cleared before the merged write.

Same care on the Health Connect side (its records are keyed analogously).

## Verification

- **Core primitive** — `swift test` (StrandAnalytics) + JVM test (Android `SleepStageTotals`), both in
  default/fork CI. Cases: short-wake bridge merges two fragments into one night with a `wake` gap
  interval at the seam; a nap stays a separate `DisplayedNight`; night-tail overnight bridge; an edited
  `effectiveStartTs` moves `spanStart`; unspecified-stage fragments; a three-fragment night. Assert the
  refactored `mainNightGroupIndices` still returns byte-identical groups (the #561 regression pins).
- **`HealthWriteback` merged-timeline assembly** — the pure write-path helper (concatenate decoded
  fragment stages + splice `gapWakes`, degrade to `asleepUnspecified`) gets `swift test` coverage: the
  seam-`wake` interval sits exactly at `[prevEnd, nextStart]`, stages stay clamped to `[spanStart,
  spanEnd]`, and the multi-fragment delete-key set is complete.
- **Consumers** — app-target Swift (`NOOPiOS` + `Strand` macOS) compiled via on-demand `app-build.yml`;
  Android via fork `android.yml` (the #368 play). HealthKit / Health Connect themselves are not
  unit-testable.

## Deliberately excluded

- **Proposal 2 — motion-aware wake classification** (restless-in-bed vs out-of-bed from
  `gravitySample` / `stepSample`). The gravity stream is too sparse on WHOOP 4.0 to trust (same
  sparse-motion limit behind the 4.0 sleep-staging work), and per the repo's derived-biosignal
  validation standard an unproven per-record signal ships as instrumentation or behind a default-off
  toggle, never as the default. Deferred to an honestly-labelled 5.0/MG follow-up; the 60-min bridge
  already decides "same night" for v1.
- **Detector / stored sessions** — unchanged. Sessions stay split in storage; grouping is read-time.
- **Daily totals / scoring** — already correct via the existing bridge; not touched beyond the
  no-op-preserving `mainNightGroupIndices` refactor.

## Cross-platform parity

`groupBridgedNights` and its `DisplayedNight` output are byte-identical Swift↔Kotlin (same bridge
constants, same tie/order rules, same gap-as-wake construction). The two writers emit the same
one-span-per-night shape; the two sleep screens render the same folded hypnogram. UI is feature-level,
not pixel-level (SwiftUI Charts vs Compose Canvas), per the parity contract.
