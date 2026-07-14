# Trends / baselines / longitudinal (incl. sleep debt & circadian)

_Code references below are repo-relative to the checkout root `/Users/vk/VKDEV/NOOP/noop` (branch `puffin-raw-probe`), verified line-by-line against source._

# Trends / Baselines / Longitudinal — Target Methodology for NOOP
### (personal baselines · sleep debt · circadian regularity)

---

## Part 1 — TARGET METHODOLOGY: how this layer *should* work

This is not one score; it is the **reference layer** every other NOOP score leans on. Its job is to convert noisy nightly readings (HRV, RHR, respiratory rate, skin temperature, sleep duration and timing) into three things: (a) a **stable personal reference + meaningful-change signal** per metric, (b) an honest **sleep-debt** accounting against a defensible **need**, and (c) a **circadian-regularity** read that is the single most actionable longitudinal lever in the literature. The science and the two vendors converge on one architecture; the rigor lives in the estimator math, the robustness, and the honesty of presentation — exactly where NOOP can lead.

### 1.1 The core pattern: two timescales, always paired with an anchor

Every credible system keeps a **fast "where am I now"** estimate and a **slow "what is normal for me"** band, and flags only when the *smoothed* fast line leaves the band — never on a single night. Altini/HRV4Training uses a 7-day moving average as state inside a 60-day normal-range band [8]. Oura mirrors this across its Readiness "balance" contributors: a recency-weighted ~14-day recent window vs a ~2–3-month baseline [19][20], and a 90-day personalized sleep-need against a 14-day debt window [11]. WHOOP's Weekly Performance Assessment compares the last week to a trailing 3-week average and adds a demographic-cohort reference [24].

**The non-negotiable design rule** (and NOOP's biggest philosophical risk): a personal baseline answers *"different from **my** normal,"* **not** *"healthy."* A chronically sleep-deprived or high-stress user's baseline normalizes to their dysfunction. So the smoothed line + personal band **must always be drawn against a population/guideline anchor** — 7–9 h for adults [14]; "more-regular-is-protective" for circadian — or NOOP will silently optimize users toward their own bad equilibrium.

### 1.2 Estimator: EWMA center + robust spread (NOOP is already close to best-practice here)

- **Center (acute state):** exponentially-weighted moving average, `EWMA_t = λ·x_t + (1−λ)·EWMA_{t−1}`, `λ = 2/(N+1)` [7]. For N≈7, λ≈0.25. EWMA is empirically **more sensitive** than a rolling mean at detecting load/risk changes (Murray et al. 2017, BJSM — 59 elite AFL players, EWMA explained significantly more injury variance than rolling averages) [6]. Vendors publish rolling means mostly for explainability; EWMA is the stronger estimator, and **NOOP already ships it** (`Baselines.update`, half-life 14 nights).
- **Spread (the band):** build it on **robust statistics** — median + MAD (robust σ ≈ 1.4826·MAD), or a Winsorized/trimmed window — not raw mean±SD, which one bad night inflates. Oura explicitly filters "unusually short or long" nights before estimating need [11]. NOOP's EWMA-of-absolute-deviation with a Winsor clamp (±3σ) + hard-outlier gate (>5σ) is a legitimate robust estimator and is **more rigorous than either vendor's published method**.
- **Per-user noise gauge:** track each user's coefficient of variation `CV = SD/mean·100%` [10]. High-CV users need a **wider band and more persistence** before a flag fires.
- **Distributional honesty:** HRV (rMSSD) is right-skewed; best practice baselines it in **ln space** [8]. A symmetric Gaussian σ on the raw metric misstates tail rarity. This is a refinement, not a headline, but it is the correct target.

> **Tradeoff, stated honestly (no single right answer):** the EWMA half-life / λ, the chronic-window length (30 vs 60 vs 90 days), and the robustness estimator (Winsorize vs trim vs median/MAD) are **design choices, not settled by RCT**. Vendor band-width multiples are proprietary — Altini's example bounds only *imply* ≈±1 SD, they are not published [9]. NOOP must pick and document its own; it should not pretend a specific multiple is a reverse-engineered fact.

### 1.3 Cold-start / minimum-N: never display a baseline you can't support

Precedents: Oura needs ≥5 nights within 14 days for debt and ~90 days for a stable need [11]; SRI needs ≥7 paired days (Phillips) [1] or ≥2 valid 24-h day-pairs at ≥0.66 valid fraction (GGIR) [3]; Altini recommends weeks-to-months before interpreting [8]. **Practical target:** acute baseline usable at ~5–7 valid nights; chronic band stabilizes at ~4–8 weeks; show an explicit **"learning / wider band"** state before then. This is *aligned with NOOP's own honesty principle* — never fabricate a confident number on thin data.

### 1.4 Sleep need — population-anchored, personally *adjusted*, never self-defined

Need is a **long-window personal baseline anchored to the population 7–9 h adult range** (7–8 h older adults) [14]. WHOOP's granted patent gives the only *published quantitative* structure: `SleepNeed = baseline(typical rest-day physiology) + σ₁(strain, prior-day 0–21 scale) + σ₂(debt, scaled and capped, carried forward) − nap_adjustment` [12]. Oura personalizes need from a 90-day, **outlier-filtered** window [11].

The critical constraint: **need is estimated from unrestricted nights and floored at a physiological minimum.** It must **not** be the plain mean of *all* nights, or a chronic under-sleeper's "need" drifts down toward their deficit. Because NOOP is a WHOOP companion, a WHOOP-style **strain adjustment to need is defensible and sensible** — but the coefficients (`σ₁`, the debt cap, the nap credit) are unpublished [12], so NOOP must set and document its own, not backfill vendor numbers.

### 1.5 Sleep debt — rolling, recency-weighted, capped, and honest about slow repayment

`debt_t = Σ_{k=0..13} w_k · max(0, need − actual_{t−k})` over ~14 days, with **recency weights** `w_k` decaying toward older nights (Oura weights recent days more within its 14-day window) [11]. WHOOP feeds a **scaled, capped** debt term forward into tonight's need [12]. The physiology is decisive: neurobehavioral deficits from restriction **accumulate dose-dependently and recover slowly and only partially** — people underestimate their own impairment (Van Dongen 2003) [13]. Therefore debt must be **capped** and framed as **slow-to-repay**; a single long weekend must **never** "erase" it. Present as tiers, matching Oura's now-shipping quantified Sleep Debt: **None / Low (<2 h) / Moderate (2–5 h) / High (>5 h)** [11]. Sleep Performance % = TST / need · 100 [12][26].

> **Design note:** a checkbook that gives *full* credit for surplus and weights all 14 nights equally contradicts both the physiology [13] and both vendors [11][12]. The defensible target is asymmetric (surplus repays at a discount), recency-weighted, and capped.

### 1.6 Circadian regularity — the highest-value, most under-used trend

This is where the biggest actionability gain is, and it is **directly computable on-device with no work/free-day labels**:

- **Sleep Regularity Index (SRI)** = probability you are in the same sleep/wake state at two timepoints 24 h apart, rescaled: `SRI = 200·mean(state[t] == state[t+24h]) − 100` on 30-s or 1-min epochs, over valid same-epoch pairs (non-wear ignored) [1][2][3]. Range −100 (inverted) … 0 (random) … +100 (perfect). Irregular sleep is a **stronger mortality predictor than duration**: UK Biobank found the least-regular quintile carried substantially higher all-cause/CVD mortality, and SRI fit mortality better than sleep duration [4][5].
- **Social jetlag** `SJL = |MSF − MSW|` (mid-sleep on free vs work days; sleep-corrected SJLsc) — only where work/free labels are inferable [15].
- **Nonparametric** interdaily stability (IS, 0–1) and intradaily variability (IV, ~0–2) for whole-rhythm consistency [16]; and a cheap labels-free proxy NOOP can show today: **SD of daily sleep midpoint**.
- **Circadian phase / ideal bedtime** should be anchored to **physiological markers** — the skin-temperature minimum, the timing of lowest RHR, activity — not clock time alone, as Oura does (chronotype from temperature + activity + sleep timing over 90 days; ideal bedtime from highest-Sleep-Score nights + lowest-RHR timing) [21][22]. Expect a **long warm-up** (Oura needs 40–90 days for chronotype) and gate it honestly behind sufficient data.

> **Hard honesty constraint (VERIFICATION-mandated):** SRI absolute values are **implementation-dependent and not transferable** — eLife reports median SRI ≈ 60 [4]; other implementations differ. There is **no universal "good SRI" cutoff** to hard-code; interpret only **within-person and quintile-relative** [4][5]. And mortality hazard ratios are **population associations with reverse-causation confounding** (illness → irregular sleep) — they must **never** be surfaced as an individual's personal risk.

### 1.7 Presentation & alerting (the part that makes it usable, not just a number)

Plot the **smoothed baseline + robust band + a faint guideline anchor** [8][14]. Report **direction *and* duration**, not just today's number [17]. **Fire a flag only on persistence** — smoothed line outside the band for ≥2–3 consecutive days — with the trigger **scaled to each user's CV** [8][10]. "Meaningful change" ≈ 0.5–1× the user's own day-to-day SD; anything smaller is noise (a heuristic borrowed from sport science, not clinically validated — label it as such). Day-to-day intraindividual variability is itself a health-relevant signal, not just measurement error [17].

### 1.8 Integration (the rigorous target neither vendor fully ships)

The three sub-signals — baseline deviation, sleep debt, circadian misalignment — are computed independently in every consumer system, including NOOP. A rigorous target **fuses** them into one longitudinal readiness/alignment trend (e.g. *debt × misalignment × HRV-baseline drift*), because their *co-occurrence* is more informative than any one alone. This is a genuine differentiation opportunity, held at low confidence because no published system validates a specific fusion.

---

## Part 2 — GAP ANALYSIS: where NOOP's Swift falls short of that target

**Headline finding:** NOOP's **per-metric baseline engine is genuinely excellent** — in several respects *more* rigorous than Oura's or WHOOP's published methods. The rigor then **falls off a cliff** in the sleep-need/debt layer and the circadian wiring, which are crude by comparison and do not inherit the baseline engine's discipline. The gaps cluster there.

### What NOOP already does well (keep it)
`Packages/StrandAnalytics/Sources/StrandAnalytics/Baselines.swift` implements a **Winsorized EWMA** (`update:185`, `foldHistory:264`) with an EWMA-of-abs-dev spread, a **hard-outlier gate** (>5σ "seen but not folded", `:226`), a **σ floor** per metric, a **cold-start ladder** (calibrating<4 → provisional 4–13 → trusted ≥14 → stale, `computeStatus:170`), and a thoughtful **early-life anti-anchoring** fix (`:104-134`, `:245-250`) that pulls a high cold-start seed to reality in days. This matches or exceeds §1.2–1.3. **No change needed to the core estimator.**

### Gap A — Sleep need is self-referential (highest-impact correctness bug)
`Strand/Screens/SleepView.swift:2236` — `sleepNeedMin = max(450, typicalTotalMin ?? 450)`, where `typicalTotalMin` (`:2122`) is the **plain arithmetic mean of all nights' `totalSleepMin`**. So "need" = max(7.5 h, *your own all-history average sleep*). For exactly the users who have chronic debt, need **drifts down toward their deficit**, systematically **under-reporting** the debt that matters most — the opposite of §1.4. A physiological `AnalyticsEngine.Rest.defaultNeedHours = 8.0` already exists (`AnalyticsEngine.swift:799`) and `SleepDebt.ledger` even defaults to it (`SleepDebt.swift:91`), but `SleepView.debtLedger:1772` overrides it with the self-referential value. **This inverts NOOP's own honesty philosophy.**

### Gap B — Sleep debt is a flat, uncapped checkbook
`Packages/StrandAnalytics/Sources/StrandAnalytics/SleepDebt.swift:90-111` — `balance = Σ(sleptMin − needMin)` over the most-recent 14 usable nights, **unweighted, full surplus credit, no decay, no cap**. One 12-hour lie-in fully erases a week of deficit; a night 14 days ago weighs exactly as much as last night. This contradicts the physiology (slow/partial recovery [13]) and both vendors' recency-weighted, capped models [11][12] (§1.5). A second, competing definition (`SleepView.sleepDebtSeries:2223`, per-night `max(0, need−asleep)` floored at 0, no credit) coexists, risking inconsistent headline-vs-chart reads.

### Gap C — No regularity metric at all (biggest missing feature)
NOOP computes circadian **phase** (cosinor) but ships **no SRI, no social jetlag, no IS/IV, no sleep-midpoint SD** — i.e. none of §1.6, the highest-value, most-actionable, mortality-relevant longitudinal signal [4][5]. NOOP already has per-minute on-device sleep/wake detection, so `SRI = 200·mean(state[t]==state[t+24h]) − 100` [1][2] is directly computable. This is a **missing capability**, not a broken one.

### Gap D — Circadian phase is wired to the wrong signal, and fragile
`Packages/StrandAnalytics/Sources/StrandAnalytics/CircadianEngine.swift` is a competent single-component cosinor (`cosinor:70`, `estimatePhase:155`), but its `ActivityBin.activity` is documented as **motion volume** — and `Strand/App/AppModel.swift:1525-1540` feeds it **mean hourly HR** instead. HR's diurnal peak is confounded by exercise, caffeine, meals, stress and posture and need not coincide with the true activity acrophase, **biasing phase**. Worse, `estimatePhase` is called with only three arguments (`:1544`), so `observedTempMinHour` is **always nil** — the skin-temp-minimum cross-check the engine's own doc promises (`:11-13`) **never runs**; `tempMinHour` is a deterministic `acrophase − 12 h` transform of the HR fit, not an independent measurement (§1.6). And `habitualWakeHour():1550` uses **only the last banked night's wake time**, so one late wake skews the whole schedule-offset. Fixed population constants (CBTmin 2.5 h before wake, 1 h/day re-entrainment) are applied to every user with no chronotype personalization.

### Gap E — Inconsistent, non-robust, wall-clock-blind trend math
`Strand/Screens/TrendsView.swift:176` (`periodChange`) uses a **split-half mean difference** (≥4 pts), while `WeeklyDigest`/`ComparisonEngine`/`RangeReport` use **OLS slope indexed by position, not wall-clock day** (gaps compressed) — two different, non-robust definitions of "trend" across surfaces. There is **no smoothing, no CI/uncertainty band, no reliability weighting** (a 2-reading week and a 7-reading week compare as equals), and **no persistence-gated alerting scaled to CV** (§1.7). Trend windows anchor on `latestDay` not today (`TrendsView:85`), so "last 7 days" can silently be weeks stale.

### Gap F — Baselines are wall-clock-blind
`Baselines.swift` counts EWMA half-lives in **valid observations, not calendar time**; a missing night only bumps a staleness counter (`:200-206`). A baseline resumed after a 3-week gap weights the pre-gap value as if it were yesterday. Two users with identical night-counts but very different gap patterns get identical smoothing (§1.2). Separately, the production path is **full-history** (`foldHistory:264`) — the auditable bounded-window alternative `rollingMeanSD(window:30)` (`:368`) is **dead code** (referenced only by tests), so ancient nights leak through the EWMA tail with no hard forgetting.

### Gap G — Gaussian z on skewed metrics; no minimum-N gate on sleep surfaces
Deviation uses a symmetric `σ = 1.253×abs-dev` around the raw EWMA center (`Baselines.deviation:345`), but HRV/skin-temp are skewed, so tail z-scores misstate rarity (§1.2). And unlike the baseline layer's honest cold-start ladder, **sleep need/debt emit a confident number from night one** (all-history mean, no "still learning" state) — inconsistent with §1.3 and with NOOP's own baseline discipline.

---

## Part 3 — ACTIONABILITY: what the user should be able to *do*

A longitudinal score is only worth shipping if it drives a **behavior** and is framed so the user trusts it. Target behaviors and presentation:

| Signal | What the user should DO | How to present it (so it's usable) |
|---|---|---|
| **Baseline deviation** (HRV/RHR/temp/resp) | Rest / deload / consider care *if symptomatic* when the smoothed line sits below band for ≥2–3 days | Smoothed line + shaded robust band + faint 7–9 h / population anchor [8][14]; trend arrow with **direction *and* duration** [17]; state chip (calibrating/provisional/trusted/stale). **Never** a diagnosis. |
| **Sleep debt** | Prioritize sleep over the next several nights; understand it repays slowly | Single **capped** number + tier (None/Low/Mod/High) [11]; a 14-night sparkline of nightly deltas; honest copy: *"repays slowly — one long night won't clear it"* [13]. |
| **Regularity (SRI)** | **The #1 lever:** keep consistent bed/wake times | Within-person trend ("more/less regular than your recent normal"), **not** a cutoff [4][5]; a concrete nudge ("aim for a consistent lights-out"). |
| **Circadian phase / ideal bedtime** | Shift light exposure & timing to align clock with schedule | "Your body clock leans late vs your schedule" + the existing light/timing plan; gated behind a long, honest warm-up [21][22]. |

**Presentation rubric (the honesty contract, all VERIFICATION-mandated):**
1. **Pair every personal band with the population anchor** — otherwise NOOP optimizes users toward their own dysfunction (§1.1).
2. **Alert only on persistence, scaled to personal CV** — single-night dips are noise; over-alerting destroys trust [8][10].
3. **Frame debt honestly** — capped, slow-to-repay, never "cleared by one weekend" [13].
4. **Regularity as within-person trend, not a diagnostic cutoff** — no universal SRI number exists [4][5].
5. **Show "still learning (N more nights)" before minimum-N** — never fabricate a baseline; this *is* NOOP's stated principle (§1.3).
6. **Never surface mortality HRs as personal risk** — they are confounded population associations; wearable sleep/wake staging propagates error into SRI/social-jetlag/IS-IV.

---

## Sources
1. Phillips et al. 2017, *Sci Rep* — Sleep Regularity Index definition. https://www.nature.com/articles/s41598-017-03171-4
2. SRI reference implementation (confirms exact arithmetic). https://github.com/mengelhard/sri
3. GGIR SRI documentation (30-s epochs, valid-fraction gating). https://wadpac.github.io/GGIR/articles/SleepRegularityIndex.html
4. eLife 2023, UK Biobank — SRI & mortality (median ≈60; non-linear). https://elifesciences.org/articles/88359
5. Windred et al. 2024, *Sleep* — regularity a stronger mortality predictor than duration. https://academic.oup.com/sleep/article/47/1/zsad285/7344663
6. **Murray et al. 2017, *BJSM*** — EWMA more sensitive than rolling averages (corrected attribution; not "Williams"). https://pubmed.ncbi.nlm.nih.gov/28003238/
7. ScienceForSport — EWMA formula, λ = 2/(N+1). https://www.scienceforsport.com/acutechronic-workload-ratio/
8. Altini/HRV4Training — 7-day MA state + 60-day band; ln(rMSSD); flag-below-band. https://medium.com/@altini_marco/the-ultimate-guide-to-heart-rate-variability-hrv-part-2-323a38213fbc
9. Altini Substack — personal "normal range" band (SD multiple **not** published). https://marcoaltini.substack.com/p/whats-your-normal-range-for-heart
10. EliteHRV — coefficient of variation as a personal noise gauge. https://elitehrv.com/improving-hrv-data-interpretation-coefficient-variation
11. Oura Sleep Debt — 14-day window, ≥5 nights/14, 90-day outlier-filtered need, tiers None/Low<2h/Mod2–5h/High>5h. https://support.ouraring.com/hc/en-us/articles/46233324892691-Sleep-Debt
12. **WHOOP patent US12318226B2** — SleepNeed = baseline + σ₁(strain 0–21) + σ₂(debt, scaled+capped) − naps (authoritative source; replaces third-party affiliate blog). https://patents.google.com/patent/US12318226B2/en
13. Van Dongen et al. 2003, *Sleep* — cumulative, dose-dependent deficits; slow/partial recovery. https://academic.oup.com/sleep/article-pdf/26/2/117/13662142/sleep-26-2-117.pdf
14. NSF / Hirshkowitz 2015 — 7–9 h adults, 7–8 h older adults. https://www.sleephealthjournal.org/article/S2352-7218(15)00015-7/fulltext
15. MCTQ — social jetlag SJL = |MSF − MSW|; SJLsc. https://cran.r-project.org/web/packages/mctq/vignettes/sjl-computation.html
16. van Someren — nonparametric IS / IV. https://www.sciencedirect.com/science/article/pii/S1984006314000510
17. Bei et al. 2016, *Sleep Med Rev* — intraindividual variability as a distinct health-relevant construct. https://www.sciencedirect.com/science/article/pii/S1087079215000908
18. Oura Trends — 90-day running average; 3-day weighted temperature deviation. https://support.ouraring.com/hc/en-us/articles/360055983614-How-to-Use-Trends
19. Oura Readiness Contributors — 14-day recent vs ~2–3-month baseline; Sleep Balance. https://support.ouraring.com/hc/en-us/articles/360057791533-Readiness-Contributors
20. Oura HRV Balance — 14-day vs 3-month, nighttime-only, 3 states. https://ouraring.com/blog/hrv-balance/
21. Oura Body Clock & Chronotype — temp + activity + sleep timing over 90 days; 40–90-day warm-up. https://support.ouraring.com/hc/en-us/articles/14594974129555-Body-Clock-and-Chronotype
22. Oura Ideal Bedtime — from highest-Sleep-Score nights + lowest-RHR timing. https://ouraring.com/blog/ideal-bedtime/
23. Oura Resilience — 14-day rolling load+recovery, 5 tiers, ≥10-day warm-up. https://support.ouraring.com/hc/en-us/articles/25358829055251-Resilience
24. WHOOP Weekly Performance Assessment — last week vs trailing 3-week avg + demographic comparison. https://support.whoop.com/hc/en-us/articles/360019454194
25. WHOOP Sleep Consistency — 4-day timing similarity, 0–100%, circadian framing. https://www.whoop.com/us/en/thelocker/new-feature-sleep-consistency-why-we-track-it/
26. gadgetsandwearables — WHOOP Sleep Debt = need − obtained; Sleep Performance/Efficiency. https://gadgetsandwearables.com/2023/10/04/whoop-advanced-sleep-metrics/
27. WHOOP Journal — with/without behavior comparison, N-gated (≥5 yes/≥5 no in 90 d). https://www.whoop.com/us/en/thelocker/the-whoop-journal/
28. WHOOP Monthly assessment — "isolated contribution" covariate-adjusted partial effect. https://www.whoop.com/gb/en/thelocker/monthly-performance-assessment-now-features-enhanced-recovery-analysis/
29. WHOOP Trend Views — weekly/monthly/6-month curves. https://www.whoop.com/us/en/thelocker/track-progress-with-new-trend-views/

*Proprietary unknowns preserved per verification: vendor band-width SD multiples, Oura's exact recency kernel & outlier thresholds, WHOOP's strain→minutes mapping and debt cap/decay, the Sleep Consistency 0–100 function, Training-Zone boundaries, and the Monthly "isolated contribution" model are **undisclosed** — these are NOOP design decisions to set and document, not reverse-engineered facts.*

## Ranked recommendations

| # | Change | Impact | Conf | Effort |
|---|---|---|---|---|
| 1 | Replace the self-referential sleep need in SleepView.swift:2236 (sleepNeedMin = max(450, typicalTotalMin)) with a population-anchored need: floor at an age-based 7–9 h guideline [14], estimate the personal component only from unrestricted/outlier-filtered nights [11], and clamp so it can never drift below ~7 h. Optionally add a WHOOP-style strain adjustment (need = anchor + σ₁(strain) − nap credit) [12] with NOOP-chosen, documented coefficients. | high | high | low |
| 2 | Add a Sleep Regularity Index engine to StrandAnalytics: SRI = 200·mean(state[t]==state[t+24h]) − 100 over 30-s/1-min on-device sleep/wake epochs, non-wear ignored, gated at ≥7 valid day-pairs [1][2][3]. Surface it as a within-person trend plus a cheap labels-free companion (SD of daily sleep midpoint). | high | high | medium |
| 3 | Make SleepDebt.ledger (SleepDebt.swift:90-111) recency-weighted, capped, and asymmetric: decay weights toward older nights [11], cap total displayed debt [12][13], and credit surplus at a discount so one long night cannot erase a week of deficit. Collapse the two competing definitions (ledger vs SleepView.sleepDebtSeries) into one, and present Oura-style tiers (None/Low<2h/Mod2–5h/High>5h) [11]. | high | high | medium |
| 4 | Pair every baseline band with the population/guideline anchor and add persistence-gated alerting: draw the smoothed line + robust band + a faint 7–9 h (or regularity-protective) anchor, and fire a flag only when the smoothed line sits outside the band for ≥2–3 consecutive days, with the threshold scaled to each user's CV [8][10][14]. | high | high | medium |
| 5 | Fix the circadian wiring in AppModel.computeCircadianPhase (AppModel.swift:1522-1555): derive habitualWakeHour from a robust central tendency of recent nights (not only repo.sleeps.last), and actually pass observedTempMinHour so the skin-temp-minimum cross-check the engine documents runs [21]. Prefer a motion/step signal over mean hourly HR as the cosinor 'activity' input, or clearly label the HR-based phase as a lower-confidence proxy. | medium | high | medium |
| 6 | Unify trend math across TrendsView, WeeklyDigest, ComparisonEngine and RangeReport onto one robust, wall-clock-aware slope (e.g. Theil–Sen or OLS regressed on actual elapsed days, not position index), add a smoothing/uncertainty band and reliability weighting, and anchor windows on today with an explicit 'data is N days stale' note when latestDay lags. | medium | medium | medium |
| 7 | Make Baselines.swift wall-clock-aware: decay the EWMA by calendar days elapsed (or inflate spread / widen the band) after gaps, instead of counting half-lives purely in valid observations. | medium | medium | medium |
| 8 | Gate the sleep need/debt surfaces behind an explicit cold-start / 'still learning (N more nights)' state, mirroring the baseline layer's calibrating→provisional→trusted ladder, rather than emitting a confident number from an all-history mean on night one. | medium | high | low |
| 9 | Baseline HRV in ln space (and handle metric skew) before computing the z-score in Baselines.deviation (Baselines.swift:345), instead of a symmetric σ=1.253×abs-dev around the raw EWMA center. | low | medium | low |
| 10 | Add an integrated longitudinal readiness/alignment trend that fuses baseline deviation × sleep debt × circadian misalignment into one signal, held behind clear uncertainty and a data-sufficiency gate. | medium | low | high |

### Rationale detail

1. **Replace the self-referential sleep need in SleepView.swift:2236 (sleepNeedMin = max(450, typicalTotalMin)) with a population-anchored need: floor at an age-based 7–9 h guideline [14], estimate the personal component only from unrestricted/outlier-filtered nights [11], and clamp so it can never drift below ~7 h. Optionally add a WHOOP-style strain adjustment (need = anchor + σ₁(strain) − nap credit) [12] with NOOP-chosen, documented coefficients.** — The current 'need = your own all-history mean sleep' makes a chronic under-sleeper's need drift down toward their deficit, systematically under-reporting debt for exactly the users who have it — inverting NOOP's honesty philosophy. AnalyticsEngine.Rest.defaultNeedHours = 8.0 already exists; the ledger already defaults to it (SleepDebt.swift:91); only SleepView.debtLedger overrides it. A near-one-line change with outsized correctness impact.

2. **Add a Sleep Regularity Index engine to StrandAnalytics: SRI = 200·mean(state[t]==state[t+24h]) − 100 over 30-s/1-min on-device sleep/wake epochs, non-wear ignored, gated at ≥7 valid day-pairs [1][2][3]. Surface it as a within-person trend plus a cheap labels-free companion (SD of daily sleep midpoint).** — Regularity is the single most actionable and most mortality-relevant longitudinal signal in the literature — a stronger predictor than duration [4][5] — and NOOP ships none of it today despite already having per-minute sleep/wake detection that makes SRI directly computable. Biggest missing capability in this layer.

3. **Make SleepDebt.ledger (SleepDebt.swift:90-111) recency-weighted, capped, and asymmetric: decay weights toward older nights [11], cap total displayed debt [12][13], and credit surplus at a discount so one long night cannot erase a week of deficit. Collapse the two competing definitions (ledger vs SleepView.sleepDebtSeries) into one, and present Oura-style tiers (None/Low<2h/Mod2–5h/High>5h) [11].** — A flat, uncapped, full-credit checkbook contradicts the physiology (recovery is slow and partial — Van Dongen 2003 [13]) and both vendors' recency-weighted, capped models [11][12]. Two coexisting debt definitions risk inconsistent headline-vs-chart reads.

4. **Pair every baseline band with the population/guideline anchor and add persistence-gated alerting: draw the smoothed line + robust band + a faint 7–9 h (or regularity-protective) anchor, and fire a flag only when the smoothed line sits outside the band for ≥2–3 consecutive days, with the threshold scaled to each user's CV [8][10][14].** — A personal baseline answers 'different from my normal', not 'healthy'; without the anchor NOOP silently optimizes users toward their own dysfunction. Persistence + CV-scaling is the discipline that stops single-night noise from destroying trust — the core presentation contract of this layer.

5. **Fix the circadian wiring in AppModel.computeCircadianPhase (AppModel.swift:1522-1555): derive habitualWakeHour from a robust central tendency of recent nights (not only repo.sleeps.last), and actually pass observedTempMinHour so the skin-temp-minimum cross-check the engine documents runs [21]. Prefer a motion/step signal over mean hourly HR as the cosinor 'activity' input, or clearly label the HR-based phase as a lower-confidence proxy.** — Phase is currently biased (HR's diurnal peak is confounded by exercise/caffeine/meals/posture and isn't the activity acrophase), the temp-minimum corroboration never runs (tempMin is just a fixed acrophase−12h transform), and a single late wake skews the whole schedule offset. These undermine an otherwise sound cosinor.

6. **Unify trend math across TrendsView, WeeklyDigest, ComparisonEngine and RangeReport onto one robust, wall-clock-aware slope (e.g. Theil–Sen or OLS regressed on actual elapsed days, not position index), add a smoothing/uncertainty band and reliability weighting, and anchor windows on today with an explicit 'data is N days stale' note when latestDay lags.** — TrendsView uses split-half mean-difference while other surfaces use position-indexed OLS — two non-robust, mutually inconsistent definitions of 'trend'; a '30-day' slope over 8 present days is silently per-observation. No CI or reliability weighting means a 2-reading week compares as equal to a 7-reading week.

7. **Make Baselines.swift wall-clock-aware: decay the EWMA by calendar days elapsed (or inflate spread / widen the band) after gaps, instead of counting half-lives purely in valid observations.** — A baseline resumed after a 3-week gap currently weights the pre-gap night as if it were yesterday; two users with the same night-count but different gap patterns get identical smoothing. Real recency should track calendar time, not observation index.

8. **Gate the sleep need/debt surfaces behind an explicit cold-start / 'still learning (N more nights)' state, mirroring the baseline layer's calibrating→provisional→trusted ladder, rather than emitting a confident number from an all-history mean on night one.** — The baseline engine already does honest minimum-N gating; the sleep layer doesn't, which is inconsistent and violates NOOP's own never-fabricate-on-thin-data principle [11][3].

9. **Baseline HRV in ln space (and handle metric skew) before computing the z-score in Baselines.deviation (Baselines.swift:345), instead of a symmetric σ=1.253×abs-dev around the raw EWMA center.** — HRV (rMSSD) and skin-temp are skewed, so a symmetric Gaussian z misstates tail rarity; ln(rMSSD) is the established best-practice transform [8]. A refinement rather than a headline, but it improves the honesty of 'how unusual is tonight'.

10. **Add an integrated longitudinal readiness/alignment trend that fuses baseline deviation × sleep debt × circadian misalignment into one signal, held behind clear uncertainty and a data-sufficiency gate.** — The three sub-signals are computed independently and never combined, yet their co-occurrence is more informative than any one alone — a genuine differentiation opportunity over Oura/WHOOP. Kept at lower confidence because no published system validates a specific fusion, so ship it as exploratory, not a gate on other scores.

