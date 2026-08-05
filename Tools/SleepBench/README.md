# SleepBench — an offline scoring harness for the sleep stagers

Replays `SleepStager` (V1) and `SleepStagerV2` over real recorded nights held in a NOOP SQLite
database and scores each hypnogram against every independent reference that database carries. It
exists so a claim about a staging recipe ("kappa went up", "wake is over-called") can be **measured**
rather than asserted.

The harness is read-only (`SQLITE_OPEN_READONLY` + `immutable=1`), takes its database path as a
command-line argument, and never writes anything back. **No health data lives in this repository and
none may be committed.**

## Running it

```bash
cd Tools/SleepBench && swift build
```

```bash
.build/debug/sleepbench --db /path/to/COPY-of-whoop.sqlite --device my-whoop-noop --stream-device my-whoop
```

| Flag | Default | Meaning |
|---|---|---|
| `--db` | *(required)* | Path to a **copy** of a NOOP SQLite database |
| `--device` | `my-whoop-noop` | The `sleepSession.deviceId` whose nights are scored |
| `--stream-device` | `my-whoop` | The `deviceId` the raw streams are stored under |
| `--pad` | `3600` | Seconds of stream padding either side of each session |
| `--csv` | *(none)* | Also write a per-night CSV |

**Pass a COPY. Never point this at a device's live database.** `--device` and `--stream-device` are
separate arguments because they genuinely differ in a real database: session rows carry the app's own
device identity while decoded streams carry the strap's.

## What it reports

| Section | Question it answers |
|---|---|
| **0. Ground-truth provenance** | How many rows are `userEdited`, and how many of those carry a `stagelock` cursor (i.e. human-authored *stages*, not just human-corrected *bounds*) |
| **A. Which stager produced the stored nights?** | Replays V1 and V2 over the identical window and compares epoch-for-epoch against `stagesJSON`, identifying the live recipe |
| **B. Accuracy vs the wearer's manual restages** | Wake-minute error and 4-class / sleep-wake agreement against reference (a) |
| **C. Agreement with the strap's own band `sleep_state`** | Sleep-vs-wake agreement against reference (b), the v18 `@81` high nibble — the strap's own verdict, not a re-derivation of NOOP's |
| **D. Does the wake over-call track overnight HR?** | Tests the standing "supplement HR" inference, both on human-labelled nights and on the far larger band-disputed-wake set |
| **E. Per-stage fraction calibration** | The guard kappa does **not** provide — how much of the night each recipe spends at each stage, as a signed bias in percentage points |
| **F. First-REM latency** | A stage-*timing* property kappa is also blind to |
| **G. Per-night detail** | Every session, one row each |

Section E exists because of a specific failure. PR #348 fitted the stager to DREAMT, raised kappa on
all three benchmarks with a held-out gap of −0.027, and was reverted 48 hours later by PR #437 for
re-scoring a healthy night from 6% to 23% awake. The revert's own words: *"kappa doesn't guard
stage-fraction calibration."*

## The two references, and what each is worth

**(a) The wearer's manual restages.** `userEdited = 1` rows. A `userEdited` row alone does **not**
prove human stage labels: the local editor corrects bed/wake *bounds* and then re-derives the
hypnogram from raw, so its stages are machine output over a human-chosen window. Only a row carrying
a `stagelock:<deviceId>:<startTs>` cursor had its stages authored directly, via the cloud
`edit_sleep_stages` path. Section B additionally excludes an edited night whose stored hypnogram is a
byte-exact V2 replay — scoring V2 against a row V2 itself wrote is self-comparison.

Section E deliberately uses the `stagelock` set rather than section B's set: B's exclusion is
version-dependent by construction, so a night can enter or leave it when the recipe changes, silently
swapping the denominator underneath a before/after comparison. The `stagelock` set comes from
`cursors` and does not move when the recipe moves.

**(b) The strap's own band `sleep_state`.** Carries no light/deep/REM, so it is a sleep-vs-wake
comparison only. STRICT maps band 2 → sleep and band 0/3 → wake, and **excludes** band 1 ("still",
genuinely ambiguous).

## Stage label vocabulary — read this before touching a comparison

`sleepSession.stagesJSON` has several producers and they do **not** agree on how to spell wake:

| Producer | Spells wake |
|---|---|
| `SleepStager` / `SleepStagerV2` (on device) | `"wake"` — V2 renames its internal `"awake"` on the way out |
| `OuraHypnogram.decode`, `FitbitExportParser` | `"wake"` |
| the noop-cloud server's `sleepStage` enum | `"awake"` |

`CloudEditApplier.mapServerStage` folds `"awake"` → `"wake"`, but **only when a cloud stage edit is
applied onto a device**. A database pulled off a phone is therefore uniformly `"wake"`; a corpus
assembled from the noop-cloud mirror carries `"awake"` on exactly the stage-locked nights this
harness uses as its human reference.

Comparing a stage against a bare `"wake"` literal is correct for one producer and silently wrong for
the other — it files every `"awake"` epoch as **sleep**, biasing wake down and sleep up in precisely
the quantities this harness exists to measure. Worse, an `"awake"` reference label matches no class in
`stageOrder`, so `Confusion.add` used to **drop** those epochs from the matrix entirely: they left the
denominator instead of showing up as disagreement.

Measured on one real 564-minute stage-locked night (119.5 reference wake minutes), stored under both
spellings with identical streams:

```
                              "awake"      "wake"
  truth wake minutes                0   ->   120
  V2 wake-minute error              0   ->  -119.5   (sign flip)
  E.1 wake stage bias         0.00 pp   ->  -21.19 pp
  E.0 4-class kappa             0.145   ->   0.091
  E.0 sleep/wake accuracy      100.0%   ->   78.8%
  E.0 epochs scored               889   ->   1128    (239 epochs had been dropped)
  C  stored kappa               0.000   ->   0.029
  F  human first-REM latency    138.0   ->   131.5 min
```

**The rule:** never compare a stage against a bare literal. Use
`SleepStageVocabulary.isWake(_:)` / `.canonical(_:)` (`Packages/StrandAnalytics`), which folds both
spellings and any case. The harness canonicalises once at the DB load point (`DB.swift`) and once at
epoch expansion (`epochLabels`), so every label array downstream is canonical by construction; the
local `isWake` helper in `Metrics.swift` is the predicate every remaining comparison goes through.

`SleepStageTotals` and `HealthWriteback` deliberately keep their own exact-match folds
(`case "wake", "awake":`) rather than calling the shared helper: their Kotlin twins match exactly too,
and the minutes they produce are stored and cross the `.noopbak` boundary, so case-folding there would
start counting a `"Wake"` that today contributes nothing — a silent, one-platform change to stored
values. Leave them exact-match unless the Kotlin twin moves in the same PR.

## Testing

```bash
cd Tools/SleepBench && swift test
```

The scoring primitives are pure functions over 30-second label arrays, so the suite needs **no
database, no health data and no `--db` argument**.

> **CI does not cover this directory.** `swift-packages.yml` runs on `Packages/**` only, and
> `app-build.yml` is disabled by default — nothing under `Tools/` is built or tested by any default CI
> job. That is why the stage-vocabulary rule itself lives in `Packages/StrandAnalytics` (where
> `SleepStageVocabulary.swift` and its tests *are* CI-gated) rather than here. If you change this
> harness, run `swift test` yourself.

## Known limitations

- **Imported nights are not scorable.** `stagesJSON` has two shapes: the segment array
  `[{start,end,stage}]` (on-device stager, Oura, Fitbit, cloud stage edits) and the minute dict
  `{"awake":N,"light":N,"deep":N,"rem":N}` (Apple Health / WHOOP CSV / Xiaomi importers). The harness
  decodes only the former; the dict shape currently decodes to `[]` and the night is then scored as
  **100% wake**. Latent for the default `--device my-whoop-noop`, since imported nights carry a
  different `deviceId` — but `sleepbench --device apple-health` would report a confidently wrong
  all-wake corpus with no warning.
- **Section D is underpowered on human-labelled nights**, which span only a narrow HR band by
  construction. The band-disputed-wake test in the same section needs no human labels and covers a far
  wider HR range; prefer it.
- **`bandVetoMirror` is a transcription**, not the shipped code. `SleepStager.applyBandStateWakeVeto`
  is `internal` and unreachable from this executable. `SleepStagerTests` pins the real implementation.

## Related

- `docs/ANALYTICS.md` — what the stagers actually compute
- `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStageVocabulary.swift` — the shared fold
- `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStageTotals.swift` — both `stagesJSON` shapes
