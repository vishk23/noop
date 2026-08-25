# Wave 0 — implementation spec

Wave 0 = "wire the rigorous methodology that's already written but disconnected" + near-free honesty fixes. Highest ROI in the program; each item is a caller/flag/framing change, not new math.

## Branch scoping (resolved against #413 / #417)

#413 (`stress-baseline-relative`) touches only `DaytimeStress.swift`; #417 (`readiness-recovery-index`) touches only `RecoveryScorer.swift`. Therefore:

- **Wave 0a — on `main`, independently mergeable.** No dependency on #413/#417.
- **Wave 0b — stacked on #413 + #417, deferred** until they land. Only two items: **S1** (wire `.baselineRelative` into `StressView` — needs #413's `DaytimeStress.ScoringMode.baselineRelative`) and **R8** (decide the dead `Recovery-Index`/`Activity-Balance` scaffolding — lives in #417's `RecoveryScorer`).

This doc specs **Wave 0a**. 0b gets its own spec once #413/#417 merge.

## Discipline for every item

- **TDD**: add/extend a failing test in `Packages/StrandAnalytics/Tests/StrandAnalyticsTests` (or the relevant target) first, then implement.
- **Additive & reversible**: default behavior must not silently change for callers that don't opt in, unless the change IS the fix (SL1, T1) — and then a test pins the new behavior.
- **Build gate**: `swift build`/`swift test` for the `StrandAnalytics` package, then the macOS (`Strand`) build, before commit.
- **Validation**: note the replay/Oura directional check each item should later be run through (harness is a follow-up; the unit test is the gate for landing).

## Wave 0a items

### SL1 — wire `sleepConsistency` into Rest  ·  impact 9.0
- **Gap**: `AnalyticsEngine` Rest builder is called with `sleepConsistency: nil` → `Rest.composite` uses `neutralConsistency = 0.5` (a flat +5.0 on the 0.10 consistency term for every user, every night). `VitalityEngine.sleepConsistency(nightlyHours:)` (1 − CoV of nightly sleep hours, clamped 0–1) already exists and is used by the vitality result, just not by Rest.
- **Files**: `AnalyticsEngine.swift` (the Rest-building entry that defaults `sleepConsistency` nil, ~L305) + its call site(s) in the app layer (`AppModel`/day-processing) that have the nightly-hours history.
- **Approach**: compute `VitalityEngine.sleepConsistency(nightlyHours:)` from the trailing sleep-duration window at the Rest call site and thread it in. When history is too short → keep nil (neutral), and mark the term as calibrating (ties to M6/coverage).
- **Test**: a regular vs irregular nightly-hours window produces a higher vs lower Rest, and an all-equal window yields consistency 1.0 (> neutral), a highly variable window < neutral.
- **Validation**: replay — irregular stretches should drop Rest; well-regular nights barely move.

### T1 — population-anchored, age-floored sleep-need  ·  impact 9.0
- **Gap**: need defaults to a fixed `Rest.defaultNeedHours = 8.0`, and the longitudinal/debt path measures against a **self-referential all-history mean** that drifts toward a chronic under-sleeper's own deficit (inverts the honesty philosophy).
- **Files**: `AnalyticsEngine.Rest` (need constants), the caller that computes/passes `sleepNeedHours`, and the debt/trends need source.
- **Approach**: personal need = population-anchored band (age-floored ~7–9 h) with a personal component learned ONLY from unrestricted nights; never let need collapse below the population floor. One need feeds Rest's duration term AND the debt ledger.
- **Test**: a chronic under-sleeper's computed need stays ≥ the age floor (does not track their deficit down); a normal sleeper's need lands in-band.
- **Validation**: replay — population anchor must *increase* debt for chronic under-sleepers, barely move well-slept users.

### RD1 — promote `HRVReadiness` (log-SWC band) from default-off  ·  impact 4.5
- **Gap**: `ReadinessEngine` default path z-scores **raw, right-skewed ms**; the correct `HRVReadiness` (lnRMSSD smallest-worthwhile-change band) exists but is quarantined/default-off.
- **Files**: `HRVReadiness.swift`, `ReadinessEngine.swift`. Land **together** with the RD2 baseline swap (Wave 1) is ideal, but promoting the log-domain band is a Wave-0 flag/first-class change.
- **Test**: readiness verdict for a given HRV vs baseline matches the log-SWC band, not the raw-ms z; skewed inputs no longer misstate tail rarity.
- **Validation**: replay vs Oura readiness; directional (should not flip well-recovered days).

### R4 — fix `ChargeDrivers` self-contradictory doc  ·  impact 6.0 (near-free honesty)
- **Files**: `ChargeDrivers.swift`. Documentation/transparency only — reconcile the drifted comment with the actual math. No behavior change; a doc/comment test if one exists, else visual diff.

### R7 — give Apple-Watch SDNN its own baseline config  ·  impact 6.0
- **Gap**: SDNN (Apple-Watch path) is baselined with RMSSD-tuned parameters.
- **Files**: `Baselines.swift` config + `WatchRecovery.swift` / `HRVAnalyzer` consumers. On `main` (not in #417's `RecoveryScorer`), so 0a-clean.
- **Test**: SDNN baseline uses its own center/spread config distinct from RMSSD.

### RD-confidence — surface `ScoreConfidence`/warm-up on the Readiness card  ·  impact 6.0
- **Gap**: Readiness estimates its SD denominator off as few as 7 nights with no width shown; `Charge` already carries `ScoreConfidence`. Reuse it.
- **Files**: `ReadinessEngine.swift` (+ the readiness card view). Types exist; this is surfacing.
- **Test**: with < `minBaseline` nights the read returns calibrating/low-confidence, not a confident number.

### RD-framing — non-clinical presentation guardrails  ·  impact 6.0
- **Files**: readiness card copy + one persistent-abnormal → "see a clinician" check. Framing + a single check; keep NON-CLINICAL.

### T-coldstart — cold-start gate on sleep-need/debt surfaces  ·  impact 6.0
- **Files**: the need/debt surface. Mirror the `calibrating→provisional→trusted` ladder; never emit a confident debt from thin history.
- **Test**: truncated history → provisional, not a confident deficit.

## Sequencing within 0a

1. **SL1**, **T1** (the two 9.0 wins; both in `AnalyticsEngine`/need path — do together, they share the Rest builder).
2. **R4** (free), **R7** (localized).
3. **RD1**, **RD-confidence**, **RD-framing** (readiness cluster — land together).
4. **T-coldstart**.

Each lands test-first, package build + macOS build green, committed separately for a legible history. PR targets `main`.
