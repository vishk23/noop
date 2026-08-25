# Stress (intraday tip + daily score)

# Stress — Target Methodology for NOOP (intraday tip + daily score)

Scope: the two surfaces on NOOP's Stress screen — an **intraday tip** ("when in the day was I activated, and should I breathe?") and a **daily score** ("how stressed was I today?"). The goal is a rigorous, high-resolution, *actionable* autonomic-arousal approximation that underclaims honestly, not a clinical stress measure.

---

## Part 1 — Target methodology

### 1.0 Frame first: what this score is, and is not

Every design choice below descends from one honesty constraint. A wrist/finger-PPG "stress" reading is an **autonomic-arousal approximation**, and arousal is **valence-blind**: a workout, a coffee, an exciting phone call, standing up, speaking, and a work deadline all produce the same cardiac signature — HR up, HRV down [1][5][6]. Oura states outright that its feature "cannot differentiate different stress sources" [13]. The medical literature is explicit that only linear time-domain HRV metrics (SDNN, RMSSD) clear Tier-1 evidence for any prognostic claim [3], that ~11% of consumer wearables are validated for *any* metric, and that "stress/readiness/body-battery" scores are "unexplored terrains" of validity [12]. A bare, alarming daytime number is also a documented driver of health anxiety — one case logged 916 ECGs in a year, benign readings repeatedly misread as threats [11]. **Therefore the score must be framed as non-clinical physiological load, presented as patterns-vs-personal-baseline rather than an absolute, gated hard on motion and data-coverage, and suppressed (not fabricated) when the signal can't support it.**

### 1.1 The physiology backbone (this part is solid)

Acute stress = sympathetic activation **plus vagal withdrawal**. Because beat-to-beat variability is overwhelmingly vagal, HRV **drops** as the vagus withdraws. The canonical meta-analytic signature: under stress **HF power, RMSSD, and SDNN fall while LF/HF rises** [1]. This is the mechanistic bedrock, and it is what both Oura and WHOOP encode: elevated HR + suppressed HRV vs a personal baseline [13][17][19].

### 1.2 Which HRV metric to trust — and which to demote

| Metric | Role in the target | Basis |
|---|---|---|
| **RMSSD → lnRMSSD** | **Core driver.** Primary time-domain *vagal* index (~42±15 ms healthy adults), valid down to ultra-short 10–30 s windows; log-transform for stable day-to-day comparison. | [2][4] |
| **SDNN** | Context only. Its prognostic value is a 24-h property; 5-min SDNN "does not" carry it. Weak basis for a moment-to-moment tip. | [2][3] |
| **Baevsky Stress Index** (SI = AMo / (2·Mo·MxDMn); report √SI per Kubios) | **Descriptive secondary channel**, explicitly a rigidity/sympathetic-*loading* proxy — *not* a validated sympathetic measure (the defining 2024 paper calls it "a needed start"). Pin units; implementations disagree. | [8][9] |
| **LF/HF ratio** | **Do not build the score on it.** "Sympathovagal balance" is discredited for resting/short recordings: LF is not pure-sympathetic, and 5-min vs 24-h values correlate poorly. Show as a labelled lens at most. | [1][2] |

There is no single right answer on **which HRV window length**: ultra-short RMSSD is valid at 10–30 s but is *noisiest at that floor*, and the source itself recommends averaging multiple windows [4]. Target: compute RMSSD on short epochs but **average several before scoring**, and expose the resulting confidence.

### 1.3 The four pillars both vendors converge on

Neither Oura nor WHOOP publishes its fusion formula, weightings, or band cut-points — every "how it combines" claim about them is inference, and neither publishes accuracy metrics against any criterion (cortisol/EDA/ECG). But their *architecture* is visible and agreed, and it is the right target:

1. **Multi-signal cardiac core.** HR + HRV as the driver. Oura adds accelerometer motion and "Average body temperature" [13][14]; WHOOP uses **HR + HRV + motion only** [17][18][19]. (Correcting a common error: WHOOP's stress score does **not** use skin temperature, SpO2, or respiratory rate — those are Recovery-side signals; the "5-input WHOOP" claim traces to an unverified third party [21] and contradicts WHOOP's own docs.)
2. **Personalized baseline, no population thresholds.** WHOOP: a **14-day** rolling HRV baseline + typical resting HR [18][19]. Oura: "recalibrated daily… no fixed thresholds," ≥5 days wear to seed [13].
3. **Motion awareness** — the two *diverge* here, and it is a genuine tradeoff (§1.6): Oura **masks** motion (no score during activity; 15-min low-motion snapshots) [13]; WHOOP **discounts** motion to keep scoring during exercise [17].
4. **Time-in-zone daily rollup, not one opaque scalar.** Oura's app shows daily "Stressed"/"Restored" minutes; its API exposes `stress_high` / `recovery_high` verbatim as *"time spent in a high stress zone (top quartile of data)"* / *"bottom quartile data"* in seconds, with a 3-level `day_summary` ∈ {restored, normal, stressful} [16]. The reference distribution behind "quartile of data" is **not stated** — present it as "time in your top-quartile stress zone," not as a confirmed rolling-personal-distribution mechanism.

**Verdict for NOOP (WHOOP companion):** build the **WHOOP-transparent intraday core** — lnRMSSD + HR vs a rolling personal baseline (+ resting HR), motion-handled, mapped to a simple low/moderate/high band — and adopt **Oura's time-in-zone daily rollup** as the daily summary. Skin temperature (available from Oura import / WHOOP 5.0) is at most a **slow contextual modifier, never a primary driver** — it is a weak, nonspecific *acute*-stress signal [14].

### 1.4 The non-negotiable correctness gate: motion

The single most important honesty constraint. Cardiac signals **cannot cleanly separate psychological stress from physical exertion, posture, or speaking.** This is broad, settled literature: RMSSD is confounded by posture (supine ≫ sitting ≫ standing), by 24–48 h exercise-recovery shadow, by a strong circadian swing with a sympathetic surge on waking, by temperature, caffeine, and alcohol [5][7]; and reading aloud / talking / spoken arithmetic shift respiration into the LF band and alter HRV *mechanically*, independent of any stress [6]. A recent (single, n=19, non-peer-reviewed) preprint sharpens the point — across seated/walking/cycling, HR and RMSSD were driven almost entirely by exertion, and the one channel with an *additive, separable* psychological-stress response was **electrodermal activity (EDA)**, which PPG wearables do not measure [10]. Treat that specific study as directional, not settled (EDA there actually correlated *more* with exertion, r≈0.67, than with stress, r≈0.48). The robust conclusion that survives regardless: **without motion gating and a circadian-phase-aware personal baseline, the score reports "stress" for a brisk walk, a phone call, or standing up.** Both are mandatory, not optional.

### 1.5 Target pipeline

```
R-R (cleaned) + HR + motion/gravity/steps + (temp, contextual)
   │
   ├─ 1. EPOCH: ~5-min epochs (Oura grain). RMSSD per epoch; average ≥N clean
   │        sub-windows for stability; lnRMSSD; instantaneous HR.
   │
   ├─ 2. MOTION GATE (mandatory): mark each epoch stationary vs active from
   │        accel/gravity/steps. SCORE ONLY STATIONARY, artifact-clean epochs.
   │        Blank or flag the 24–48 h post-hard-exercise shadow.
   │
   ├─ 3. PERSONAL, CIRCADIAN-AWARE BASELINE: per-user rolling (~14-day) dist of
   │        lnRMSSD + HR, stratified by time-of-day; express epoch as z / margin
   │        vs the user's own same-phase baseline. Adapt slowly. Robust stats
   │        (Winsorize + EWMA + σ-floor), with a cold-start/confidence status.
   │
   ├─ 4. FUSE: elevated when lnRMSSD depressed AND HR elevated vs baseline;
   │        weight vagal HRV highest. NO resting LF/HF as the sympathetic proxy.
   │        Temp cooling = weak specificity add only.
   │
   └─ 5. OUTPUT
         • Intraday tip: low / moderate / high band per stationary epoch,
           + confidence flag; sustained-high → benign action (breathe/walk).
         • Daily: TIME-IN-ZONE (minutes in high-stress / high-recovery, Oura
           quartile-style) as the headline, + coverage (% of day scoreable).
           A single 0–3/0–100 only as a secondary, defined transparently.
```

### 1.6 Where there is no single right answer (explicit tradeoffs)

- **Motion: mask vs discount.** Oura masks (honest, but sacrifices daytime coverage); WHOOP discounts (full coverage, but requires an undisclosed, unvalidatable exertion-subtraction model). For a **cardiac-only** app that cannot see EDA, **masking is the more defensible default**; discounting is a research direction, not a shippable default.
- **Baseline: day-local vs personal cross-day.** Day-local ("the day is its own baseline") needs zero history and works cold, but an all-day-stressed day pulls its own "calm" reference up and reads ~normal, masking real stress. A personal rolling baseline needs seeding but scored materially better against an Oura reference (r≈0.6 vs r 0.43–0.53 for day-relative in NOOP's own 26-day validation). **Personal wins once seeded; day-local is the cold-start fallback, clearly flagged as provisional.**
- **Resolution: fine vs coarse epochs.** ~5-min epochs (Oura grain) are responsive but noisy and gappy, and *require* motion gating or every active epoch lights up. Hourly buckets are stable and partially, accidentally mute the motion problem by averaging — but they mis-score sustained-active hours and can't localize a short stressor. Target: **fine epochs + mandatory motion gate + multi-window averaging + coverage display.**
- **Output shape: scalar vs time-in-zone.** A single 0–3 is simple but opaque and, presented as an absolute, anxiety-provoking [11]. Time-in-zone minutes are honest and personalized but need a coverage denominator so a mostly-unscored day isn't shown as "calm." **Prefer time-in-zone; keep any scalar secondary and transparently defined.**
- **What the daily number even measures.** A daily stress score built from *last night's sleep* RHR/HRV is protected from the exertion confound (sleep is low-motion) but is really a **morning autonomic-state / recovery-adjacent** number — conceptually different from Oura/WHOOP's *daytime* stress, which aggregates daytime epochs. The cleanest target is: **the daily headline = the aggregation (time-in-zone) of the day's motion-gated daytime epochs**, with any sleep-derived autonomic number reframed as morning readiness rather than sharing the "stress" label and bands with the intraday tip.

### 1.7 Validation path

Move beyond marketing by correlating output against tagged real-world stressors and, ideally, salivary cortisol or an EDA reference in a small internal study; report agreement numbers rather than asserting accuracy [12]. NOOP already has a precedent worth extending: the dormant `.baselineRelative` HR margin was tuned against a 26-day Oura reference (r≈0.6). Re-validate once an HR+HRV (RMSSD-included) comparison exists.

---

## Part 2 — Gap analysis: NOOP today vs the target

NOOP's Stress surface is two independent computations sharing only the logistic squash `3/(1+e^(−raw))`. Both fall short of the target in specific, fixable ways.

**A) Daily 0–3 score** — `StressModel.init` / `StressMath` in `/Users/vk/VKDEV/NOOP/noop/Strand/Screens/StressView.swift` (≈720–883).

1. **Naive stats; ignores the robust machinery the repo already ships.** The baseline is a plain arithmetic mean + **population SD** (`StressMath.std`, ÷N) over up to 30 raw nightly RHR/HRV values (StressView ≈741–749). No Winsorizing, no hard-outlier rejection, no EWMA recency weighting, and crucially **no σ-floor**. Recovery already uses the `floorSpread`-protected `Baselines` model; Stress reimplements a weaker one locally. Consequence: one artifact night skews mean/SD, and a *tight* baseline makes the logistic saturate on a few-bpm move — the exact jumpiness a σ-floor prevents.
2. **Equal-weight fusion, unjustified.** `raw = zRHR + zHRV` with 1:1 weights (StressView ≈831–843) and no physiological/empirical basis, even though the target weights vagal HRV highest [1][2].
3. **Three surfaces disagree on the same number.** For WHOOP CSV imports the *preferred* stored value is written by `WhoopImporter` (branch `origin/stress-baseline-relative:Strand/Data/WhoopImporter.swift` ≈111) as `z = 0.6·zRHR − 0.6·zHRV`, `stress = clamp(1.5+z, 0, 3)` — a **linear, 0.6-weighted, whole-history** map. The live `StressModel` is **logistic, unit-weighted, trailing-30**. The daily card *prefers the stored value verbatim* (StressView ≈722–724), so the shown number can be the importer's transform while the "How this is computed" card describes the logistic one — **the explanation can misdescribe the displayed number.**
4. **Trend is not a true rolling-baseline history.** Every past day in `fullTrend` is re-scored against **today's single 30-day baseline** (StressView ≈783–798), so historical stress is distorted by where the baseline sits now, not each day's contemporaneous norm.
5. **No confidence/coverage.** Cold-start (few baseline nights) silently drops a z-term or collapses toward the 1.5 midpoint (≈757, ≈765) with no "calibrating/provisional" status — unlike `BaselineStatus` in `Baselines.swift`. It is really a morning autonomic-state number but is labelled and banded identically to the daytime tip (§1.6).

**B) Intraday tip** — the **shipped** `.dayRelative` path in `/Users/vk/VKDEV/NOOP/noop/Packages/StrandAnalytics/Sources/StrandAnalytics/DaytimeStress.swift`.

6. **The validated superior path ships dormant.** `.baselineRelative` (personal cross-day Winsorized-EWMA baseline + a **validated fixed +15 bpm** HIGH cutoff, `marginToSigma(15, atBand:2.0)`, r≈0.6 vs Oura) is fully implemented and unit-tested on the branch, but the only non-test caller — `StressView.swift:115` — passes **no mode**, so the tip runs the `.dayRelative` path the same study found **inferior** (r 0.43–0.53). Wiring it is a near-one-line caller change, gated only on building the `daytime_hr`/`daytime_rmssd` history folder from past daytime aggregates.
7. **No motion gating at all** — the central science gate is **absent from both the shipped and the dormant path.** `DaytimeStress.analyze` takes only `hr` and `rr`; its only gate is `minHourHRSamples=300` (a data-density gate) plus the waking window. NOOP *has* accelerometer/gravity/steps, but they never reach this path. An active hour (commute, chores, workout) with enough HR samples is scored as "stress" [5][10]. Hourly averaging only partially mutes this; finer grain would make it worse without a gate.
8. **Day-local baseline masks all-day stress.** `.dayRelative` centres on the day's own lower-quartile HR / upper-quartile RMSSD across ≤16 waking hourly aggregates; a uniformly stressed day sets a high "calm" quartile and reads ~baseline, so the Breathe nudge under-fires. With ≤16 points, `sdHR/sdRMSSD` can be tiny (z saturates) or, with <2 hours, zero (term dropped, everything reads 1.5).
9. **Coarse grain.** Hourly buckets needing 300 HR samples each vs Oura's ~5-min grain; on WHOOP's intermittent daytime sampling many hours fail the gate and go unscored, and any high-stress-minutes count can only move in 60-min steps.
10. **Hardcoded waking window.** 06:00–22:00 by hour-of-day, not actual sleep detection — shift workers, nappers, and early risers are mis-bucketed.

**C) Additive lenses, correctly quarantined.** `StressIndex` (Baevsky SI) and `HRVFreqDomain` (LF/HF via Lomb-Scargle) are today-only descriptive readouts in an "Advanced HRV" card and feed neither the score nor the timeline (StressView ≈121–122; `/Users/vk/VKDEV/NOOP/noop/Packages/StrandAnalytics/Sources/StrandAnalytics/StressIndex.swift`). This matches the target — LF/HF must not drive the score [1][2] — and the SI implementation and units are correct. The only gap is that RMSSD is time-domain only per hour; no frequency-domain or respiration correction informs the score (acceptable, given the target demotes both to lenses).

---

## Part 3 — Actionability: what the user should be able to *do*

A stress number is only useful if it drives a decision without driving anxiety. NOOP already does several things right — "autonomic load" framing, a passive in-app Breathe nudge (no notification), a transparent methodology card, and honest gaps-as-blanks rather than fabricated values. To close the loop:

1. **Anchor everything to the user's own baseline, never an absolute.** "HRV 12% below your 14-day norm," not "stress 2.3." Both vendors' entire actionability rests on this [13][19]; it is also the anxiety antidote [11].
2. **Show WHEN, and let the user attach context.** The intraday timeline is the actionable surface: a labelled peak ("high 2.4 at 3 PM") the user can mentally map to a meeting or a coffee. Allow a lightweight tag/note so arousal's valence-blindness becomes the user's own annotation rather than a false "stress" verdict.
3. **Pair every elevation with a benign next action, not an alarm.** NOOP's sustained-high → Breathe sheet is the right pattern (mirrors WHOOP's Huberman breathwork [17]). Extend to "a short walk / hydration / step outside." Never imply threat.
4. **Make coverage and confidence first-class.** Display "we could score 6 of your 16 waking hours today" and mark cold-start days "calibrating." A mostly-unscored day must never render as "calm" — suppress, don't infer.
5. **Give a daily summary that's honest and glanceable:** time-in-high-stress and time-in-recovery minutes (Oura quartile-style [16]) with a coverage denominator — more legible and less alarming than a single 0–3, and it makes "was today unusually stressful?" answerable against the user's own distribution.
6. **Keep the non-clinical guardrails visible.** An explicit line that this is physiological arousal (workout, caffeine, excitement, and a deadline read identically), not a clinical or mental-health measure, and that persistent changes warrant a clinician, not the app [12]. This *is* NOOP's philosophy — underclaim, gate, make provenance legible.

---

## Sources

1. Kim et al. 2018, *Stress and HRV: A Meta-Analysis* — PMC5900369 (stress → HF/RMSSD/SDNN down, LF/HF up; HRV endorsed as objective stress index). *Verified.*
2. Shaffer & Ginsberg 2017, *An Overview of HRV Metrics and Norms* — PMC5624990 (RMSSD ~42±15 ms vagal; SDNN ~50±16 ms; LF/HF "sympathovagal balance" discredited; 5-min vs 24-h not interchangeable). *Verified.*
3. Frontiers in Cardiovascular Medicine 2025 HRV review — fcvm.2025.1630668 (only SDNN and RMSSD meet Tier-1 evidence).
4. J Appl Physiol 2020, ultra-short-term HRV — japplphysiol.00955.2020 (RMSSD valid at 10 s / SDNN 30 s; noisy at the floor, average multiple windows). *Verified.*
5. HRV confounds review — PMC11439429 (posture, 24–48 h exercise recovery, circadian, temperature, caffeine, alcohol, respiration).
6. Bernardi et al. 2000 — ScienceDirect S0735109700005957 (reading aloud / talking / spoken arithmetic alter HRV mechanically via respiration). *Verified.*
7. Circadian HRV — PubMed 22734576 (maximal sympathetic shift on morning awakening).
8. Baevsky Stress Index, Am J Physiol Regul 2024 — ajpregu.00243.2024 (SI = AMo/(2·Mo·MxDMn); framed as "a needed start," not validated vs MSNA/norepinephrine). *Verified.*
9. Kubios, *HRV Analysis Methods* — kubios.com/blog/hrv-analysis-methods (AMo/Mo/MxDMn definitions; reports √SI as "Stress Index"). *Verified.*
10. Bosch et al. (DLR), arXiv:2605.15756 (exertion dominates HR/RMSSD; EDA is the additive/separable psychological-stress channel). *Single n=19 non-peer-reviewed preprint — directional only; EDA correlated more with exertion than stress.*
11. Smartwatch health-anxiety case — PMC8357265 (916 ECGs/year; benign readings misread as threats). *Illustrative, for harm caution.*
12. Umbrella review of consumer wearables — Sports Medicine 10.1007/s40279-024-02077-2 (~11% validated for any metric; stress/readiness scores "unexplored terrains").
13. Oura Support, *Daytime Stress* — support.ouraring.com/…/Daytime-Stress (inputs HR/HRV/Motion/Average body temperature; 4 zones; 15-min while awake/worn/inactive; ≥5-day wear; recalibrated daily, no fixed thresholds; cannot differentiate sources). *Verified verbatim.*
14. Oura Engineering, *Inside the Ring: Daytime Stress* — ouraring.com/blog/inside-the-ring-daytime-stress (per-signal physiology; temperature as vasoconstriction proxy — slow, weak, nonspecific).
15. Oura, *Daytime Stress feature* — ouraring.com/blog/daytime-stress-feature (Stressed/Engaged/Relaxed/Restored; ~96 stressed / ~64 restored avg minutes).
16. Oura API v2 `daily_stress` (mirrored in Pinta365/oura_api generated.ts) — `stress_high` = "top quartile of data in seconds," `recovery_high` = "bottom quartile data in seconds," `day_summary` ∈ {restored, normal, stressful}. *Verified verbatim; reference distribution unstated.*
17. WHOOP, *Introducing Stress Monitor* — whoop.com/…/introducing-stress-monitor (HR + HRV in-the-moment + motion to distinguish exercise; 0–3 scale; Huberman breathwork). *Verified.*
18. WHOOP India, *How It Works* — whoop.in/pages/how-it-works ("compared to your 14-day baseline… Stress Score between 0 and 3"). *Verified verbatim.*
19. WHOOP Support, *Get to Know the Stress Monitor* — support.whoop.com (0–3 from HR+HRV vs 14-day HRV baseline + typical resting HR; motion limits exercise impact; low/useful-alertness/high bands).
20. WHOOP, *HRV Training* — whoop.com/…/heart-rate-variability-training (represents HRV as lnRMSSD). *For the Recovery pipeline; NOT confirmed for the live Stress reading.*
21. kygo.app, *WHOOP Stress Score & Recovery* — kygo.app/post/whoop-stress-score-recovery-explained. *Unverified third party; source of the refuted "5-signal WHOOP" claim — do not rely on.*

NOOP code (absolute paths): `/Users/vk/VKDEV/NOOP/noop/Strand/Screens/StressView.swift` (daily model + wiring); `/Users/vk/VKDEV/NOOP/noop/Packages/StrandAnalytics/Sources/StrandAnalytics/DaytimeStress.swift` (shipped `.dayRelative` intraday); `/Users/vk/VKDEV/NOOP/noop/Packages/StrandAnalytics/Sources/StrandAnalytics/StressIndex.swift` and `HRVFreqDomain.swift` (additive lenses); branch `origin/stress-baseline-relative`: `…/DaytimeStress.swift` (`.baselineRelative`, `marginToSigma`, `baselineRelativeHighMarginBPM=15`), `…/Baselines.swift` (`daytime_hr`/`daytime_rmssd` cfgs), `Strand/Data/WhoopImporter.swift` (the divergent stored-value formula).

## Ranked recommendations

| # | Change | Impact | Conf | Effort |
|---|---|---|---|---|
| 1 | Wire the validated .baselineRelative intraday path into StressView (build the daytime_hr/daytime_rmssd history folder from past daytime aggregates, then pass the mode at StressView.swift:115 instead of defaulting to .dayRelative). | high | high | medium |
| 2 | Add a mandatory motion gate to the intraday tip: thread NOOP's accelerometer/gravity/steps into DaytimeStress and score only stationary, artifact-clean epochs (mask, don't discount); blank or flag the 24–48 h post-hard-exercise shadow. | high | high | high |
| 3 | Replace the daily score's local naive statistics (StressMath plain mean + population SD over 30 nights) with the repo's robust Baselines machinery — Winsorize, EWMA half-life recency weighting, σ-floor/floorSpread, and a BaselineStatus. | high | high | medium |
| 4 | Stop the stored-value shadowing and unify the three disagreeing daily transforms: recompute imported (my-whoop) days through the live StressModel, or at minimum relabel provenance so the shown number and the 'How this is computed' card always agree. | high | high | medium |
| 5 | Surface coverage and confidence on both surfaces: intraday 'X of your N waking hours were scoreable,' and daily cold-start 'calibrating/provisional' status; never collapse silently to the 1.5 midpoint or render a mostly-unscored day as calm. | high | high | medium |
| 6 | Add an Oura-style time-in-zone daily rollup (minutes in high-stress and in high-recovery, plus coverage) as the daily headline, keeping any single 0–3 as a transparently-defined secondary; ideally aggregate it from the motion-gated daytime epochs rather than from last night's sleep vitals. | medium | medium | medium |
| 7 | Make the daily trend a true rolling-baseline history: score each past day against its own contemporaneous trailing baseline instead of re-expressing every day against today's single 30-day baseline. | medium | high | medium |
| 8 | Move the intraday grain from hourly buckets to ~5-min epochs (Oura grain) with multi-window RMSSD averaging for stability — contingent on the motion gate landing first. | medium | medium | high |
| 9 | Replace the hardcoded 06:00–22:00 waking window with actual sleep/wake detection, and keep skin temperature (Oura import / WHOOP 5.0) strictly as a slow contextual modifier, never a score driver. | low | medium | medium |

### Rationale detail

1. **Wire the validated .baselineRelative intraday path into StressView (build the daytime_hr/daytime_rmssd history folder from past daytime aggregates, then pass the mode at StressView.swift:115 instead of defaulting to .dayRelative).** — The superior path is already implemented and unit-tested on origin/stress-baseline-relative: a personal cross-day Winsorized-EWMA baseline plus a validated fixed +15 bpm HIGH cutoff scored r≈0.6 against an Oura reference, versus r 0.43–0.53 for the day-local .dayRelative path that currently ships. Shipping the inferior path while the better one sits dormant behind a near-one-line caller change is the single highest-leverage fix, and it directly implements the target's personal-baseline pillar [13][17][19].

2. **Add a mandatory motion gate to the intraday tip: thread NOOP's accelerometer/gravity/steps into DaytimeStress and score only stationary, artifact-clean epochs (mask, don't discount); blank or flag the 24–48 h post-hard-exercise shadow.** — This is the central, non-negotiable correctness gate from the science, and it is absent from BOTH the shipped and the dormant path — analyze() takes only hr and rr. Cardiac signals cannot separate psychological stress from exertion/posture/speaking [5][6][10], so an active hour with ≥300 HR samples is currently scored as 'stress.' Masking is the defensible default for a cardiac-only app that cannot see EDA; Oura masks for exactly this reason [13].

3. **Replace the daily score's local naive statistics (StressMath plain mean + population SD over 30 nights) with the repo's robust Baselines machinery — Winsorize, EWMA half-life recency weighting, σ-floor/floorSpread, and a BaselineStatus.** — Recovery already uses the floorSpread-protected Baselines model; Stress reimplements a weaker one in StressView (≈741–749) with no outlier rejection and, critically, no σ-floor — so one artifact night skews the baseline and a tight baseline makes the logistic saturate on a few-bpm move. Reusing the shipped machinery removes the jumpiness and gives a cold-start status for free.

4. **Stop the stored-value shadowing and unify the three disagreeing daily transforms: recompute imported (my-whoop) days through the live StressModel, or at minimum relabel provenance so the shown number and the 'How this is computed' card always agree.** — The daily card prefers the stored value verbatim (StressView ≈722–724), but for WHOOP CSV that value is WhoopImporter's linear, 0.6-weighted, whole-history z = 0.6·zRHR − 0.6·zHRV, clamp(1.5+z) — materially different from the logistic, unit-weighted, trailing-30 model the methodology card describes. The explanation can therefore misdescribe the displayed number, which violates NOOP's legible-provenance philosophy.

5. **Surface coverage and confidence on both surfaces: intraday 'X of your N waking hours were scoreable,' and daily cold-start 'calibrating/provisional' status; never collapse silently to the 1.5 midpoint or render a mostly-unscored day as calm.** — Exposing how much of the day was actually scoreable after gating is a core honesty constraint [12] and the antidote to a bare number driving over-checking [11]. NOOP currently drops z-terms or defaults to 1.5 with no status, unlike BaselineStatus in Baselines.swift, so a low-data day can read falsely calm.

6. **Add an Oura-style time-in-zone daily rollup (minutes in high-stress and in high-recovery, plus coverage) as the daily headline, keeping any single 0–3 as a transparently-defined secondary; ideally aggregate it from the motion-gated daytime epochs rather than from last night's sleep vitals.** — Both vendors converge on time-in-zone over an opaque scalar, and Oura's API exposes it verbatim as seconds in the top/bottom quartile [16]; the science recommends the same. It is more legible and less alarming than a lone number, and it fixes a conceptual gap: NOOP's current daily score is built from sleep RHR/HRV (a morning autonomic-state number) yet shares the 'stress' label and bands with the daytime tip.

7. **Make the daily trend a true rolling-baseline history: score each past day against its own contemporaneous trailing baseline instead of re-expressing every day against today's single 30-day baseline.** — fullTrend (StressView ≈783–798) computes one baseline for today and scores all history against it, so past stress is distorted by where the baseline sits now rather than each day's own norm — the trend line is not comparable across time.

8. **Move the intraday grain from hourly buckets to ~5-min epochs (Oura grain) with multi-window RMSSD averaging for stability — contingent on the motion gate landing first.** — Hourly buckets requiring 300 HR samples each leave many hours unscored on WHOOP's intermittent daytime sampling and can only localize stress to the hour; ultra-short RMSSD is valid at 10–30 s but noisy, so averaging several short windows per epoch is the right stability tradeoff [4]. Finer grain must not ship before motion gating, or every active epoch will read as stress.

9. **Replace the hardcoded 06:00–22:00 waking window with actual sleep/wake detection, and keep skin temperature (Oura import / WHOOP 5.0) strictly as a slow contextual modifier, never a score driver.** — The fixed hour-of-day window mis-buckets shift workers, nappers, and early risers. Temperature is a slow, weak, nonspecific acute-stress signal and is Oura-only among the vendors [14] — the refuted 'WHOOP uses temperature' claim must not be reintroduced; treat it as optional specificity, not a primary channel.

