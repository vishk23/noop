# Sleep staging + Rest quality score

# Sleep Staging + Rest-Quality Score — Target Methodology for NOOP

NOOP is WHOOP-class hardware (wrist/strap PPG + accelerometer + R-R + skin temperature), a WHOOP 5.0 companion that also backtests against imported Oura history. This doc defines how the **sleep-staging layer** and the **rest-quality score** *should* be computed and presented — reconciling the medical evidence with what Oura and WHOOP actually do — as the target to move NOOP's real Swift toward. The honest thesis up front: **the score's actionable weight belongs on the three dimensions that are both well-measured and medically anchored — duration-vs-need, efficiency/continuity, and regularity — while stage architecture (deep/REM) is demoted to descriptive display with visible uncertainty.** NOOP today does close to the opposite: it hard-codes need, zeroes out regularity, and lets its noisiest estimate (deep/REM) drive 20% of the number.

---

## Part 1 — Target Methodology

### 1.1 What the score should answer — and the one genuinely unresolved choice

There are two coherent things a sleep score can mean, and the vendors split on them:

- **Oura** scores *intrinsic sleep quality* — a weighted blend of duration, efficiency, restfulness, REM %, deep %, latency, and circadian timing [15][18].
- **WHOOP** scores *sufficiency for load*: `Sleep Performance = Total Sleep ÷ Sleep Need`, a pure ratio, and deliberately keeps REM/deep *out* of the score, surfacing them separately as "Restorative Sleep" [16][20][23].

**There is no single right answer here — it is a product-philosophy choice, and it should be made explicitly rather than by accident.** WHOOP's design is actually *more* aligned with the medical evidence: the NSF/Ohayon 2017 consensus could not define an "optimal" architecture and issued only *negative* findings (REM ≥41% does not indicate good quality; N3 ≤5% does not — the latter specifically in older adults), explicitly rebutting "more REM/deep is always better" [10]. A score that directly rewards higher deep/REM % (Oura's approach, and NOOP's current restorative term) is scoring a quantity with **no validated optimum**, using the **least reliable** sensor estimate. The defensible target for NOOP — a WHOOP companion whose owner considers matching WHOOP sensible — is to **lead with a WHOOP-style sufficiency ratio, layer the RU-SATED quality dimensions that have real evidence, and treat architecture as descriptive context, not a scored target.** Whichever is chosen, the number must be *named* for what it computes; NOOP currently persists an architecture-weighted quality blend under the name `sleep_performance` (WHOOP's word for a sufficiency ratio), which is an incoherent hybrid (see §2).

### 1.2 The staging layer: resolution, feature set, and the accuracy ceiling

**Resolution.** Stage at **30-second epochs** into W / Light(N1+N2) / Deep(N3) / REM — the AASM reference grid [17], and what both Oura and WHOOP use. NOOP already does this; keep it.

**Feature set (target).** The physiology is real and separable: NREM/deep = parasympathetic dominance, low/stable HR, regular breathing, near-zero motion; REM = sympathetic activation, variable HR/breathing, muscle atonia; wake = motion + elevated HR [8][9]. A defensible on-device feature vector per epoch: mean HR, time-domain HRV (RMSSD/SDNN), **a frequency-domain autonomic proxy (HF / LF-HF)**, respiratory rate + variability, Cole-Kripke activity counts, body position, and skin-temperature trend. NOOP has all of these except frequency-domain HRV (no neurokit2/scipy on-device → RMSSD-only), which is the single feature that most directly separates NREM from REM; recovering an HF/LF-HF proxy via a lightweight Lomb-Scargle or AR spectral estimate on the tachogram is the highest-value staging upgrade available within the no-cloud constraint.

**Model class — a real transparency-vs-accuracy tradeoff.** The literature favors sequence models (HMM/CRF or LSTM/TCN) with temporal priors that emit **per-epoch posterior probabilities** [9]. NOOP instead uses a transparent, auditable percentile-band classifier + median smoothing + physiology reimposition. This is a legitimate choice that serves NOOP's honest/explainable philosophy — a black-box net fights that value — but it comes at an accuracy cost and, as built, is **self-referential** (per-night P25/P70 bands over that night's own epochs) with no absolute or personal anchor. The target keeps the interpretable classifier but adds (a) personal/absolute anchors alongside per-night percentiles, and (b) an explicit per-epoch confidence output.

**The accuracy ceiling is low and irreducible — design for it.** Even expert human scorers only reach 82.6% overall agreement, with per-stage κ of just W 0.70 / N1 0.24 / N2 0.57 / N3 0.57 / R 0.69 — N1 is near chance, and *deep and REM are only "moderate" between humans* [6][7]. On top of that, EEG-free devices infer stages from autonomic proxies: research-grade wrist PPG+accel reaches κ≈0.62 / ~76% 4-class [2], but commercial devices land at κ≈0.21–0.53 [1][2]. **NOOP is WHOOP-class hardware, so WHOOP-class error is the realistic expectation:** independent WHOOP 4.0 vs PSG returned κ=0.37, sleep sensitivity 93.6% but wake specificity 40.1%, and systematically **overestimated deep by ~31 min and REM by ~15 min** [22]; the earlier Miller 2020 WHOOP validation (n=12, 86 sleeps — *not* the sometimes-cited n=6) gave ~63% 4-class agreement, κ≈0.47 [5]. Oura stages *directionally* better (~79% 4-stage agreement — but that figure is Oura's own marketing [19], and its main independent-looking validation is **manufacturer-funded** with a published rebuttal [3][4], with per-stage *sensitivity* for deep only ~64% and REM ~73%). **Do not inherit any vendor headline as a NOOP capability claim: NOOP's own staging is unvalidated against PSG until proven, and per CLAUDE.md's own rule a single "matched WHOOP" night is not validation.** Deep-minute is the least reliable output of the whole pipeline — which is exactly why it should not drive the score.

**Systematic bias to expect.** Consumer devices have high sleep sensitivity and low wake specificity, so at the epoch level they mislabel wake as sleep (over-call sleep, under-detect brief awakenings) [1]; a 24-study/798-subject meta-analysis reported pooled biases on the order of TST −16.9 min, efficiency −4.7%, WASO +13.3 min [14] (directionally illustrative of systematic error rather than a correction to hard-code — corrections tuned on one cohort do not reliably transfer).

### 1.3 The rest-quality composite: an RU-SATED backbone

Anchor the composite to Buysse's validated multidimensional framework — **R**egularity, **S**atisfaction, **A**lertness, **T**iming, **E**fficiency, **D**uration [12] — keeping only the dimensions a wearable can honestly measure, weighted by strength of evidence:

**(a) Duration vs. personal need — the dominant, most-actionable lever.** Adults need 7–9 h [11]. This should be the largest term, scored against a **personalized** need (§1.4), not a population constant. NOOP already makes this 50% of the score — correct weight, wrong denominator (fixed 8 h).

**(b) Efficiency & continuity.** Firm, evidence-based thresholds exist: efficiency ≥85%, latency ≤15 min (≤30 acceptable), WASO ≤20 min, ≤1 awakening >5 min [10]. Score efficiency and continuity here — but **guard against the sensor artifact**: when wake is under-detected on sparse-motion nights, efficiency pins spuriously to ~1.0, so this term must be down-weighted or widened when wake-detection confidence is low.

**(c) Regularity — weight it heavily; it is the best-evidenced dimension of all.** Day-to-day sleep-timing consistency (Sleep Regularity Index) is a **stronger** all-cause and cardiometabolic mortality predictor than duration: most-regular vs least-regular quintile shows 30% lower all-cause (HR 0.70) and 38% lower cardiometabolic (HR 0.62) mortality [13]. Both vendors under-use this (Oura folds a weak "Timing" term; WHOOP keeps consistency entirely outside Sleep Performance). NOOP has a working regularity signal (`VitalityEngine.sleepConsistency`) but **does not feed it into the score at all** — the largest single missed opportunity in the current design.

**(d) Architecture (deep + REM) — descriptive, NOT a "more-is-better" scored target.** This is where NOOP must diverge from Oura and align with the science. Because there is no validated optimum [10] and deep/REM are the noisiest estimates [22], architecture should be shown descriptively (multi-night bands against the user's *own* baseline) with visible uncertainty, and at most contribute a small term that flags *extreme baseline-relative deviation* (not distance from an invented ideal). If any architecture term survives in the score, it must (i) carry low weight, (ii) be baseline-relative, and (iii) collapse to "unknown/neutral" — not to a low score — when staging confidence is low.

**(e) Timing (circadian).** Midpoint alignment to chronotype is a legitimate minor contributor [18]; keep it small and personalized, never a fixed 00:00–03:00 clock target.

**Combination.** Keep it a **transparent, inspectable weighted sum** with every sub-score traceable — this is a genuine NOOP advantage over both vendors' black boxes. A defensible starting weight vector, evidence-ranked: **Duration 0.40, Regularity 0.20, Efficiency/Continuity 0.20, Architecture 0.10 (baseline-relative, floored-neutral on low confidence), Timing 0.10** — the exact numbers are a judgment call NOOP must own and document, but the *ordering* (duration ≈ regularity ≫ architecture) is what the evidence dictates.

### 1.4 Adaptive sleep need — adopt WHOOP's structure, choose NOOP's own coefficients

WHOOP's most defensible idea is a **nightly-recomputed, load-aware Sleep Need**, and it publishes the *structure* literally in its API: `sleep_needed = baseline + need_from_recent_strain + need_from_sleep_debt − need_from_recent_nap` [20][21]. The **coefficients are not published by either vendor** — WHOOP's f(strain)/f(debt)/baseline-learning and Oura's contributor weights are genuinely proprietary [3][15]. So NOOP can adopt the **baseline/strain/debt/nap decomposition** (it is documented and physiologically sensible) but must make every coefficient its **own defensible, documented choice** — neither vendor's can be copied because neither is disclosed. A staged path: **v1** = personalize `baseline` from the user's own trailing sleep (a real per-user need beats a fixed 8 h even with no strain/debt terms); **v2** = add debt (rolling deficit vs need) and a modest strain term, each surfaced explicitly so the user sees *why* tonight's need moved.

### 1.5 Presentation: a decomposition with uncertainty, not a bare number

- **Lead with the decomposition, not the rollup.** Show the named contributors (duration, regularity, efficiency, architecture, timing) each explainable and, ideally, user-correctable — plus, if adaptive need is adopted, the baseline/strain/debt/nap split. The single 0–100 is a summary *of* those parts, not a substitute. This is the honest synthesis of Oura's transparency (named contributors) and WHOOP's actionability (adaptive need) that neither vendor fully delivers.
- **Attach per-night confidence.** A no-resp WHOOP 5.0 night and a full-signal night must not surface an identical-looking number. Use a sensor-class-aware confidence tier to widen the band and badge low-confidence nights.
- **Never state stage minutes as false precision.** Show "~1 h deep (low confidence)" with a band, not "47 min of deep sleep" — the estimate cannot support the third significant figure [7][22].
- **Prefer multi-night aggregates for architecture** over single-night stage minutes, which carry irreducible label noise.
- **Baseline-relative flags, not absolute ideals.** Reserve architecture callouts for extreme deviations from the user's own history (echoing Ohayon's only two consensus findings, REM ≥41% / N3 ≤5% [10]), never "get more deep sleep."
- **Label everything non-clinical.** Staging cannot screen for sleep disorders; PPG+accel misses apneas and arousals and degrades on exactly the fragmented nights users most want insight on [1]. State this plainly.

### 1.6 Where the honest answer is "no single right answer"

| Choice | Option A | Option B | Honest resolution |
|---|---|---|---|
| What the score means | Intrinsic quality (Oura) | Sufficiency for load (WHOOP) | Product choice, not a fact; lead with sufficiency, layer quality, **name it honestly** |
| Architecture in the score | Directly scored (Oura, NOOP-today) | Excluded, shown separately (WHOOP) | Science favors B; demote to descriptive + floored baseline-relative flag |
| Sleep-need model | Static/age-based (Oura) | Adaptive (WHOOP) | Adaptive is more actionable but coefficients are unpublished → NOOP's own defensible choice |
| Staging model | Interpretable rules (NOOP-today) | Learned sequence model | Transparency vs accuracy; keep rules but add anchors + per-epoch confidence |
| Bias correction | Add back WASO/TST bias | Leave raw | Corrections don't reliably transfer across cohorts [14] → prefer confidence bands over point corrections |

---

## Part 2 — Gap Analysis: NOOP today vs. the target

NOOP's staging + rest score are two stacked pure-Swift computations (`SleepStager.swift` → `AnalyticsEngine.Rest.composite`). The composite is `0.50·duration + 0.20·efficiency + 0.20·restorative + 0.10·consistency`, scaled to [0,100] (`AnalyticsEngine.swift:811-848`, verified). The gaps, most severe first:

**G1 — The strongest-evidence dimension (regularity) contributes zero signal.** The live call site `IntelligenceEngine.swift:645` invokes `analyzeDay` without `sleepConsistency`, so it defaults to `nil` → `neutralConsistency = 0.5` (`AnalyticsEngine.swift:809`). The 10% consistency weight is therefore a **constant +5.0 points for every night, every user**. A working regularity signal, `VitalityEngine.sleepConsistency(nightlyHours:)` (`VitalityEngine.swift:102`), already exists and is wired into the separate Vitality path — but not into Rest. The dimension the evidence ranks *above duration* for mortality prediction [13] is dead weight in the headline score.

**G2 — Duration is 50% of the score but measured against a hardcoded 8 h.** The same call site omits `sleepNeedHours`, so it defaults to `Rest.defaultNeedHours = 8.0` (`AnalyticsEngine.swift:305, 799`). The personalization hook *exists in the API* (the param is threaded into `Rest.composite` at L438-449) but is never supplied. A 6 h-need and a 9 h-need person are scored identically on half the score. No adaptive strain/debt term exists at all.

**G3 — The noisiest estimate drives 20% of the score, against an above-population target.** The restorative term is `clamp01((deep+REM)/tst / 0.50) · deepFactor`, with `deepFactor = 0.5 + 0.5·clamp01((deep/tst)/0.13)` (`AnalyticsEngine.swift:801-840`). Three problems: (i) it directly rewards higher deep/REM %, which Ohayon explicitly declines to endorse [10]; (ii) it is built on deep/REM, the least reliable stage outputs on wrist-class hardware [22]; (iii) `restorativeTarget = 0.50` sits *above* the healthy-adult deep+REM share (~33–48%), so even textbook architecture caps this sub-score near 0.80 — structurally docking normal sleepers.

**G4 — Rest has no learned baseline anywhere in the chain.** Into recovery, Rest enters centered on a **fixed** `sleepPerfCenter = 0.85` (`RecoveryScorer.swift:63, 237`), unlike the HRV/RHR/resp terms which use per-user `DriverBaseline` z-scores. A user whose honest normal is 0.78 is permanently "below center." Combined with G1/G2/G3, the live composite is also **range-compressed**: consistency is frozen at 0.05, efficiency rarely hits 1.0, and restorative caps ~0.80, so a genuinely excellent night lands near 89–95 and hovers just above the fixed 0.85 recovery center.

**G5 — A hardware class is structurally penalized independent of true quality.** On WHOOP 5.0 no-resp nights the resp-based REM rule falls back to an HR-only bar and REM commonly funnels toward 0% (a `REMFunnelDiagnostic` exists precisely for this); deep is under-detected too, so `(deep+REM)/tst` and `deepFactor` both collapse and restorative floors near the `deepFloorFactor = 0.5` floor — depressing Rest for one hardware class on physiology it simply can't see. Conversely, sparse-motion nights over-count duration *and* pin efficiency near 1.0 (wake under-detected), double-crediting two terms on a poor night.

**G6 — The surfaced value carries no confidence.** The composite is a single `round2` point estimate; a `DayResult` confidence tier exists but the composite ignores it. A motion-only 4.0 night and a full-signal 5.0 night surface the same-looking 0–100.

**G7 — Staging thresholds are self-referential.** Stage-2 cut points are per-night percentiles (P25/P70 HR, etc.) over that night's own CK-sleep epochs (`SleepStager.classifyEpochs`), with the HR sleep baseline just the day-median (`hrBaseline()`). Identical physiology can be labeled differently depending on the night's own distribution — no absolute or personal calibration, no cold-start handling.

**G8 — RMSSD-only autonomic features.** No frequency-domain HRV (HF/LF-HF omitted) weakens the NREM/REM discrimination the restorative term depends on — so the medically dubious 20% term is *also* built on a weakened feature set.

**G9 — Main-night selection is learned but unchecked.** `habitualMidsleep` picks *which* block is scored, but the block's score has no sanity check; a long still off-wrist stretch that clears the gates can silently become the headline Rest.

---

## Part 3 — Actionability Rubric

A score is only useful if it tells the user something they can *change*. Rank every surfaced element by whether it maps to a controllable, evidence-backed action:

| Dimension | What the user can DO | Evidence strength | How to present |
|---|---|---|---|
| **Duration vs. need** | Go to bed earlier / protect a longer window; repay debt | High [11] — the dominant lever | Minutes short of *personal* need + the debt trend; "≈35 min short of your need" |
| **Regularity** | Keep wake/sleep times consistent day-to-day | **Highest** [13] — outpredicts duration for mortality | Consistency trend + "your midpoint drifted 90 min vs your 14-day average" |
| **Efficiency / continuity** | Address fragmentation: caffeine/alcohol timing, room temp, screens | High [10] | Efficiency % + awakenings, with a low-confidence badge on sparse-motion nights |
| **Architecture (deep/REM)** | *Almost nothing directly* — no validated lever | Low [10]; noisiest estimate [22] | **Descriptive only**: multi-night bands vs the user's own baseline, with uncertainty; extreme-deviation flag, never "get more deep" |
| **Sufficiency for load** (if adaptive need adopted) | Anticipate tonight's higher need after hard days | Medium (structure documented, coefficients NOOP's own) [20][21] | Baseline/strain/debt/nap breakdown: "hard day added ~40 min; you carry ~1.5 h debt" |
| **Confidence** | Know when *not* to over-read a night | High (irreducible single-night noise) [7] | Per-night confidence badge; widen bands, suppress precise stage minutes on low-confidence nights |

**The honesty rubric (non-negotiables):** (1) Never present stage minutes as exact — bands, not "47 min." (2) Never imply an optimal architecture target or gamify deep/REM. (3) Never let low staging confidence read as *low sleep quality* — unknown architecture must map to neutral, not to a low score (this is G5). (4) Label the whole feature non-clinical; it cannot screen for disorders. (5) Put the visible, actionable emphasis on the levers that are both controllable and evidence-backed — duration, regularity, continuity — and let the user *see the decomposition* rather than a single opaque number.

---

## Sources

1. Chinoy et al. 2021, *SLEEP* — consumer devices vs PSG; high sleep sensitivity, low wake specificity; staging "mixed and often poor." https://academic.oup.com/sleep/article/44/5/zsaa291/6055610
2. Fonseca et al. 2021, *Nature & Science of Sleep* ("It's All in the Wrist") — wrist PPG+accel 4-class κ 0.62 / 76.4%; commercial κ 0.21–0.53. https://www.tandfonline.com/doi/full/10.2147/NSS.S306808
3. Svensson et al. 2024, *Sleep Medicine* — Oura Gen3 + OSSA 2.0, 96 subjects / 421,045 epochs; sleep/wake sens 94.4–94.5% / spec 73–74.6%; per-stage deep sens ~64% / REM ~73%. **Manufacturer (Oura)-funded — not independent.** https://www.sciencedirect.com/science/article/pii/S1389945724000200
4. Published Comment on Svensson/OSSA 2.0 — flags Oura funding and that group-level agreement masks individual-level error. https://www.researchgate.net/publication/379195209
5. Miller et al. 2020, *J Sports Sci* — WHOOP vs PSG, n=12 / 86 sleeps; 4-stage ~63%, κ≈0.47 (also PMC8226553). https://www.tandfonline.com/doi/full/10.1080/02640414.2020.1797448
6. Rosenberg & Van Hout 2013, *JCSM* — AASM inter-scorer reliability: overall 82.6%, N1 63.0%, N3 67.4%. https://jcsm.aasm.org/doi/full/10.5664/jcsm.2350
7. Inter-rater reliability meta-analysis, *JCSM* — per-stage expert κ: W 0.70, N1 0.24, N2 0.57, N3 0.57, R 0.69. https://jcsm.aasm.org/doi/abs/10.5664/jcsm.9538
8. Tobaldini et al. 2013, *Front. Physiology* — HRV autonomic signatures across sleep stages. https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2013.00294/full
9. Radha et al. 2019, *Scientific Reports* — HRV-based (LSTM) sleep staging feasibility. https://www.nature.com/articles/s41598-019-49703-y
10. Ohayon et al. 2017, *Sleep Health* (NSF) — continuity thresholds; architecture "uncertain," only negative findings (REM ≥41% / N3 ≤5%, latter older-adult-specific). https://www.sleephealthjournal.org/article/S2352-7218(16)30130-9/abstract
11. Hirshkowitz et al. 2015, *Sleep Health* (NSF) — duration recommendations (7–9 h adults). https://www.sleephealthjournal.org/article/S2352-7218(15)00160-6/abstract
12. Buysse — RU-SATED multidimensional sleep-health framework. https://pmc.ncbi.nlm.nih.gov/articles/PMC7289662/
13. Windred et al. 2024, *SLEEP* (UK Biobank) — Sleep Regularity Index outpredicts duration; 30% lower all-cause / 38% lower cardiometabolic mortality. https://academic.oup.com/sleep/article/47/1/zsad253/7280269
14. 2024 meta-analysis (24 studies / 798 subjects) — pooled biases TST −16.9 min, efficiency −4.7%, WASO +13.3 min. https://pmc.ncbi.nlm.nih.gov/articles/PMC11874098/
15. Oura Sleep Score composition (support). https://support.ouraring.com/hc/en-us/articles/360025445574-Sleep-Score
16. WHOOP Sleep Performance definition (support). https://support.whoop.com/s/article/WHOOP-Sleep
17. AASM scoring manual FAQ — 30-s epochs, W/N1/N2/N3/R, N3 ≥20% slow-wave. https://aasm.org/resources/pdf/faqsscoringmanual.pdf
18. Oura Sleep Contributors + published target ranges (population heuristics, not clinical cutoffs). https://support.ouraring.com/hc/en-us/articles/360057792293-Sleep-Contributors
19. Oura OSSA staging blog — **vendor marketing**: >1,200 nights, "79% 4-stage agreement," "vs 60–65% wrist wearables." https://ouraring.com/blog/new-sleep-staging-algorithm/
20. WHOOP Sleep Need model (baseline + strain + debt − naps). https://www.whoop.com/us/en/thelocker/how-much-sleep-do-i-need/
21. WHOOP developer API — `sleep_needed` decomposition fields (documented structure; coefficients undisclosed). https://developer.whoop.com/docs/developing/user-data/sleep/
22. WHOOP 4.0 vs PSG 2025, *SLEEP Advances* (Oxford) — κ=0.37, sens 93.6% / spec 40.1%, deep +31 min, REM +15 min, SOL −11 min. https://academic.oup.com/sleepadvances/article/6/2/zpaf021/8090472
23. WHOOP Restorative Sleep = deep + REM, reported separately from Sleep Performance. https://www.whoop.com/us/en/thelocker/what-is-restorative-sleep/
24. WHOOP sleep-debt definition + repayment guidance. https://www.whoop.com/us/en/thelocker/understanding-sleep-debt-impact-on-performance-and-recovery/

## Ranked recommendations

| # | Change | Impact | Conf | Effort |
|---|---|---|---|---|
| 1 | Wire the existing regularity signal into the Rest score: pass VitalityEngine.sleepConsistency(nightlyHours:) as the sleepConsistency argument at the analyzeDay call site (IntelligenceEngine.swift:645), replacing the nil→neutralConsistency=0.5 default. | high | high | low |
| 2 | Personalize sleep need instead of the hardcoded 8 h: thread a per-user need into analyzeDay's sleepNeedHours (currently omitted at IntelligenceEngine.swift:645, defaulting to Rest.defaultNeedHours=8.0). Start with a trailing personal baseline; stage toward a WHOOP-style adaptive baseline+debt(+strain) decomposition with NOOP's own documented coefficients. | high | high | medium |
| 3 | Propagate per-night staging confidence into the surfaced score and fix the hardware-class asymmetry: use the existing DayResult confidence tier to badge/widen the band on low-confidence nights (no-resp WHOOP 5.0, sparse-motion 4.0), and when deep/REM are low-confidence treat architecture as UNKNOWN (deepSeconds=nil → deepFactor 1.0 neutral path) rather than letting restorative collapse to the deepFloorFactor=0.5 floor. | high | high | medium |
| 4 | Demote stage architecture from a fixed-target 20% scored term to a low-weight, baseline-relative, floored-neutral contributor (or descriptive-only). Reduce wRestorative, replace the fixed restorativeTarget=0.50 / deepShareTarget=0.13 'more-is-better' curve with deviation from the user's own trailing baseline, and reallocate weight toward duration/regularity/continuity. | high | high | medium |
| 5 | Give Rest a learned per-user baseline where it enters recovery: replace the fixed sleepPerfCenter=0.85 / sleepPerfScale=0.12 in RecoveryScorer.swift (L63,65,237) with a per-user DriverBaseline z-score, matching how the HRV/RHR/resp terms already work. | medium | high | medium |
| 6 | Resolve the quality-vs-sufficiency incoherence: either compute a true WHOOP-style sufficiency ratio (TST ÷ personalized need) as the headline and surface RU-SATED quality contributors beside it, or keep the quality blend but stop naming it sleep_performance. Lead the UI with the decomposition (named contributors + adaptive-need breakdown), not the bare rollup. | medium | medium | medium |
| 7 | Add a sanity check on the learned main-night block before it becomes the headline Rest: validate the selected block against habitual duration and in-run HR (e.g. reject or flag a block whose median HR or duration is implausible for sleep) rather than trusting the accept-ladder alone. | low | medium | low |
| 8 | Add absolute and/or personal-trailing anchors to the Stage-2 percentile-band classifier (SleepStager.classifyEpochs), supplementing the per-night P25/P70 cut points and the day-median HR baseline (hrBaseline()) so identical physiology is not labeled differently night to night. | medium | medium | high |
| 9 | Prototype a lightweight on-device frequency-domain HRV proxy (Lomb-Scargle or AR spectral estimate on the R-R tachogram → HF, LF/HF) and land it first as instrumentation beside the incumbent features, validated per CLAUDE.md's 'tracks a varying input' rule before feeding staging. | medium | low | high |

### Rationale detail

1. **Wire the existing regularity signal into the Rest score: pass VitalityEngine.sleepConsistency(nightlyHours:) as the sleepConsistency argument at the analyzeDay call site (IntelligenceEngine.swift:645), replacing the nil→neutralConsistency=0.5 default.** — Regularity is the single best-evidenced sleep dimension for mortality (outpredicts duration; 30% all-cause / 38% cardiometabolic reduction, Windred 2024 [13]), yet it currently contributes a constant +5.0 points to every night for every user. Both the score param (AnalyticsEngine.swift:305-306, threaded to Rest.composite) and the signal (VitalityEngine.swift:102) already exist and are used elsewhere — this is a threading change, not new math. Highest evidence-to-effort ratio in the whole design.

2. **Personalize sleep need instead of the hardcoded 8 h: thread a per-user need into analyzeDay's sleepNeedHours (currently omitted at IntelligenceEngine.swift:645, defaulting to Rest.defaultNeedHours=8.0). Start with a trailing personal baseline; stage toward a WHOOP-style adaptive baseline+debt(+strain) decomposition with NOOP's own documented coefficients.** — Duration-vs-need is 50% of the score and the dominant actionable lever (Hirshkowitz [11]), but is measured against a fixed 8 h — a 6 h-need and 9 h-need person are scored identically. WHOOP's baseline/strain/debt/nap structure is documented [20][21] and the more defensible, load-aware target; only the coefficients are proprietary, so they must be NOOP's own choice. v1 (personal baseline) is low effort; the adaptive terms are medium.

3. **Propagate per-night staging confidence into the surfaced score and fix the hardware-class asymmetry: use the existing DayResult confidence tier to badge/widen the band on low-confidence nights (no-resp WHOOP 5.0, sparse-motion 4.0), and when deep/REM are low-confidence treat architecture as UNKNOWN (deepSeconds=nil → deepFactor 1.0 neutral path) rather than letting restorative collapse to the deepFloorFactor=0.5 floor.** — Today a motion-only night and a full-signal night surface an identical-looking 0-100 (G6), and no-resp nights funnel REM→0 so restorative structurally floors, depressing Rest for one hardware class independent of true quality (G5, REMFunnelDiagnostic exists for exactly this). Single-night stage estimates carry irreducible noise even between human experts [7]; honest presentation requires visible uncertainty, and low confidence must not read as low quality. The nil-deep neutral path already exists in Rest.composite.

4. **Demote stage architecture from a fixed-target 20% scored term to a low-weight, baseline-relative, floored-neutral contributor (or descriptive-only). Reduce wRestorative, replace the fixed restorativeTarget=0.50 / deepShareTarget=0.13 'more-is-better' curve with deviation from the user's own trailing baseline, and reallocate weight toward duration/regularity/continuity.** — Ohayon/NSF 2017 could not define an optimal architecture and explicitly rejects 'more REM/deep is always better' [10]; deep/REM are also the least reliable estimates on wrist-class hardware (WHOOP overestimates deep +31/REM +15 min [22]). NOOP's restorativeTarget=0.50 even sits above the healthy deep+REM share, docking normal sleepers. So the noisiest, least-defensible quantity currently moves 20% of the number (G3). Exact reweight is a documented judgment call, but the direction (architecture ≪ duration≈regularity) is what the evidence dictates.

5. **Give Rest a learned per-user baseline where it enters recovery: replace the fixed sleepPerfCenter=0.85 / sleepPerfScale=0.12 in RecoveryScorer.swift (L63,65,237) with a per-user DriverBaseline z-score, matching how the HRV/RHR/resp terms already work.** — Rest is the only recovery driver with no learned baseline anywhere in the chain (G4); a user whose honest normal is 0.78 is permanently below the fixed 0.85 center. Combined with the range-compression from G1-G3, the score sits in a narrow band barely above center. Personalizing the center removes a systematic per-user bias and makes Rest consistent with the rest of RecoveryScorer.

6. **Resolve the quality-vs-sufficiency incoherence: either compute a true WHOOP-style sufficiency ratio (TST ÷ personalized need) as the headline and surface RU-SATED quality contributors beside it, or keep the quality blend but stop naming it sleep_performance. Lead the UI with the decomposition (named contributors + adaptive-need breakdown), not the bare rollup.** — NOOP persists an architecture-weighted quality blend under the name sleep_performance — WHOOP's term for a pure sufficiency ratio (§1.1). That is an incoherent hybrid, and it imports/prefers WHOOP's own sleep_performance in SleepView, mixing two different meanings under one name. Exposing the decomposition is the honest synthesis of Oura's named transparency and WHOOP's adaptive actionability that neither vendor fully delivers, and plays to NOOP's inspectable-math advantage.

7. **Add a sanity check on the learned main-night block before it becomes the headline Rest: validate the selected block against habitual duration and in-run HR (e.g. reject or flag a block whose median HR or duration is implausible for sleep) rather than trusting the accept-ladder alone.** — habitualMidsleep selects which block is scored but the block's score has no downstream sanity check (G9); a long still off-wrist stretch that clears the detection gates can silently become the headline Rest. Cheap guardrail against a wrong-block score with outsized visible impact.

8. **Add absolute and/or personal-trailing anchors to the Stage-2 percentile-band classifier (SleepStager.classifyEpochs), supplementing the per-night P25/P70 cut points and the day-median HR baseline (hrBaseline()) so identical physiology is not labeled differently night to night.** — Stage thresholds are currently self-referential per-night percentiles with no absolute or personal calibration and no cold-start handling (G7); a low-variability and a high-variability night get the same relative cuts. Personal anchors improve staging stability, which the restorative/efficiency terms both depend on. Higher effort because it touches the classifier core and needs backtest validation.

9. **Prototype a lightweight on-device frequency-domain HRV proxy (Lomb-Scargle or AR spectral estimate on the R-R tachogram → HF, LF/HF) and land it first as instrumentation beside the incumbent features, validated per CLAUDE.md's 'tracks a varying input' rule before feeding staging.** — NOOP has no frequency-domain HRV (RMSSD-only, no neurokit2/scipy), the single feature that most directly separates NREM from REM autonomically [8][9] (G8). Recovering an HF/LF-HF proxy is the highest-value staging feature upgrade within the no-cloud constraint. Confidence is low because it is unproven on this hardware and must not become a default or gate on thin evidence (echoes the withdrawn PPG→HR estimate #194); ship as instrumentation or behind an Experimental toggle until it demonstrably tracks a varying ground truth.

