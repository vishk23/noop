# Readiness / HRV-readiness (if distinct from Charge)

## Readiness / HRV-readiness — TARGET METHODOLOGY for NOOP

**Scope of this doc.** NOOP already ships a physiology-only recovery score — **Charge** (`RecoveryScorer`, a weighted HRV+RHR+resp+sleep+skin-temp composite on the app's robust EWMA baselines) — and a separate, categorical **Readiness** read (`ReadinessEngine`) that adds training-load context. It also carries a *more correct* log-domain HRV-band engine (`HRVReadiness`) quarantined behind a default-off experiment. This doc defines what a **Readiness / HRV-readiness** score *should* be **given that Charge already exists**, then measures the shipped code against it.

---

## Part 1 — TARGET METHODOLOGY

### 1.1 The one decision that frames everything: Readiness ≠ Recovery, by *scope*

The most important, best-supported architectural fact is that **"Recovery" and "Readiness" are not synonyms and should differ by SCOPE, not by re-summing the same inputs** [1][5][22].

- **Recovery / Charge** = a *physiology-only* snapshot: "how recovered is my autonomic nervous system right now?" This is the **WHOOP-Recovery** construct — HRV-led, plus RHR, respiratory rate, sleep, skin temp, SpO₂, normalized to the person's own baseline, banded green 67–100 / yellow 34–66 / red 0–33 [5][7]. NOOP's Charge already *is* this axis.
- **Readiness** = a *broader composite* that folds the recovery signal together with **load and context**: "given my recovery **and** my recent training load, sleep debt, and circadian/temperature state, how prepared am I to take on strain today?" This is the **Oura-Readiness / Garmin-Training-Readiness** construct. Garmin makes the load-awareness explicit — Training Readiness combines last-night sleep score, **HRV status vs baseline**, recovery-time countdown, **acute (~7-day) training load**, 3-night sleep history, and 3-day stress history into one morning figure [22][23].

**The failure mode to avoid is two near-identical 0–100 scores.** If NOOP's Readiness re-sums HRV and RHR that are *already inside* Charge, the two numbers become redundant and can only disagree by noise. The clean design: **Readiness ingests Charge as its recovery term and adds *orthogonal* load/context terms** (training-load balance, sleep debt/regularity, temperature/circadian) — never re-scoring the autonomic inputs Charge already owns.

**Honest tradeoff — one blended score (Oura) vs. two axes (WHOOP).** Oura folds recovery, sleep, and activity balance into a *single* morning Readiness number [1][2]; WHOOP deliberately splits "how recovered" (Recovery %) from "how much should I do" (Strain Target), so each number means exactly one thing [5][9][10]. For construct isolation the **two-axis model is more defensible** — a low Oura score doesn't localize cleanly to under-recovery vs. merely short sleep, whereas WHOOP's pair is directly actionable. **NOOP is already two-axis (Charge + Readiness); the recommendation is to lean into that, not collapse to a single Oura-style blend.** The genuine things worth borrowing *from* Oura are (a) **temperature-driven off-baseline/illness flagging** and (b) **named contributors with disclosed baseline windows** so the score is explainable [1].

### 1.2 The physiological core: a personal lnRMSSD baseline-band, not an absolute number

The dominant readiness signal is **vagally-mediated HRV**, best captured by **RMSSD** — the preferred short-term time-domain index of parasympathetic cardiac control [20]. Two properties dictate the method:

1. **RMSSD is right-skewed → work in the log domain (lnRMSSD)** before any SD-based math. This is standard practice in the athlete-monitoring literature [18][19]. *(Note on WHOOP: log-transforming is standard and NOOP should do it, but WHOOP publicly reports HRV to users as raw RMSSD in ms and does **not** disclose whether its Recovery score transforms internally — do not cite WHOOP as proof of lnRMSSD [6].)*
2. **Between-individual variation is enormous** (healthy-adult short-term RMSSD ≈ 42 ± 15 ms, range 19–75 ms [20]), so **population norms are useless as targets** — only the person's own history is meaningful.

The converged recipe from the sports-science literature and from HRV4Training / Oura / WHOOP alike:

- **Chronic baseline:** a **7-day rolling average of lnRMSSD**, which suppresses the large night-to-night noise of single readings [18][19]. *Day-to-day decisions ride the 7-day line, never one night.*
- **Personal normal band:** built from a trailing **~60-day** window of the individual's own lnRMSSD; band = long-run mean ± **smallest worthwhile change (SWC ≈ 0.5 × between-day SD)** [13][14]. Interpretation flips from "higher is better" to **"normal is better"** — readiness is high when today's value / the 7-day baseline sits *within or above* the band and degrades as it falls *below* it [13].
- **Second-order signal — coefficient of variation (CV = SD/mean of the rolling window):** a **rising CV alongside a falling baseline is the classic early warning of maladaptation / accumulated fatigue**, and can flag trouble while the baseline is still nominally in-range [14][25].

**Honest caveat on the constants.** The 0.5×SD multiplier and the 7-day / ~60-day windows are **conventions** (Plews/Buchheit/Altini) and a commercial guide [13][14], **not** the output of a formal optimization; the best windows likely vary by person and data density [18][19]. NOOP should treat them as *starting points to validate on its own data*, not settled truths.

### 1.3 Acute vs. chronic fusion, and the supporting signals

Readiness should be driven primarily by **HRV and resting heart rate together** [19]. RHR drifting **several bpm above baseline** is one of the most robust, hard-to-fake recovery/illness signals — Oura-adjacent figures put fever/flu tags around ~8.5 bpm above baseline [1]. *(Avoid the specific "3–7 bpm" figure — it is not attributable to a primary source.)* Layer the rest as modifiers:

| Term | Role | Baseline window (vendor precedent) |
|---|---|---|
| **lnRMSSD** (7-day) vs personal band | Dominant driver | ~60-day personal normal [13]; Oura HRV Balance = 14-day vs 3-month, recent-weighted [1] |
| **Resting HR** | Co-dominant, hard-to-fake | vs long-term average [1] |
| **Respiratory rate** | Illness/strain modifier | WHOOP *states* it adds next-day-performance signal beyond HRV/RHR/sleep — a **vendor claim, not validated** [8] |
| **Skin/body temperature deviation** | Off-baseline / illness guard | Oura: ~2-month nighttime baseline; "significantly above/below normal lowers the score" [1] |
| **Training-load balance (ACWR)** | Load context (Readiness only) | acute ~7-day vs chronic ~28-day; prefer **EWMA-ACWR** over simple rolling averages to reduce bias |
| **Sleep debt / regularity** | Context (Readiness only) | Oura Sleep Balance 14-day vs need; Regularity over 14-day [1] |

**Acute** = last night's lnRMSSD (and RHR) relative to the band. **Chronic** = the 7-day baseline's trajectory vs the ~60-day mean, plus the CV trend. Score each input by its signed deviation from its *own* personal band, weight HRV and RHR as the two dominant terms, add temperature/respiratory-rate as modifiers, and map to a continuous 0–100 with a **logistic** curve (NOOP's Charge already does exactly this — logistic on a weighted robust-z composite).

**The deepest honest uncertainty.** It is **not established that a composite Readiness score outperforms simply trending the raw 7-day lnRMSSD baseline** for guiding decisions [18]. Added contributors improve *face validity* and answer "how much today," but their independent predictive value in a consumer score is largely unvalidated, and **no vendor publishes validation of any composite recovery/readiness score's next-day predictive accuracy** — only the underlying HR/HRV *sensor* accuracy is independently validated [12]. **Design implication:** make the lnRMSSD band-trend *first-class and visible*, and let the composite be a **summary over an explainable band**, never an opaque number that buries it.

### 1.4 Measurement grain

**Nightly, sleep-derived HRV is valid and appropriate.** Consistent morning-supine ~5-min readings are the classic protocol [19], but nocturnal sleep-window lnRMSSD is at least as sensitive and in one 2024 head-to-head (24 recreational runners) was **more responsive to training-induced change** than morning readings — validating NOOP's on-device sleep-window approach (present as suggestive, single-study) [21]. WHOOP samples HRV during sleep, stated to be weighted toward slow-wave sleep, for a stable nightly reading — but the exact epochs/weighting are unpublished, so do not over-specify [11].

### 1.5 Warm-up and honesty gating

Bands are meaningless until enough nights exist. Oura learns baselines over **~2 weeks** [2]; Garmin needs **~3–4 weeks** to calibrate [22]; the SWC band stabilizes over **~60 days** [13]. The target: **gate the score (or widen its uncertainty) during warm-up, and prefer an honest "not enough data yet" to a fabricated band.** NOOP's own `Baselines` pipeline already models this with `calibrating → provisional → trusted → stale` states and a `ScoreConfidence` (calibrating/building/solid) — the Readiness axis should *use* it.

### 1.6 Target vendor band scales (for reference, not to copy)

- **Oura Readiness (0–100):** 85–100 Optimal / 70–84 Good / 60–69 Fair / 0–59 Pay Attention [2].
- **WHOOP Recovery (0–100%):** green 67–100 / yellow 34–66 / red 0–33 [5].
- **Garmin Training Readiness (1–100):** Prime 95–100 / High 75–94 / Moderate 50–74 / Low 25–49 / Poor 1–24 [22].

**The exact weighting, normalization curves, and 0–100 mapping shapes behind all three are proprietary and unpublished** [1][5][22] — NOOP must design and *validate its own*, and must never present any vendor coefficient as known.

---

## Part 2 — GAP ANALYSIS (shipped NOOP vs. the target)

NOOP's architecture is right; the **execution of the Readiness axis is where it falls short**, and the more-correct engine is quarantined. Specifics below are grounded in the audited Swift.

### 2.1 The default-visible Readiness is categorical, not a resolved score
`ReadinessEngine` (`ReadinessEngine.swift`) emits a **5-way `Level` enum** (primed/balanced/strained/rundown/insufficient) plus **4-way per-signal flags**, with **no continuous 0–100 score, no percentile, no hysteresis** (:27–37, synthesize :275–300). The z→flag cut-points are hard edges at 0.5 / −0.5 / −1.0 (:229–234), so **severity within a band is lost — a z of −1.01 and −5.0 both read "bad"** — and the Level can flip night-to-night on a single noisy input. The target is a smoothed continuous score with severity-within-band and confidence.

### 2.2 The Readiness baseline is naive and inconsistent with the app's own rigorous pipeline
For HRV/RHR/resp, `ReadinessEngine` takes an **unweighted trailing-30-night arithmetic mean + sample SD**, min 7 points, then a plain `z=(v−m)/sd` (`zSignal` :218–238; `baselineWindow=30`, `minBaseline=7` :69–73). This means **no EWMA/recency weighting, no Winsorization/outlier rejection, no cold-start damping, no staleness penalty** — and missing nights are `compactMap`'d away, so a 30-*calendar*-day window silently shrinks over gaps and a **weeks-old baseline can anchor today's z with no penalty**. Meanwhile the *same repo* exposes exactly the right machinery, which Charge/`WatchRecovery` use and Readiness ignores:
- `Baselines.foldHistory` — Winsorized EWMA + cold-start gating (`Baselines.swift` :264), status `calibrating/provisional/trusted/stale` (:36–41, :170–175), hard bounds (hrv 5..250 etc. :150–158);
- `Baselines.deviation` — robust z = (value − baseline)/(1.253 × spread), `inNormalRange` |z|≤1 (:345);
- `Baselines.rollingMeanSD` — an *auditable* trailing mean/SD that **still returns a status-carrying `BaselineState`** (:368), i.e. even the "simple" path was built to carry cold-start/staleness — Readiness could adopt it almost for free.

One bad-decode HRV night in the raw window skews the mean **and** inflates the SD (desensitizing the z); `foldHistory`'s hard-outlier gate + Winsor clamp exist precisely to prevent this.

### 2.3 HRV uses raw ms; the correct log-domain engine is quarantined
`ReadinessEngine`'s HRV z is computed on **raw RMSSD ms** (:135–146), but RMSSD is right-skewed, so a raw z overstates high-side and understates low-side (suppression) deviations. The app's **own** `HRVReadiness` engine does it correctly — **ln domain** (:104), a **7-night rolling baseline** (:107) vs a **60-night (fallback 30) personal band at ±0.5·SD SWC** (:119–122), tiers primed/normal/suppressed (:124–132), and an informational **overreaching-watch = falling-CV-slope while baseline < long-mean** (:134–149), honesty-gated at `minNights=14` (:78). But it is **opt-in only** behind `PuffinExperiment.hrvReadinessKey="noopHrvReadiness"` (default OFF, `PuffinExperiment.swift`:82–96), surfaced solely in `TestCentreView` (:265–317), feeds **no downstream gate**, and is explicitly n=1 unvalidated. **The good ideas — log domain, SWC personal-normal band, robust short rolling baseline, CV-trend — are exactly the target, and they are the ones users don't see.**

### 2.4 Signals are combined by counting, not weighted physiology; no coupled term, no confidence
`synthesize` **counts** bad/watch/good flags and applies coarse rules (`bad≥2 || (recoveryDown && loadHigh) → rundown`, etc., :275–300). The informative **coupled case (HRV down *and* RHR up together)** only surfaces via the blunt `rundown` rule, not a weighted score; **no trend/slope of HRV or RHR feeds the verdict** (only the quarantined engine computes a slope). There is **no confidence exposed** — `minBaseline=7` lets the SD denominator ride on as few as 7 nights, yet the card shows no width/uncertainty (contrast Charge's `ScoreConfidence`). No respiration/skin-temp/sleep-performance terms feed Readiness at all, though the platform already computes them for Charge.

### 2.5 Load context is thin and uses the biased ACWR
ACWR is `acute=mean(last 7 strain) / chronic=mean(last 28)` — simple rolling averages (:184–194), i.e. the **biased rolling-average ACWR**, not the EWMA-ACWR shown to reduce bias. Monotony is a noisy 7-day Foster estimate (min 4 points, :197–206). There is **no sleep-debt, sleep-regularity, or temperature/circadian context** — the very terms that make a *Readiness* axis distinct from Charge per the target [1][22].

### 2.6 Cross-engine incoherence with no reconciliation
Three engines can point different directions on the same night with nothing surfaced to the user: **Charge** (0–100, EWMA baseline, logistic), **Readiness** (categorical, naive raw-ms z), and experimental **HRV-readiness** (3-tier log SWC band). They disagree even on *domain* (raw ms vs ln) and *baseline construction* (naive mean vs Winsorized EWMA). A user seeing a green Charge and a "strained" Readiness has no explanation of why.

### 2.7 Resp signal is asymmetric by construction
The respiratory-rate signal only ever emits watch/bad (never good/neutral), gated to 8–25 bpm on both value and baseline mean, with wider z thresholds 1.5/2.0 (:167–182). A genuinely-low resp night can't contribute a positive signal — acceptable as an illness-guard, but it should be framed as such, not as a symmetric contributor.

---

## Part 3 — ACTIONABILITY (what the user should be able to DO, and how to present it)

A readiness number is only worth showing if it changes a decision. Present it so it is **explainable, self-relative, and honestly non-clinical**.

### 3.1 Show the trend and the band, not just a verdict
Plot the **7-day lnRMSSD baseline line with the shaded personal-normal band** (Altini / HRV4Training pattern) and today's point [13] — this makes a low read explainable at a glance and is the single most evidence-backed view. Under it, expose **named contributors, each with its disclosed baseline window and direction** (Oura pattern) and the **top 1–2 drivers** of today's score (e.g. "RHR several bpm above baseline; HRV below band") [1]. The band + drivers turn the score from a black box into something the user can reason about.

### 3.2 Drive guidance off the band and the 7-day trend — never a single night
Evidence-based mapping from the HRV-guided-training RCTs [15][16][17]:
- **In-band → normal / hard training OK.**
- **1 night below → proceed, trim volume.**
- **≥2–3 nights below, or Kiviniemi's "below 10-day mean − 1 SD" / 2-day downward trend, or rising CV with falling baseline → swap intensity for easy/rest.**
- **Sustained below-band with rising CV → genuine recovery days.**

**Frame this honestly.** The efficacy evidence is a **small, highly heterogeneous** pooled effect on VO₂max (ES ≈ 0.402, 95% CI 0.273–0.531 vs. 0.215 for fixed programming; I² ≈ 94%) in mostly fit adults [16]. In Kiviniemi 2007, the HRV-guided group's advantage was in **running performance / peak velocity — VO₂peak did *not* differ significantly between groups** [15]. This validates *acting on the band* for athletic training; it does **not** validate day-to-day "readiness" guidance for general wellness, illness prediction, or non-athletes.

### 3.3 Gate and label during warm-up
Bands are meaningless early. Reuse `ScoreConfidence` / `BaselineState.status` to label the score **provisional until ~2–4 weeks** and widen its uncertainty, and prefer an explicit **"not enough data yet"** to a fabricated band [2][22][13]. NOOP's honesty ethos ("never fabricate a number") already demands this — the machinery exists (`WatchRecovery`'s nil + `.calibrating` pattern), it just isn't wired into Readiness.

### 3.4 Non-clinical guardrails (a clinician would insist on these)
- **Never show population norms (42 ± 15 ms) as targets** — only the person's own baseline is meaningful given the huge inter-individual spread [20].
- **Every component is a self-relative approximation:** a temperature deviation is an **"off your baseline"** flag, *never* a fever/illness diagnosis; low HRV is **"below your recent norm,"** not "autonomic dysfunction" [1].
- **Surface confounders as caveats, not silent "fatigue":** alcohol, late meals, poor sleep, illness, menstrual phase, altitude, and measurement time all move HRV [19].
- **A persistently abnormal RHR/HRV/temperature pattern warrants "consider seeing a clinician,"** not a NOOP interpretation.
- **RMSSD-based readiness is a non-clinical wellness approximation** and must never imply detection of arrhythmia, infection, or disease; the composite's predictive validity is unpublished for every vendor [12].

### 3.5 Reconcile the axes for the user
When Charge and Readiness diverge, **say why** (e.g. "recovery is solid, but load is spiking and sleep is short"). The two-axis model is only actionable if the pair is legible; today three engines can disagree silently.

---

## Sources

1. Oura — Readiness Contributors. https://support.ouraring.com/hc/en-us/articles/360057791533-Readiness-Contributors
2. Oura — An Introduction to Your Readiness Score. https://support.ouraring.com/hc/en-us/articles/360025589793
3. Oura — Readiness Score (blog). https://ouraring.com/blog/readiness-score/
4. Oura — Resilience. https://support.ouraring.com/hc/en-us/articles/25358829055251-Resilience
5. WHOOP 101 (developer docs). https://developer.whoop.com/docs/whoop-101/
6. WHOOP — Heart Rate Variability (RMSSD). https://www.whoop.com/us/en/thelocker/heart-rate-variability-hrv/
7. WHOOP — How Does WHOOP Recovery Work. https://www.whoop.com/us/en/thelocker/how-does-whoop-recovery-work-101/
8. WHOOP — Podcast 84, respiratory rate added to Recovery. https://www.whoop.com/us/en/thelocker/podcast-84-recovery-update/
9. WHOOP — Strain Coach (support). https://support.whoop.com/hc/en-us/articles/360023313394-Strain-Coach
10. WHOOP — Strain Target. https://www.whoop.com/us/en/thelocker/strain-coach/
11. WHOOP — HRV measured during sleep. https://www.whoop.com/us/en/thelocker/heart-rate-variability-training/
12. Bellenger et al. — WHOOP wrist PPG HRV validation vs ECG. https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8160717/
13. Altini — "What's your normal range for heart rate variability." https://marcoaltini.substack.com/p/whats-your-normal-range-for-heart
14. athletedata.health — HRV-Guided Training guide (7-day baseline ± SWC; CV). https://www.athletedata.health/guides/hrv-guided-training
15. Kiviniemi et al. 2007 — HRV-guided training RCT (10-day mean − 1 SD). https://pubmed.ncbi.nlm.nih.gov/17849143/
16. Meta-analysis (6 RCTs, 195 participants) — HRV-guided training & VO₂max. https://pmc.ncbi.nlm.nih.gov/articles/PMC7663087/
17. Firstbeat/Vesterinen 2016 — smarter endurance training with HRV guidance. https://www.firstbeat.com/en/blog/smarter-endurance-training-heart-rate-variability-guidance/
18. Plews et al. 2013 (Sports Medicine) — 7-day rolling lnRMSSD. https://pubmed.ncbi.nlm.nih.gov/23852425/
19. Buchheit 2014 (Frontiers in Physiology) — canonical HRV monitoring methods. https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2014.00073/full
20. Shaffer & Ginsberg 2017 — RMSSD as vagal index; 42 ± 15 ms norm. https://pmc.ncbi.nlm.nih.gov/articles/PMC5624990/
21. Nummela group 2024 — morning vs nocturnal HR/HRV responsiveness. https://pmc.ncbi.nlm.nih.gov/articles/PMC11541970/
22. Garmin — Training Readiness (official manual; six factors, band cutoffs). https://www8.garmin.com/manuals/webhelp/GUID-C001C335-A8EC-4A41-AB0E-BAC434259F92/EN-US/GUID-C21BE0C8-A08E-4DA1-B6C6-2E0E2DDDB372.html
23. Garmin — Training Readiness (running science). https://www.garmin.com/en-US/garmin-technology/running-science/physiological-measurements/training-readiness/
24. the5krunner — Garmin Training Readiness overview. https://the5krunner.com/garmin-features/training/training-readiness/
25. Plews & Buchheit — "variation in variability" (CV of 7-day lnRMSSD). https://www.researchgate.net/publication/221863314

*NOOP source of truth referenced above: `Packages/StrandAnalytics/Sources/StrandAnalytics/ReadinessEngine.swift`, `HRVReadiness.swift`, `Baselines.swift`, `RecoveryScorer.swift`, `WatchRecovery.swift`, `ScoreConfidence.swift`; `Strand/BLE/PuffinExperiment.swift`; `Strand/Screens/TestCentreView.swift`.*

## Ranked recommendations

| # | Change | Impact | Conf | Effort |
|---|---|---|---|---|
| 1 | Promote the log-domain lnRMSSD personal-normal-band engine (HRVReadiness) out of the default-off experiment into a first-class, default-visible HRV-readiness signal: surface the 7-night lnRMSSD baseline with the shaded ±0.5-SD SWC band and today's point, and drive training guidance off band-position + trend (in-band -> normal; >=2-3 nights below or rising-CV+falling-baseline -> easy/rest). | high | high | medium |
| 2 | Replace ReadinessEngine's naive raw-ms trailing mean/SD (zSignal :218-238; baselineWindow=30/minBaseline=7 :69-73) with the app's own baseline machinery in the log domain: ln-transform HRV, and build baselines via Baselines.foldHistory + Baselines.deviation (robust z = (v-baseline)/(1.253*spread), Winsorized EWMA, cold-start + stale status) or at minimum Baselines.rollingMeanSD, which already returns a status-carrying BaselineState. | high | high | medium |
| 3 | Emit a continuous 0-100 Readiness score (with severity-within-band and hysteresis) that backs the 5-way Level, instead of collapsing every continuous z into 4 flags at hard cut-points 0.5/-0.5/-1.0 (:229-234). | high | medium | medium |
| 4 | Surface confidence + warm-up gating on the Readiness card by reusing ScoreConfidence / BaselineState.status: label the score provisional until ~2-4 weeks, widen its uncertainty early, and show an explicit 'not enough data yet' instead of scoring off a thin baseline. | medium | high | low |
| 5 | Present named contributors with disclosed baseline windows (Oura pattern) and the top 1-2 drivers behind today's score, alongside the trend+band chart, so a low read is explainable (e.g. 'RHR several bpm above baseline; HRV below band'). | high | high | medium |
| 6 | Define Readiness as distinct from Charge by SCOPE: ingest Charge as the recovery term and add ONLY orthogonal load/context terms (training-load balance, sleep debt/regularity, temperature/circadian) as a weighted composite, rather than re-scoring HRV/RHR (already inside Charge) via independent flag-counting. | high | medium | high |
| 7 | Add an explicit weighted coupled term (HRV-down AND RHR-up together) and feed HRV/RHR trend slopes into the verdict, instead of surfacing the coupled case only via the blunt 'rundown' counting rule. | medium | medium | medium |
| 8 | Upgrade ACWR from the biased simple rolling-average (acute mean(7)/chronic mean(28), :184-194) to EWMA-ACWR (Williams/Menaspa), and reconsider the noisy 7-day/min-4 Foster monotony estimate. | medium | medium | medium |
| 9 | Reconcile the three engines (Charge 0-100 EWMA/logistic; Readiness categorical naive-z; experimental HRV-band log-SWC) so they cannot silently point different directions: unify on the log domain + shared baselines, and when axes diverge, show the user a one-line reason (e.g. 'recovery solid, but load spiking and sleep short'). | medium | medium | medium |
| 10 | Add non-clinical presentation guardrails to the Readiness surface: never render population norms as targets; frame temperature/HRV deviations as 'off your baseline' / 'below your recent norm' not illness; surface confounders (alcohol, late meals, poor sleep, menstrual phase, altitude) as caveats; route a persistently abnormal RHR/HRV/temperature pattern to 'consider seeing a clinician' rather than a NOOP interpretation. | medium | high | low |

### Rationale detail

1. **Promote the log-domain lnRMSSD personal-normal-band engine (HRVReadiness) out of the default-off experiment into a first-class, default-visible HRV-readiness signal: surface the 7-night lnRMSSD baseline with the shaded ±0.5-SD SWC band and today's point, and drive training guidance off band-position + trend (in-band -> normal; >=2-3 nights below or rising-CV+falling-baseline -> easy/rest).** — HRVReadiness.swift already implements the exact target method (ln domain :104, 7-night baseline :107, 60/30-night SWC band :119-122, CV-slope overreaching watch :134-149, honest nil<14 nights :78) but is quarantined behind PuffinExperiment.hrvReadinessKey (default OFF, PuffinExperiment.swift:82-96), shown only in TestCentreView (:265-317), feeding nothing. The most evidence-backed HRV view [13][15][16][17] is the one users can't see, while the default engine uses the less-correct raw-ms z. Must ship with warm-up gating + non-clinical caveats and the Kotlin twin (parity contract), and honestly framed as athlete-performance evidence with a small heterogeneous effect.

2. **Replace ReadinessEngine's naive raw-ms trailing mean/SD (zSignal :218-238; baselineWindow=30/minBaseline=7 :69-73) with the app's own baseline machinery in the log domain: ln-transform HRV, and build baselines via Baselines.foldHistory + Baselines.deviation (robust z = (v-baseline)/(1.253*spread), Winsorized EWMA, cold-start + stale status) or at minimum Baselines.rollingMeanSD, which already returns a status-carrying BaselineState.** — The same repo (Baselines.swift :264 foldHistory, :345 deviation, :368 rollingMeanSD) already provides recency-weighting, Winsor/hard-outlier rejection, hard bounds, and calibrating/provisional/trusted/stale states that Charge and WatchRecovery use; ReadinessEngine ignores all of it and rolls a bare mean/sampleSD in raw ms. Result: one bad-decode night both skews the mean and inflates the SD, gaps silently shrink the window, and a weeks-old baseline anchors today with no staleness penalty. Reusing the existing pipeline fixes raw-ms skew, outlier sensitivity, and staleness at once. Requires the Kotlin twin.

3. **Emit a continuous 0-100 Readiness score (with severity-within-band and hysteresis) that backs the 5-way Level, instead of collapsing every continuous z into 4 flags at hard cut-points 0.5/-0.5/-1.0 (:229-234).** — Today a z of -1.01 and -5.0 both read 'bad' and the Level can flip night-to-night on one noisy input (synthesize :275-300). A smoothed continuous score preserves severity and reduces flicker, matches how Oura/WHOOP/Garmin present [2][5][22], and lets the band-position map onto a resolved number rather than a coarse enum. Keep the Level as a headline banded off the continuous score. Kotlin twin required.

4. **Surface confidence + warm-up gating on the Readiness card by reusing ScoreConfidence / BaselineState.status: label the score provisional until ~2-4 weeks, widen its uncertainty early, and show an explicit 'not enough data yet' instead of scoring off a thin baseline.** — minBaseline=7 lets the SD denominator ride on as few as 7 nights with no width shown, unlike Charge which carries ScoreConfidence (calibrating/building/solid, ScoreConfidence.swift:32). Oura learns baselines ~2 weeks [2], Garmin ~3-4 weeks [22], the SWC band stabilizes ~60 days [13]. WatchRecovery's nil+.calibrating pattern is the model to copy. Low effort because the confidence types already exist; honors NOOP's 'never fabricate' ethos.

5. **Present named contributors with disclosed baseline windows (Oura pattern) and the top 1-2 drivers behind today's score, alongside the trend+band chart, so a low read is explainable (e.g. 'RHR several bpm above baseline; HRV below band').** — The shipped card already carries per-signal evidence strings but only as coarse flags; making contributors + baseline windows explicit [1] and showing the shaded personal-normal band [13] is the single biggest actionability win and turns the score from a black box into a decision aid. Avoid population norms (42+-15 ms) as targets [20]; frame every term as self-relative and non-clinical.

6. **Define Readiness as distinct from Charge by SCOPE: ingest Charge as the recovery term and add ONLY orthogonal load/context terms (training-load balance, sleep debt/regularity, temperature/circadian) as a weighted composite, rather than re-scoring HRV/RHR (already inside Charge) via independent flag-counting.** — The best-supported architectural guidance is Readiness = Recovery + load/context, differing by scope not by re-summing inputs [1][5][22]. NOOP already has both axes (RecoveryScorer=Charge, ReadinessEngine adds ACWR/monotony) but ReadinessEngine recomputes HRV/RHR from scratch and combines by counting (synthesize :275-300), risking a redundant second score. Honest caveat: it is not established that a composite beats simply trending the 7-day lnRMSSD band [18], so keep the band first-class and let the composite summarize it. Higher effort: new context terms + Kotlin twin + validation.

7. **Add an explicit weighted coupled term (HRV-down AND RHR-up together) and feed HRV/RHR trend slopes into the verdict, instead of surfacing the coupled case only via the blunt 'rundown' counting rule.** — HRV and RHR together are the dominant, hard-to-fake recovery signal [19], and the coupled divergence is the most informative pattern; today it only appears through synthesize's recoveryDown&&loadHigh rule (:283-288) with no trend/slope input (only the quarantined HRVReadiness computes a slope). A weighted term captures severity the flag-count discards. Kotlin twin required.

8. **Upgrade ACWR from the biased simple rolling-average (acute mean(7)/chronic mean(28), :184-194) to EWMA-ACWR (Williams/Menaspa), and reconsider the noisy 7-day/min-4 Foster monotony estimate.** — Simple rolling-average ACWR is known to be biased vs the exponentially-weighted formulation; since ACWR is the load-context term that differentiates Readiness from Charge, it should use the less-biased estimator. Monotony over only 7 days with min 4 points is a noisy Foster estimate. Moderate confidence because ACWR's injury-prediction validity is itself debated; keep it as context, not a hard gate. Kotlin twin required.

9. **Reconcile the three engines (Charge 0-100 EWMA/logistic; Readiness categorical naive-z; experimental HRV-band log-SWC) so they cannot silently point different directions: unify on the log domain + shared baselines, and when axes diverge, show the user a one-line reason (e.g. 'recovery solid, but load spiking and sleep short').** — The three engines disagree even on domain (raw ms vs ln) and baseline construction (naive mean vs Winsorized EWMA), and nothing reconciles them for the user. The two-axis model is only actionable if the pair is legible [5][9]. Depends on adopting recs 1-2 first (shared log domain + baselines), then a presentation-layer reconciliation. Kotlin twin for any analytics change.

10. **Add non-clinical presentation guardrails to the Readiness surface: never render population norms as targets; frame temperature/HRV deviations as 'off your baseline' / 'below your recent norm' not illness; surface confounders (alcohol, late meals, poor sleep, menstrual phase, altitude) as caveats; route a persistently abnormal RHR/HRV/temperature pattern to 'consider seeing a clinician' rather than a NOOP interpretation.** — NOOP is explicitly non-clinical and 'never fabricate'; the composite's predictive validity is unpublished for every vendor (only sensor accuracy is validated [12]), inter-individual RMSSD spread is huge so only personal baselines are meaningful [20], and confounders move HRV independent of fatigue [19]. Low effort (copy/framing + a simple persistent-abnormal check), high trust/safety payoff, and it hardens the honest-wellness positioning.

