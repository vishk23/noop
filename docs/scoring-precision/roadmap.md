# NOOP scoring precision — program roadmap

No `.almanac/` wiki in this repo (only the CLI is installed) and the task is a pure synthesis of the five provided audits, so no code re-read is warranted. Here is the deliverable.

---

# NOOP Precision-Program Map

The five score families are not five problems. They are five views onto **~8 shared machines** — a baseline engine, an HRV representation, a sleep-wake detector, a regularity signal, a motion channel, a confidence contract, a set of context channels, and a presentation substrate. Almost every per-score recommendation collapses onto one of those machines. The strategic consequence: **fix the machine once, lift three-to-five scores at once.** The program below is organized to exploit that, not to grind score-by-score.

A second structural fact dominates the sequencing: **the most rigorous methodology in this codebase is already written, unit-tested, and disconnected.** `.baselineRelative` (Stress, r≈0.6), `VitalityEngine.sleepConsistency` (Rest), `HRVReadiness` (log-SWC band), and the `Recovery-Index`/`Activity-Balance` scaffolding all exist behind caller changes or default-off flags. The single highest-ROI wave is wiring, not building.

---

## 0. The recurrence matrix (the whole thesis on one screen)

Each row is a shared machine; each cell is how that machine surfaces (or fails) in that family. Read it column-wise to see a family's dependencies; row-wise to see the leverage of one fix.

| Shared machine | Stress | Rest / Sleep | Charge / Recovery | Readiness | Trends / Longitudinal |
|---|---|---|---|---|---|
| **Baseline spine** (`Baselines.swift`: Winsor + EWMA + σ-floor + status) | Daily uses naive mean+popSD, no σ-floor → logistic saturates | Rest has **no** learned baseline; enters recovery at fixed 0.85 center | Uses it for HRV/RHR/resp; sleepPerf & skinTemp still fixed | `ReadinessEngine` rolls its own naive raw-ms mean/SD, ignores the spine | Full-history EWMA, **no bounded window, wall-clock-blind** |
| **HRV representation** (lnRMSSD; freq-domain) | Per-hour RMSSD only; freq-domain exists but never scores | RMSSD-only; **no HF/LF-HF** — the feature that best separates NREM/REM | z-scores **raw ms** (right-skewed) | Default engine raw-ms; quarantined `HRVReadiness` correctly uses ln | `deviation()` symmetric-Gaussian on skewed ms |
| **Sleep-wake detection + one sleep-need** | Hardcoded 06:00–22:00 window; daily built from *sleep* vitals | The whole score; need hardcoded **8 h** at the call site | Rest term + (dead) sleep-debt input | Sleep-debt/regularity are the missing orthogonal terms | Need is **self-referential mean** → debt inverts for under-sleepers |
| **Regularity** (consistency / SRI) | — | `sleepConsistency` **constant 0.5 → +5.0 for everyone** | — | Should be a context term | **No SRI at all** despite per-minute epochs |
| **Motion / gravity / steps gate** | **Absent** — exertion scored as stress (central correctness bug) | Core to staging; sparse-motion nights break it | (motion via dead strain term) | (load context) | Circadian uses **HR, not motion**, for the activity acrophase |
| **Confidence / coverage** (`ScoreConfidence`, `BaselineState.status`) | Collapses to 1.5 midpoint silently | Confidence *tier* exists, composite ignores it | **Has** `ScoreConfidence` (the model to copy) | `minBaseline=7`, no width shown | Emits confident numbers from night one |
| **Directional context** (skin-temp, resp, circadian) | Temp must stay a slow modifier, never a driver | Resp is RSA-estimate; no-resp funnels REM→0 | Skin-temp is a **symmetric penalty** (fever == cooling) | Temp framed as illness, not "off baseline" | Circadian temp-min cross-check **never runs** |
| **Presentation substrate** (trend+band, decomposition, provenance) | Stored value **shadows** the shown math; trend re-based on today | `sleep_performance` names a quality blend as if a sufficiency ratio | Per-term deltas don't sum (logistic); doc drift | Three engines can point opposite ways, unreconciled | Split-half vs OLS; no CI band; stale-anchor ambiguity |

---

## 1. Shared machinery — fix once, lift many

### M1 · The baseline spine (`Baselines.swift`) — adopt it universally, in log-domain, wall-clock-aware
This is the single biggest structural lever. The repo already has a robust EWMA engine with Winsorization, a σ-floor (`floorSpread`), hard bounds, and a `calibrating→provisional→trusted→stale` status ladder — and **Charge already depends on it.** Four families either bypass it (Stress daily, Readiness), use it but leave key terms un-personalized (Recovery's `sleepPerfCenter=0.85`/`skinTempScaleC`, Rest's absent baseline), or inherit its two internal defects (full-history-only window, observation-indexed decay).
**Fix once, lifts:** Stress daily (S3), Readiness (RD2), Recovery HRV+fixed terms (R5/R6), Rest→recovery center (SL5), and — by fixing the engine's own ln-space and wall-clock handling (T7/T9) — everyone downstream. It also **dissolves the "three engines disagree on domain and baseline construction" incoherence at its root**, because they'd finally share one substrate.

### M2 · HRV representation — lnRMSSD everywhere, plus a freq-domain proxy as instrumentation
Two distinct issues ride together. (a) **Domain:** RMSSD is right-skewed; a symmetric z on raw ms treats equal-magnitude suppression and elevation as equally probable (they are not) and misstates tail rarity. Sport science standard is lnRMSSD; the app's own `HRVReadiness` already does this correctly while the default path does not. (b) **Bandwidth:** there is no frequency-domain HRV anywhere, the one feature that most directly separates NREM from REM autonomically — a genuine staging ceiling.
**Fix once, lifts:** Recovery (R6), Readiness (RD2), Trends (T9) all get the ln fix in the *same* `deviation()` change; Sleep staging (SL9) and Stress intraday get the freq-domain proxy — but that proxy ships behind an Experimental gate until it proves it *tracks a varying input* (anti-#194), never as a default on thin evidence.

### M3 · Sleep-wake detection + one personalized sleep-need — the dependency hub
Sleep/wake epochs and a single defensible sleep-need are upstream of half the program. Today Stress hardcodes a 06:00–22:00 clock window, Rest measures against a fixed 8 h, and Trends measures against a **self-referential all-history mean that drifts down toward a chronic under-sleeper's own deficit** — inverting the honesty philosophy for exactly the users with the most debt. One personalized, population-anchored need (age-floored 7–9 h, personal component from unrestricted nights) feeds Rest's 50% duration term, the debt ledger, and Readiness's context axis simultaneously.
**Fix once, lifts:** Stress waking-window + motion-gated daytime epochs (S9/S2), Trends SRI + circadian wake-anchor (T2/T5), Rest (SL2), debt (T3), Readiness context (RD6).

### M4 · Regularity — the highest-mortality-evidence signal, currently a constant
Sleep regularity out-predicts duration for all-cause and cardiometabolic mortality (Windred 2024). NOOP computes `VitalityEngine.sleepConsistency` and **throws it away** — Rest receives a constant 0.5 (a flat +5.0 for every user, every night), and there is no Sleep Regularity Index in the longitudinal layer despite per-minute sleep/wake epochs that make SRI directly computable.
**Fix once, lifts:** Rest (SL1, a threading change), Trends (T2, a new SRI engine), and Readiness's context axis. Best evidence-to-effort ratio in the entire design.

### M5 · Motion gating — the correctness gate that unblocks resolution
Cardiac signals cannot separate psychological stress from exertion, posture, or speaking. The intraday Stress tip currently scores an active hour with ≥300 HR samples as "stress" because `analyze()` never sees accelerometer/gravity/steps. This is the one **non-negotiable correctness gate** in the program, and it is a hard prerequisite: finer 5-min epochs (S8) must not ship before it, or *every active epoch reads as stress*. The same motion channel is the correct cosinor "activity" input for circadian phase (T5, currently HR — confounded by caffeine/meals/exercise) and is core to staging.
**Fix once, lifts:** Stress correctness (S2), Stress resolution (unblocks S8), circadian phase (T5), staging robustness.

### M6 · Confidence & coverage — one honesty contract, surfaced everywhere
Charge already carries `ScoreConfidence` (calibrating/building/solid); Stress, Sleep, Readiness, and Trends do not propagate the confidence they already compute. The failure modes are specific and dangerous: a motion-only WHOOP-4.0 night and a full-signal 5.0 night surface an *identical-looking* 0–100 Rest; a mostly-unscored Stress day collapses to the 1.5 midpoint and reads **calm**; Readiness estimates its SD denominator off as few as 7 nights with no width shown. The types exist — this is surfacing, not building.
**Fix once, lifts:** Stress (S5), Sleep (SL3), Readiness (RD4), Trends (T8). It is also the antidote to the hardware-class trap: **low confidence must never render as low quality.**

### M7 · Directional context channels — keep the sign
Skin-temp and respiration carry *directional* information (a rise signals illness/overreach; cooling is benign) that the current symmetric `-|dev|` penalty discards — it scores a fever identically to benign cooling, throwing away the exact signal Oura uses for days-ahead illness detection. Across families the discipline is the same: temperature is a **slow, weak, non-specific modifier**, never a primary driver (the refuted "WHOOP uses temperature" claim must not be reintroduced), and its sign is the whole point.
**Fix once, lifts:** Recovery (R3, split into a signed illness/overreach flag), Stress (S9, temp-as-modifier only), Readiness (RD10, "off your baseline" framing), Trends (T5, the temp-minimum circadian cross-check that currently never runs).

### M8 · Presentation substrate — trend + band + decomposition + honest provenance
Every family independently asks for the same shift: **away from an opaque daily scalar, toward a rolling personal baseline, a shaded band, a named decomposition, and time-in-zone.** The connective failures are also shared: Stress's stored value *shadows* the live math so the "how computed" card can misdescribe the shown number; Rest persists a quality blend under WHOOP's `sleep_performance` sufficiency-ratio name; the three readiness engines can point opposite directions with nothing reconciling them; trend math is split-half in one view and position-indexed OLS in another (a "30-day" slope over 8 present days is silently per-observation).
**Fix once, lifts:** the presentation layer of all five families, and it is where NOOP's inspectable-math advantage actually pays off.

---

## 2. Cross-cutting principles (governing law for every score)

1. **Personal baseline, but anchored.** Everything self-relative — never render a population norm (42±15 ms, a fixed 8 h, 0.85) as a *target*. **But** a personal baseline answers "different from my normal," not "healthy"; pair every band with a faint guideline anchor, or NOOP silently optimizes a user toward their own dysfunction (the chronic under-sleeper whose "need" drifts to their deficit).
2. **Right domain before z.** Log-transform skewed metrics (RMSSD, skin-temp) before baselining. A symmetric Gaussian z on skewed data is a correctness bug, not a nicety.
3. **Robust, never naive.** Winsorize, EWMA recency-weight, σ-floor, hard bounds. Plain mean + population SD is banned: one artifact night must not move the baseline, and a tight baseline must not saturate the logistic on a few-bpm move.
4. **Wall-clock, not observation index.** Decay by calendar days; widen uncertainty across gaps. A baseline resumed after a 3-week gap must not weight the pre-gap night as if it were yesterday.
5. **Cold-start honesty / never fabricate.** Every score inherits the `calibrating→provisional→trusted` ladder. Never collapse silently to a midpoint or score off a thin baseline; say "N more nights."
6. **Coverage is a first-class output.** "X of your N waking hours were scoreable." A mostly-unscored day must never read as calm or good; low confidence ≠ low quality.
7. **Resolution matched to the signal — behind its gate.** 5-min epochs for daytime stress, 30 s–1 min for staging/SRI. Finer grain ships *only after* its correctness gate (motion) lands.
8. **Directional signals keep their sign.** Illness/overreach channels (temp, resp) are signed flags surfaced beside the score, never symmetric penalties folded into it.
9. **Trend + band ≫ point estimate.** The daily dot is noise; the rolling trend and band-position carry the signal. Preserve severity-within-band and add hysteresis; never collapse a continuous z into hard flags that flip night-to-night on one noisy input.
10. **Legible provenance.** The shown number and the explanation must always agree — no stored-value shadowing, no borrowing a vendor's term (`sleep_performance`) for a different quantity. Be honest that logistic per-term deltas don't sum to the headline.
11. **Prove it tracks a varying input** (anti-#194). A derived signal earns a gate by demonstrably moving with ground truth, not by matching one vendor once. Correlation to Oura is *similarity to a proxy*, not truth — a regression guard, never the objective function.
12. **Reconcile, don't multiply.** Readiness = Recovery + orthogonal load/context, differing by **scope**, not by re-summing HRV/RHR into a second, disagreeing score. When axes diverge, show the user one line of reason ("recovery solid, but load spiking and sleep short").

---

## 3. Sequenced roadmap

Ranked by **(impact × confidence) ÷ effort**, scoring H=3 / M=2 / L=1 for impact & confidence and L=1 / M=2 / H=3 for effort. The score is shown so the ranking is auditable (consistent with Principle 10).

### The 5 highest-leverage moves (each lifts multiple scores)

> **MOVE A — Wire the code that already exists.** *(Wave 0; highest ROI in the program.)*
> Rigorous methodology is written and tested but disconnected. Each item is a caller/flag change, not new math: **SL1** consistency→Rest (9.0), **T1** population-anchored need (9.0), **S1** `.baselineRelative`→StressView (4.5), **RD1** promote `HRVReadiness` from default-off (4.5), **R8** decide the dead Recovery-Index/Activity-Balance scaffolding (4.0), plus near-free honesty fixes **R4** doc-drift (6.0) and **R7** SDNN config (6.0).

> **MOVE B — Adopt `Baselines.swift` as the universal, log-domain, wall-clock-aware spine.** *(M1+M2.)*
> Threads one engine through Stress-daily, Readiness, Recovery's fixed terms, and Rest; fixes ln-space and calendar decay inside `deviation()` once. Removes the cross-engine domain/baseline incoherence at the root.

> **MOVE C — Sleep-wake detection as a shared service + one personalized sleep-need.** *(M3+M4.)*
> The dependency hub: unblocks Stress's waking window, the SRI engine, the circadian wake-anchor, Rest's 50% duration term, an honest debt ledger, and Readiness's context axis.

> **MOVE D — One confidence/coverage contract, surfaced on every score.** *(M6.)*
> Reuse the existing `ScoreConfidence`/`BaselineState.status`. Low effort, high honesty payoff, and the only defense against the 4.0-vs-5.0 hardware trap and false-calm/false-good days.

> **MOVE E — Motion gating + directional context channels (the correctness gates).** *(M5+M7.)*
> Motion gating makes Stress *correct* (and unblocks finer resolution); signed temp/resp flags make illness detection *possible*. These are gates: without them, finer grain and cardiac-only scoring actively mislabel.

### Dependency graph (what must precede what)

- **Motion gate (S2) → finer epochs (S8).** Ship resolution after the gate or every active epoch reads as stress.
- **Sleep-wake detection (M3) → {Stress waking-window S9, SRI T2, circadian wake-anchor T5}.**
- **Personalized need (SL2/T1) → {honest debt ledger T3, Rest duration term, Readiness context RD6}.**
- **Baseline spine in log-domain (M1/M2) → cross-engine reconciliation (RD9).** The three engines cannot agree until they share domain + baseline.
- **Promote HRVReadiness (RD1) ⟂ swap ReadinessEngine baseline (RD2) — land together,** so the default Readiness isn't the naive path while the good one stays hidden.
- **Confidence types (M6) have no upstream dependency** → schedule early.

### Ranked backlog

| Wave | Change | Family | I×C/E | Notes / dependency |
|---|---|---|---|---|
| **0** | Wire `sleepConsistency` into Rest (kill the constant +5.0) | Sleep | **9.0** | Threading only |
| **0** | Population-anchored, age-floored sleep-need (flip self-referential default) | Trends | **9.0** | Near-one-line; low-effort first step of M3 |
| **0** | Fix `ChargeDrivers` self-contradictory doc | Recovery | **6.0** | Honesty contract in a transparency file |
| **0** | Give Apple-Watch SDNN its own baseline config (not RMSSD-tuned) | Recovery | **6.0** | Localized |
| **0** | Confidence/warm-up gating on Readiness card | Readiness | **6.0** | Types already exist (M6) |
| **0** | Non-clinical presentation guardrails (framing + persistent-abnormal → clinician) | Readiness | **6.0** | Copy/framing + one check |
| **0** | Cold-start gate on sleep need/debt surfaces | Trends | **6.0** | Mirrors baseline ladder (M6) |
| **1** | Wire `.baselineRelative` intraday path (r≈0.6 vs shipping 0.43–0.53) | Stress | **4.5** | Build daytime_hr/rmssd history folder |
| **1** | Personalize sleep-need threading (adaptive baseline+debt) | Sleep | **4.5** | Fuller form of T1; feeds M3 |
| **1** | Propagate staging confidence; nil-deep → neutral, not 0.5 floor | Sleep | **4.5** | Fixes 4.0-vs-5.0 asymmetry (M6) |
| **1** | Demote stage architecture to low-weight, baseline-relative, floored-neutral | Sleep | **4.5** | Reweight toward duration≈regularity |
| **1** | Parasympathetic-saturation guard (low HRV + low RHR + weak coupling = benign) | Recovery | **4.5** | Correctness gap; inputs already on-device |
| **1** | Make 7-day lnRMSSD trend + band the primary object, % secondary | Recovery | **4.5** | Presentation (M8) |
| **1** | Promote `HRVReadiness` log-SWC band to first-class | Readiness | **4.5** | Land with RD2 |
| **1** | Replace `ReadinessEngine` naive baseline with the log-domain spine | Readiness | **4.5** | M1/M2; land with RD1 |
| **1** | Named contributors + disclosed baseline windows on Readiness | Readiness | **4.5** | Biggest actionability win (M8) |
| **1** | Robust `Baselines` for the daily Stress score (kill naive stats) | Stress | **4.5** | M1 |
| **1** | Unify the three disagreeing daily-Stress transforms; end stored-value shadowing | Stress | **4.5** | Provenance (M8) |
| **1** | Coverage + cold-start status on both Stress surfaces | Stress | **4.5** | M6 |
| **1** | SRI engine (200·mean(state[t]==state[t+24h])−100) + midpoint-SD companion | Trends | **4.5** | Needs M3 epochs |
| **1** | Recency-weighted, capped, asymmetric debt ledger; collapse two definitions | Trends | **4.5** | Needs personalized need |
| **1** | Baseline band + guideline anchor + persistence-gated (≥2–3 day) alerting | Trends | **4.5** | Core presentation contract (M8) |
| **1** | Decide Recovery-Index/Activity-Balance: wire-with-attribution or delete | Recovery | 4.0 | Keep behavioral load out of morning Charge (WHOOP discipline) |
| **2** | **Motion gate on intraday Stress** (mask, don't discount; post-exercise shadow) | Stress | 3.0 | **Gate** — precedes S8; M5 |
| **2** | Split skin-temp/resp into signed illness/overreach flag | Recovery | 3.0 | M7 |
| **2** | Personalize `sleepPerfCenter`/`skinTempScaleC` | Recovery | 3.0 | M1 extension |
| **2** | Log-transform HRV in `deviation()` | Recovery | 3.0 | M2; shared with RD2/T9 |
| **2** | Continuous 0–100 Readiness (severity + hysteresis) backing the 5-way Level | Readiness | 3.0 | M8 |
| **2** | Give Rest a learned baseline where it enters recovery | Sleep | 3.0 | M1 |
| **2** | Fix circadian wiring (robust wake-hour, wire temp-min, motion activity input) | Trends | 3.0 | Needs M3/M5 |
| **2** | True rolling-baseline Stress trend (each day vs its own contemporaneous norm) | Stress | 3.0 | M8 |
| **3** | Oura-style time-in-zone daily Stress rollup from gated daytime epochs | Stress | 2.0 | Needs motion gate |
| **3** | Sufficiency-ratio vs quality-blend: stop misnaming `sleep_performance` | Sleep | 2.0 | M8 |
| **3** | Main-night block sanity check (median-HR/duration plausibility) | Sleep | 2.0 | Cheap guardrail |
| **3** | Readiness = Charge + orthogonal load/context (scope, not re-summing) | Readiness | 2.0 | Principle 12 |
| **3** | Weighted coupled HRV↓&RHR↑ term + trend slopes into verdict | Readiness | 2.0 | — |
| **3** | EWMA-ACWR (Williams/Menaspa) replacing biased rolling-average ACWR | Readiness | 2.0 | Context, not a gate |
| **3** | Reconcile the three engines on one domain; one-line divergence reason | Readiness | 2.0 | Needs M1/M2 first |
| **3** | Unify trend math (Theil-Sen/OLS on wall-clock days) + CI band + reliability wt | Trends | 2.0 | M8 |
| **3** | Wall-clock-aware `Baselines` decay across gaps | Trends | 2.0 | M1 internal |
| **3** | ln-space HRV in `Baselines.deviation` | Trends | 2.0 | Same edit as R6/RD2 |
| **3** | 5-min Stress epochs + multi-window RMSSD averaging | Stress | 1.3 | **Only after** motion gate |
| **3** | Percentile-band staging + absolute/personal anchors | Sleep | 1.3 | Touches classifier core; needs backtest |
| **3** | Confounder tags (journal-sourced); soften uncited 58% anchor | Recovery | 1.3 | noop-cloud MCP as tag source |
| **3** | Sleep-detection waking window + temp as slow modifier | Stress | 1.0 | Needs M3 |
| **Exp** | Freq-domain HRV proxy (Lomb-Scargle / AR) as instrumentation | Sleep/Stress | 0.7 | Behind Experimental until it tracks a varying input |
| **Exp** | Integrated longitudinal fusion (debt × misalignment × baseline dev) | Trends | 0.7 | Exploratory; never a gate on other scores |

**Practical wave read:** Wave 0 is a single afternoon of wiring and framing that measurably improves four families. Waves 1–2 are the substance (baseline spine, sleep-need, confidence, motion gate). Wave 3 is presentation polish and reconciliation. "Exp" items ship dark until validated.

*Cross-platform note:* many recs carry a "Kotlin twin required" caveat as an effort driver. Per the owner's standing position (Swift-only; Kotlin twins are pure-policy transcription or deferred), that caveat should **not** inflate the effort ranking above — treat parity as a mechanical follow-up or a deferred doc burden, not a blocking gate.

---

## 4. Validation strategy

**Owner assets:** ~2 yr of Oura history (backtest baseline), a live WHOOP 5.0 app (companion spot checks), WHOOP 4.0 nights (the hardware-asymmetry cases), and the noop-cloud MCP journal (confounder tags). **Governing discipline:** correlation to Oura is *similarity to a proxy, not ground truth* — use it to catch regressions and adjudicate A/B swaps, never as the objective function (do not overfit to Oura; matching WHOOP is equally acceptable since NOOP is a WHOOP companion, and the real goal is rigorous, actionable methodology). Every **new** derived signal must prove it **tracks a varying input** before it gates anything.

### 4.1 The replay harness (the workhorse)
Run **old path vs new path** over the full 2 yr, emitting per-day: both values, the Oura equivalent, and (for spot days) the WHOOP value. Report **r, MAE, bias, coverage, and the distribution shift.** This is exactly how `.baselineRelative` was already validated (r≈0.6 vs 0.43–0.53) — that precedent is the template, and A/B-over-history is the cleanest form of validation because the owner's own data adjudicates.

| Change class | Oura reference | WHOOP spot check | Success = (direction, not just higher r) |
|---|---|---|---|
| Stress intraday / daily | Daytime stress; **time-in-zone** (secs in top/bottom quartile, in Oura API) | WHOOP stress | Higher r vs Oura *and* coverage reported; motion-gated version must **not** score exertion hours |
| Rest / staging | Sleep score, stages, efficiency | Sleep performance | Architecture demotion must **narrow the 4.0-vs-5.0 gap**, barely move full-signal nights |
| Recovery / Readiness | Readiness | Recovery % | Saturation guard must **flip** low-HRV+low-RHR+weak-coupling days, leave others put |
| Sleep-need / debt | Oura need/debt tiers | — | Population anchor must **increase** debt for chronic under-sleepers, not well-slept users |
| SRI / regularity | Oura regularity if exposed, else midpoint-SD | — | Must **drop** across known-irregular stretches (face validity) |
| Circadian phase | Bedtime / midpoint + **skin-temp minimum** | — | Motion-based phase must corroborate the temp-min cross-check (which currently never runs) |

### 4.2 Beyond correlation — the checks that catch what r hides
- **Directional / invariance tests.** Several fixes are meant to move a *subset* in a specific direction, not raise global r. Verify the intended subgroup shift (the four rows above), because a change that correctly re-scores only the fittest days or only under-sleepers will show a *tiny* global r delta while being exactly right.
- **Cold-start replay.** Truncate history to the first N nights; confirm each score surfaces *provisional/calibrating* rather than a confident number or a midpoint collapse.
- **Coverage / hardware-asymmetry replay.** On WHOOP-4.0 / no-resp nights, confirm the new confidence badge widens the band and that Rest no longer structurally floors — and that the sparse-motion "default-to-sleep" path isn't *inflating* a poor night.
- **Confounder cross-check (noop-cloud MCP).** Use journaled alcohol/late-meal/illness/travel days to confirm low mornings pair with a plausible benign cause and that the signed temp flag fires on illness but **not** on benign cooling.

### 4.3 WHOOP-app spot checks (targeted, not bulk)
Pick ~10–20 representative days — a hard-training block, an illness, a travel week, a normal week — and eyeball NOOP vs the WHOOP app for recovery %, sleep performance, stress, and stages. This catches gross method divergences the aggregate correlation smooths over, and it is the right tool for the companion-parity question that Oura history can't answer.

### 4.4 New-signal gate (anti-#194) and regression pinning
- **"Tracks a varying input" before any gate/default:** SRI must move monotonically across a deliberately irregular stretch; the freq-domain HF proxy must separate a REM-heavy from a deep-heavy night; the continuous Readiness score and Recovery-Index slope must respond to a manipulated input. Until proven, they stay instrumentation/Experimental.
- **Golden-file pinning:** extend the existing unit tests (which already cover the dormant `.baselineRelative`, `Recovery-Index`, and `HRVReadiness` paths) into golden replay outputs so the harness results are regression-locked. Byte-identical Kotlin-twin parity is a *check where twins are maintained*, not a release blocker given the Swift-first posture.

---

**Bottom line:** the program is ~8 machines, not 5 scores. Wave 0 (wire what exists + free honesty fixes) buys four-family improvement for almost no effort; Moves B–E (baseline spine, shared sleep-need, confidence contract, motion gate) are the structural backbone that the rest hangs off; and the whole thing is validated by replaying the owner's own 2 yr against itself — using Oura as a regression net and directional test, WHOOP as the companion spot check, and "tracks a varying input" as the gate that keeps NOOP honest.
