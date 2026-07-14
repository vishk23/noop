# Recovery / Charge (readiness-to-perform)

# Recovery / "Charge" (readiness-to-perform) — Target Methodology for NOOP

*Reconciling the physiology, what Oura and WHOOP actually do, and NOOP's shipped Swift, into a target NOOP should move toward. Every vendor "weight" or "formula" below is flagged where it is a design choice rather than a published fact — because for both vendors, it is.*

---

## PART 1 — TARGET METHODOLOGY

### 1.1 What the score actually is (and what it is not)

Overnight cardiac-autonomic status is a genuine, non-invasive window into daily recovery, and the single most information-dense signal is **vagally-mediated HRV, specifically RMSSD** (root mean square of successive R-R differences) — the standard time-domain index of parasympathetic tone, mathematically identical to Poincaré SD1, with a healthy-adult norm of ~42 ± 15 ms [1]. Higher vagal HRV tracks fitness/freshness; blunted vagal HRV tracks fatigue, high load, illness, and overreaching [4]. But RMSSD alone "might even lead to a dead-end" [4]: the defensible design is a **small, weighted panel of overnight signals, each interpreted against the individual's own rolling baseline**, not against population norms [1][15].

Three honest framings must survive into any implementation:

1. **The single-percent number is the weakest part, medically.** It is a company-specific compression of noisy, **non-independent** signals (poor sleep lowers HRV, so counting a sleep term and an HRV term double-counts one stressor), it is not medically validated, and it is confounded by alcohol, menstrual phase, breathing, body position, and age [15][1]. NOOP's honest, explicitly non-clinical posture — present the drivers and the personal band, not a falsely precise verdict — is the correct one.
2. **Only personal-baseline deviations are meaningful.** Absolute HRV is not comparable between people [15]; the score must be built from *deviations* from the user's own history, which is exactly what both vendors and NOOP already do.
3. **The evidence base is a modest edge, not a decisive one.** A meta-analysis found HRV-guided training beats predefined training specifically for improving RMSSD/SD1 (SMD ≈ 0.50, p<0.01), but when *all* vagal-HRV outcomes are pooled the effect is trivial and non-significant (SMD ≈ 0.15, p=0.59), and every aerobic-performance outcome was non-significant (VO₂max p=0.30, endurance p=0.18) [5]. Readiness-guided autoregulation of load is real and useful, but present it as a *modest edge for adjusting training*, never an established performance guarantee.

### 1.2 The input panel (highest defensible resolution)

Computed per night from a stable, artifact-corrected nocturnal window:

| Input | Definition | Direction | Role |
|---|---|---|---|
| **lnRMSSD** (dominant) | RMSSD over the cleanest low-motion nocturnal segment, natural-log transformed | higher → better | The signal. Log because raw RMSSD is right-skewed [1][17]. |
| **Resting HR** | overnight HR nadir (lowest sustained), not a daytime value | lower → better | Disambiguates HRV; moves largely opposite it [4]. |
| **Respiratory rate** | overnight mean breaths/min (from R-R / amplitude modulation) | rise → worse | Normally 12–20/min, very stable night-to-night; a rise is an early, fairly specific illness/infection precursor [10]. |
| **Skin-temperature deviation** | nightly distal temp minus personal nightly baseline (Δ°C) | **sustained rise → illness flag** (directional) | Small day-to-day noise; a sustained *rise* flags illness, luteal phase, alcohol, overreach [7]. Best used as a *flag*, possibly not a continuous score driver. |
| **Prior-day load** | acute strain from the previous day | context | The physiological *cause* the other signals detect [4] — see §1.4 on where it belongs. |

**Why overnight, not a spot reading:** an overnight measure is less noisy than a single morning spot reading (the rationale WHOOP and Altini both give). *(Note: the specific claims "ultra-short 120 s RMSSD reaches r≈0.99" and "nocturnal ≈ morning RMSSD with no difference" are not supported by the cited primary sources and should not be relied on [1][2]. The defensible core is: 5-min is the conventional minimum window, shorter windows are noisier, and overnight beats a single spot reading.)*

**The HRV-window question has no single right answer.** WHOOP measures RMSSD during a dynamic average weighted toward the **final slow-wave-sleep episode** — self-reported, not independently audited, but physiologically reasonable because SWS is lowest-motion/most-stable [9][21]. Oura uses a **whole-night average**. Each is defensible; there is no ground-truth label that adjudicates between them. Whatever NOOP picks, the definition must be *stated*, because a whole-night mean reads materially higher than a last-SWS mean.

### 1.3 Baseline & personalization — the load-bearing design choice

Today's lnRMSSD/RHR must be compared to a **rolling personal reference**, with a **"normal range" band**. The field standard is a **7-day rolling average of lnRMSSD** (≥3–5 readings/week) referenced against a longer window [5]. Both vendors implement this shape:

- **Oura**: "balance" contributors compare a **14-day recent average (recent 2–5 days up-weighted) vs a ~3-month long-term average**; baselines take up to 2 weeks to learn [7].
- **WHOOP**: normalizes each biometric to a **personal rolling baseline of undisclosed length**, publicly committing only to a **first-4-recordings calibration period** during which the score is greyed out and metrics are compared against age/sex/fitness population priors [8][20]. *(The widely-repeated "~30-day baseline" comes from a single third-party developer blog that in the same passage fabricates unpublished weights; treat it as unconfirmed, not WHOOP fact [16].)*

**The "normal band" width is genuinely unsettled.** The smallest-worthwhile-change literature uses **mean ± 0.5 SD** as the band inside which a change is just noise [6]; HRV-guided-training RCTs have used both **mean − 1 SD** and **mean ± 0.5 SD** as decision thresholds [5]. Below the band → accumulated fatigue/insufficient recovery; inside → no action; above → parasympathetic dominance [6]. For an *elite* athlete 0.5 SD is defensible; for a *noisier general user* a wider band (up to 1.0 SD) reduces false alarms. **There is no single right answer** — the honest move is to pick one, state it, and let trend + band position (not the daily dot) carry the message.

**Baseline windows, likewise, are a spectrum, not a settled constant:** 7-day rolling is the de facto standard for the *recent* lnRMSSD; the *long-term* reference length (14-day vs 30 vs 60 vs exponentially-weighted) is not established by the literature. An EWMA with a ~2-week half-life is a reasonable, defensible middle. **Require a warm-up (~2 weeks / both vendors' range) before scoring, and widen uncertainty when readings are sparse or motion-corrupted.**

### 1.4 Transform → score

1. **Log-transform** the right-skewed positive metrics (RMSSD especially) before baselining, so deviations are near-symmetric [1][17].
2. **Convert each metric to a personal z-score** (or SWC-band position): `z = (today − personal_mean) / personal_SD`, sign-oriented so "better recovery" is positive (higher lnRMSSD → +; higher RHR/resp/temp-rise → −).
3. **Combine as a weighted composite with lnRMSSD dominant**, RHR secondary, respiration/temperature as smaller context terms [8]. Do **not** equal-weight, and guard against double-counting the sleep↔HRV stressor [15]. **Critically: the weights are a design choice, not a validated formula — neither vendor discloses coefficients, and neither publishes evidence that the composite predicts next-day performance better than lnRMSSD-vs-baseline alone.** State this plainly.
4. **Map the composite to a 0–100 personal scale** and present bands. Vendor cutoffs (not cross-comparable): WHOOP green ≥67 / yellow 34–66 / red ≤33 [19]; Oura ≥85 Optimal / 70–84 Good / 60–69 Fair / ≤59 Pay attention [22].

**Parasympathetic-saturation guard (a correctness requirement, not a nicety).** Very fit or deeply-rested people can show *low* HRV together with *low* RHR — this is benign, not fatigue [12][2][13]. Detect it via a **weak or negative correlation between HRV and average R-R interval**; when HRV is low but RHR is *also* low and that correlation is weak/negative, **suppress the "poor recovery" verdict** [12]. Omitting this guard makes the score actively wrong for exactly the fittest users.

### 1.5 Illness / overreach overlays — flags, not buried in the %

These carry high user value and belong **surfaced separately**, with their **sign preserved**, not silently dragging a percentage:

- **Illness flag:** a sustained **respiratory-rate rise** and/or a **skin-temp elevation** beyond the personal band, especially together — an early, days-ahead infection signal [10][7]. *(The specific "±0.5 °C / 3-day-lead" cutoffs come from a commercial blog and should be treated as heuristics of weak provenance, not validated thresholds; Oura's official 95.9–99.3 °F is an absolute normal band, a different quantity from a personal-deviation threshold [7].)*
- **Maladaptation flag:** track the **coefficient of variation of the 7-day rolling lnRMSSD**; a collapsing (or rising) CV over weeks is an early non-functional-overreaching marker even before mean HRV falls [3].

### 1.6 Presentation (equal in importance to computation)

- **Lead with drivers + band, not a lone number.** For each input show today's value, the personal baseline, and whether it sits inside / below / above the band [7]-style. This is both more truthful and more useful, and matches NOOP's philosophy.
- **Trend over point.** The daily value is noisy; the **7-day rolling lnRMSSD trend and band position** carry the signal [4][5]. Surface direction and CV, not just today's dot.
- **Confidence, honestly.** Grey out / caveat until a personal baseline exists (both vendors do: 4 days to 2 weeks) [20][7]; widen the band when data is sparse.
- **Confounder context tags** (alcohol, late meals, menstrual/luteal phase, poor breathing, illness, altitude, body position, age) — allow a low morning to be *explained* rather than alarming [1][15]. Alcohol in particular depresses overnight HRV and raises RHR: a red morning can simply mean last night's drink.
- **Avoid nocebo.** A starkly-presented "red" changes behavior/anxiety; pair every low score with its specific driver and a plausible benign explanation [14].
- **Never imply clinical meaning or cross-app equivalence.** A low score is not illness; a high score is not clearance to train through pain. WHOOP "good" ≥67 and Oura "Optimal" ≥85 are different scales [19][22].

### 1.7 Where WHOOP and Oura diverge, and which is more defensible for NOOP

- **Load handling:** WHOOP **separates** physiological Recovery from behavioral Strain (causally cleaner, aligns with the autonomic-recovery literature); Oura **folds** previous-day activity and activity-balance directly into Readiness (richer but circular — activity predicting readiness) [8][7]. **NOOP should keep behavioral load out of the morning state score** and, if it wants load-awareness, express it in a separate *forward-looking* object (NOOP already does — see §2).
- **Temperature:** Oura treats it as an explicit contributor with sign; WHOOP measures skin temp but does not present it as a primary Recovery driver [7][8][18]. The API/consumer discrepancy on WHOOP's side (developer recovery object exposes SpO2 + skin-temp but *not* respiratory rate, while consumer materials cite respiratory rate + sleep and omit SpO2/skin-temp) shows even the vendor is ambiguous about what enters the score [18].
- **Input accuracy:** in one small study (Dial 2025, n=13, 536 nights vs Polar-H10 ECG), Oura Gen3/4 nocturnal RHR/HRV were cleaner than WHOOP 4.0 [24]. **This does not drive NOOP design:** it validates device-*firmware inputs*, not composite scores; it tested WHOOP 4.0 (not the WHOOP 5.0 NOOP pairs with) and Oura Gen3/4; WHOOP's HRV error carried a huge ±10.49% SD; and it says nothing about NOOP's own on-device R-R→RMSSD pipeline, which is the only accuracy that matters here. Per NOOP's own anti-#194 rule, any derived signal must be shown to **track a varying input**, not match one vendor on one night.

**Net target for NOOP:** a physiological-state score **dominated by personalized overnight lnRMSSD**, plus signed deviation terms for RHR and respiration, with **skin-temp and respiration doubling as a separate directional illness flag**; scored against the user's own rolling baseline with a stated band; **behavioral load kept out of the morning number** and expressed in a separate forecast; a **saturation guard** as a hard correctness requirement; and presentation that leads with drivers, trend, band, and confidence — labeling the number an approximate, non-clinical, design-chosen index, because that is exactly what both vendors are hiding.

---

## PART 2 — GAP ANALYSIS (NOOP's shipped Swift vs the target)

NOOP's Charge is `RecoveryScorer.recovery(...)` — a personal-baseline robust-z composite squashed through a logistic, explicitly labeled APPROXIMATE. **Verified against the working tree** (`RecoveryScorer.swift:208–252`, `Baselines.swift`, `ChargeDrivers.swift`, `IntelligenceEngine.swift:1506–1515`): the shipping score is a **5-term composite** — HRV (wHRV=0.55), RHR (0.20), Rest/sleep (0.15), respiration (0.05), skin-temp (0.05) — renormalized when a term is nil, mapped by `100/(1+exp(−1.6·(z+0.20)))`, banded red<34 / yellow<67 / green.

### What NOOP already gets right (credit before critique)

- **HRV-dominant, personal-baseline, robust-z composite** — the correct *shape* [1][15]. Baselines are per-metric Winsorized EWMA (`Baselines.swift:185`) with a genuinely thoughtful **early-life anti-anchoring fix** (`Baselines.swift:128–134`, `earlyAdaptNights=8`, `earlyHalfLifeB=3`, `earlySpreadInflate=2.5`) that solves the exact cold-start "seed locks high, rejects real lower nights" failure the literature warns about.
- **Honest cold-start:** `recovery()` returns nil until the HRV baseline is usable (≥4 valid nights), showing "Calibrating — N of 4 nights" (`calibrationNights`, `RecoveryScorer.swift:155`) rather than a fabricated value — matching both vendors' calibration discipline [20][7].
- **Drivers are surfaced,** not just a number: `chargeDrivers` (`ChargeDrivers.swift:122`) emits an ordered per-term breakdown with value, baseline, and plain-English verdict — this is the §1.6 "lead with drivers" target, already built.
- **Confidence is modeled:** `ScoreConfidence.charge(...)` (calibrating/building/solid) exists.
- **Load is already kept out of the morning score and lives in a separate forward-looking object:** `RecoveryForecast.swift` (wired into `IntelligenceView.swift`) projects tomorrow-morning Charge from prior-day Effort, sleep-vs-need, and mean-reversion, with an honest ± band. **This is the WHOOP "separate state from load" discipline, done right** — and it means the branch's dead "Activity-Balance" term (§below) would *duplicate* logic the forecast already owns.

### Gaps vs target

1. **No parasympathetic-saturation guard (correctness gap).** The composite has no branch for "low HRV + low RHR + weak HRV↔R-R correlation → benign" [12][2][13]. For NOOP's fittest/most-rested users, a low-HRV night with a low RHR is scored as poor recovery — the one case the guard exists to prevent. NOOP computes R-R already, so the correlation input is available.

2. **Skin-temp is a symmetric penalty that discards sign (`RecoveryScorer.swift:242`, `−abs(dev)/1.0`).** Any drift — a benign cool room or a fever — lowers Charge equally, throwing away the directional information Oura uses for illness detection [7]. The illness signal (§1.5) is *buried in the %* instead of surfaced as a flag. (`SkinTempRelative` at `ChargeDrivers.swift:56` *does* keep the sign for display, but the score term does not.)

3. **No separate illness/overreach flag.** Respiration (weight 0.05, frequently dropped when RSA-from-RR is non-finite) and skin-temp are tiny score terms, not the days-ahead illness overlay the science calls high-value [10][7]. The maladaptation marker (CV of 7-day lnRMSSD [3]) is not computed.

4. **The dominant driver is not log-transformed and the robust-z assumes symmetry.** `zScore` (`RecoveryScorer.swift:182`) uses raw ms with an EWMA-abs-dev spread (×1.253 → σ), i.e. it treats equal-magnitude high and low RMSSD deviations as equally probable, but RMSSD is right-skewed — the literature's reason for lnRMSSD [1][17]. No log handling anywhere.

5. **Two terms are not personalized while the rest are:** `sleepPerfCenter=0.85` / `sleepPerfScale=0.12` and `skinTempScaleC=1.0` are **fixed population constants** (`RecoveryScorer.swift:49,63,65`), so a habitual short/long/variable sleeper, or someone with a different skin-temp amplitude, is mis-centered/mis-scaled against a population norm — the exact thing §1.3 says to avoid — while HRV/RHR/resp *are* baselined.

6. **HRV definition is mode-dependent and neither vendor's.** Default is a **whole-night mean RMSSD** (deep-only is opt-in; `IntelligenceEngine.swift:495`), which the code's own trace notes reads ~2× higher than WHOOP's last-SWS convention and is not identical to Oura's whole-night average either. Defensible, but the dominant driver's definition should be *stated* to the user, not silent.

7. **Watch path conflates SDNN and RMSSD.** `WatchRecovery.compute` (`WatchRecovery.swift:60`) feeds **SDNN** into the **RMSSD-tuned `hrvCfg`** (bounds 5–250, floorSpread 5). SDNN and RMSSD have materially different magnitudes/distributions, so watch Charge is scored against a mis-tuned config.

8. **Trend/band is not the primary object.** The score is a per-day logistic %; `Deviation.inNormalRange` uses `|z| ≤ 1.0` (`Baselines.swift:81`), not the ±0.5 SD smallest-worthwhile-change band [6], and nothing surfaces the 7-day rolling lnRMSSD trend or CV as the lead signal [4][5]. The user sees a noisy daily dot, not the trend that carries the message.

9. **Honesty-contract doc drift (shipped, real).** `ChargeDrivers.swift` top comment (lines 19–20) says `deltaPoints` = "score with every present term minus the score recomputed with this term **omitted** and the remaining weights **renormalized**." The actual `points()` impl (lines 140–153) does the opposite — it **neutralizes each term to z=0 while keeping its weight** — and its own inline comment says the top comment's method "would be WRONG here." Two contradictory specs for an honesty-contract file. (The implementation is the correct choice; the file-top comment is stale.) Also inherent: because the composite is logistic, per-term `deltaPoints` do not sum to the headline, so driver rows can misstate relative influence near the saturation ends.

10. **Dead scaffolding on the `readiness-recovery-index` branch.** That branch adds `recoveryIndexSlope` (overnight RHR-decline slope) and Activity-Balance (prior-day Effort vs strain baseline), unit-tested but **wired by zero production callers** (grep confirms these symbols exist in no non-test Swift on either the branch or the working tree). Even if wired, `chargeDrivers`/`recoveryTrace` cover only the original 5 terms, so the new drivers would be invisible in the "why is my Charge" breakdown. Activity-Balance would also duplicate `RecoveryForecast`'s load handling.

11. **Unvalidated constants.** The weights (0.55/0.20/0.15/0.05/0.05), the logistic (k=1.6, z0=−0.20 → z=0 anchors to 58%), the "58% population average" label, and the fixed sleep/skin scales are hand-set, fit to no labeled outcome. The only cited check is r≈0.71 correlation to Oura Readiness — similarity to another proxy, not ground truth. This is *acceptable and honest* (both vendors are in the same position [8][7]) **provided NOOP keeps saying so** — but the 58% "WHOOP-published population average" label is itself uncited and should be softened to a design anchor.

---

## PART 3 — ACTIONABILITY (what the user should be able to DO)

A recovery score is only worth showing if it changes a decision. The target NOOP experience:

**The one decision it should drive: how hard to go today.** Map the band to an action, the way both vendors do — green/high → today's a day you can push; yellow/moderate → maintain; red/low → prioritize rest [8]. But because the evidence for this is a *modest* edge [5], frame it as a nudge ("your body looks primed / average / taxed"), never a command.

**Make the *why* the product, not the number.** NOOP already emits `chargeDrivers`; the UI should lead with those rows — "HRV 41 ms vs 48 ms baseline, limiting recovery; resting HR 52 vs 55, supporting" — so the user sees which lever moved and can act on the controllable one (sleep, alcohol, load). A lone 46% is un-actionable; "46% because HRV is down and you logged a late drink" is.

**Show the trend and band, not just today.** Surface the 7-day rolling lnRMSSD direction and where today sits in the personal band. A single red morning inside the normal band is noise; three declining mornings *below* the band is a real signal to back off [4][5][6]. This is the single highest-value presentation change.

**Surface illness/overreach as its own alert.** "Respiratory rate and skin temp both elevated 2 nights running — possible illness coming; consider easing off" is genuinely useful and days-ahead [10][7] — far more so than the same signal silently shaving 3 points off a percentage.

**Explain benign reds to avoid nocebo.** Pair every low morning with a plausible cause and a confounder tag ("HRV low, but you logged alcohol / you're in your luteal phase / you slept 5 h") [1][15][14]. NOOP's journaling (via the noop-cloud MCP) is a natural source for these tags. And retain the saturation guard so the fittest users aren't told they're wrecked when they're simply deeply parasympathetic [12].

**Let the forecast close the loop.** `RecoveryForecast` already projects tomorrow's Charge from tonight's controllable levers (sleep, today's strain). Presenting it as "if you sleep your 8 h you'll likely wake at ~62 ± 6" turns the score from a verdict into a *plan* — the most actionable framing available, and one neither vendor foregrounds.

**Always show confidence and calibration state.** Use `ScoreConfidence` to widen the band and soften the language when data is thin, and keep the honest "Calibrating — N of 4 nights" state. A confident-looking number on 4 nights of data is a lie the honest architecture already avoids — keep it that way.

---

## Sources

1. Shaffer & Ginsberg, *An Overview of Heart Rate Variability Metrics and Norms* — RMSSD as primary vagal index = SD1; norm 42±15 ms; 5-min conventional minimum; confounders. https://pmc.ncbi.nlm.nih.gov/articles/PMC5624990/
2. Plews et al. 2013, *Sports Med* — elite HRV monitoring; lnRMSSD near-normal; reductions in HRV despite decreases in resting HR (saturation). https://pubmed.ncbi.nlm.nih.gov/23852425/
3. Plews et al. 2012 — CV of 7-day rolling lnRMSSD as early non-functional-overreaching marker. https://pubmed.ncbi.nlm.nih.gov/22367011/
4. Buchheit 2014, *Front. Physiol.* — RMSSD as vagal index; high load lowers vagal HRV; RMSSD-alone "dead-end." https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2014.00073/full
5. Meta-analysis, HRV-guided vs predefined training — RMSSD/SD1 SMD 0.50 (p<0.01); pooled vagal-HRV 0.15 (p=0.59); aerobic outcomes non-sig; thresholds mean−1SD & mean±0.5SD; 7/10-day baselines. https://pmc.ncbi.nlm.nih.gov/articles/PMC8507742/
6. EliteHRV — normal band = baseline mean ± 0.5 SD (smallest worthwhile change). https://elitehrv.com/improving-hrv-data-interpretation-coefficient-variation
7. Oura, *Readiness Contributors* (official) — 9 contributors; RHR 3–5/10–15 bpm; HRV Balance 14-day vs 3-month; Body Temp deviation; Recovery Index ≥6 h; ~2-week learning; normal 95.9–99.3 °F. https://support.ouraring.com/hc/en-us/articles/360057791533-Readiness-Contributors
8. WHOOP, *How Recovery Works* — 4 sleep-measured inputs, HRV weighted most; 4-day calibration; personalized baseline. https://www.whoop.com/us/en/thelocker/how-does-whoop-recovery-work-101/
9. WHOOP — RMSSD measured during deepest/last SWS episode; ECG-agreement validation. https://www.whoop.com/us/en/thelocker/whoop-proven-most-accurate-wearable-in-heart-rate-heart-rate-variability-measurements/
10. WHOOP — respiratory rate ~12–20/min, stable night-to-night; a rise is an early infection precursor. https://www.whoop.com/us/en/thelocker/what-does-an-infection-do-to-your-respiratory-rate/
11. Smartlet (commercial blog, weak provenance) — nightly temp ~0.2 °C stable; >0.5 °C flags illness; ~3-day lead. https://smartlet.io/blogs/magazine/body-temperature-trends-early-illness-detection
12. Altini, *Parasympathetic Saturation* — low HRV + low RHR can be benign; detect via weak/negative HRV↔R-R correlation; measure sitting. https://marcoaltini.substack.com/p/parasympathetic-saturation
13. Buchheit & Schmitt 2015, *Beyond RMSSD?* — combine HRV indices; saturation can bias RMSSD downward. https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2015.00343/full
14. Qualitative study of exercisers — users recognize wearable-readiness limitations. https://pubmed.ncbi.nlm.nih.gov/38668986/
15. WellnessPulse — recovery scores are company-specific, non-independent, not medically validated; only personal-baseline deviations are meaningful. https://wellnesspulse.com/healthtech/wearable-recovery-scores-explained/
16. OpenWearables (third-party dev blog, low reliability) — claims WHOOP ~30-day % baseline; also fabricates unpublished weights (discard). https://openwearables.io/blog/whoop-recovery-strain-sleep-data-for-developers
17. Best-practice on log-transforming right-skewed positive biological variables (basis for lnRMSSD). https://pmc.ncbi.nlm.nih.gov/articles/PMC9036143/
18. WHOOP Developer API — recovery object = recovery_score, resting_heart_rate, hrv_rmssd_milli, spo2_percentage, skin_temp_celsius, user_calibrating (no respiratory_rate). https://developer.whoop.com/docs/developing/user-data/recovery/
19. WHOOP Recovery bands — Green 67–100 / Yellow 34–66 / Red 1–33. https://support.whoop.com/s/article/WHOOP-Recovery
20. WHOOP — first-4-recordings calibration; population priors until personalized. https://support.whoop.com/hc/en-us/articles/360019622573-What-is-the-Recovery-calibration-period-
21. WHOOP — HRV as RMSSD, dynamic sleep average weighted to last SWS. https://www.whoop.com/us/en/thelocker/heart-rate-variability-hrv/
22. Oura *Readiness Score* — bands 85–100 / 70–84 / 60–69 / 0–59. https://support.ouraring.com/hc/en-us/articles/360025589793-Readiness-Score
23. Oura blog — 7 contributors / 3 pillars; prior-day activity folded in. https://ouraring.com/blog/readiness-score/
24. Dial 2025, *Physiological Reports* (n=13, 536 nights vs Polar-H10) — Oura Gen3/4 vs WHOOP 4.0 RHR/HRV; validates inputs, not composites; not WHOOP 5.0. https://pmc.ncbi.nlm.nih.gov/articles/PMC12367097/
25. MDPI *Sensors* 2024 — Oura nocturnal HR/rMSSD/frequency-domain HRV vs ECG, small biases. https://www.mdpi.com/1424-8220/24/23/7475
26. WHOOP wrist-PPG validation — HR and lnRMSSD agreement with ECG. https://www.researchgate.net/publication/351769975

*Verified NOOP source (working tree, branch `puffin-raw-probe`): `/Users/vk/VKDEV/NOOP/noop/Packages/StrandAnalytics/Sources/StrandAnalytics/RecoveryScorer.swift`, `Baselines.swift`, `ChargeDrivers.swift`, `ScoreConfidence.swift`, `RecoveryForecast.swift`, `WatchRecovery.swift`; live call site `/Users/vk/VKDEV/NOOP/noop/Strand/Data/IntelligenceEngine.swift:1506–1515`.*

## Ranked recommendations

| # | Change | Impact | Conf | Effort |
|---|---|---|---|---|
| 1 | Add a parasympathetic-saturation guard to RecoveryScorer.recovery: when the HRV term is negative (low vs baseline) AND resting HR is also low vs baseline AND the HRV↔R-R-interval correlation is weak/negative, suppress or soften the low-Charge verdict and attach a benign-explanation tag instead of scoring it as poor recovery. | high | high | medium |
| 2 | Make the 7-day rolling lnRMSSD trend and personal-band position the primary presented object, with the daily logistic % secondary. Compute the rolling trend + its coefficient of variation, and present today's value as inside/below/above a stated band (choose 0.5 SD or 1.0 SD and state it) rather than as a noisy standalone dot. | high | high | medium |
| 3 | Split skin-temp and respiratory rate out of the score as a separate, directional illness/overreach flag: surface a sustained skin-temp RISE and/or respiratory-rate rise (and the CV-of-7-day-lnRMSSD maladaptation marker) as their own alert, and stop entering skin-temp as a symmetric -|dev| penalty that discards sign (RecoveryScorer.swift:242). | high | medium | medium |
| 4 | Fix the ChargeDrivers honesty-contract doc drift: update the file-top comment (ChargeDrivers.swift lines 19-20) so it describes the actual neutralize-to-baseline (z=0, keep weight) attribution the points() impl uses, not the omit-and-renormalize method the code's own inline comment (lines 140-153) says would be WRONG. | medium | high | low |
| 5 | Personalize the two currently-fixed terms: replace sleepPerfCenter=0.85 / sleepPerfScale=0.12 and skinTempScaleC=1.0 (RecoveryScorer.swift:49,63,65) with per-user baselines (a personal Rest-quality baseline and the personal skin-temp deviation spread), the same way HRV/RHR/resp are baselined via Baselines.swift. | medium | high | medium |
| 6 | Log-transform HRV (lnRMSSD) before baselining and z-scoring, rather than z-scoring raw ms with a symmetric abs-dev spread (RecoveryScorer.swift:182, zScore). | medium | high | medium |
| 7 | Give the Apple Watch SDNN path its own baseline config instead of feeding SDNN into the RMSSD-tuned hrvCfg (WatchRecovery.swift:60; hrvCfg bounds 5-250, floorSpread 5 in Baselines.swift:150). | medium | high | low |
| 8 | Resolve the dead Recovery-Index / Activity-Balance scaffolding on branch readiness-recovery-index: either delete it or wire it with driver-row + trace coverage. Prefer keeping behavioral load OUT of the morning Charge (WHOOP discipline) since RecoveryForecast.swift already owns prior-day strain and sleep-vs-need; if Recovery-Index (overnight RHR-decline slope) is kept, validate it tracks a varying input per the repo's anti-#194 rule before it gates anything. | medium | medium | low |
| 9 | Add confounder context tags (alcohol, late meal, menstrual/luteal phase, short sleep, illness) that annotate a low morning without dragging the number, sourced from NOOP's journaling, and soften the uncited '58% WHOOP population average' logistic anchor (RecoveryScorer.swift:54-56) to an explicit design anchor. | medium | medium | high |

### Rationale detail

1. **Add a parasympathetic-saturation guard to RecoveryScorer.recovery: when the HRV term is negative (low vs baseline) AND resting HR is also low vs baseline AND the HRV↔R-R-interval correlation is weak/negative, suppress or soften the low-Charge verdict and attach a benign-explanation tag instead of scoring it as poor recovery.** — This is a correctness gap, not a nicety: the literature is explicit that low HRV + low RHR is benign for fit/deeply-rested users [12][2][13], and NOOP's composite has no such branch, so it actively mislabels its fittest users as unrecovered. NOOP already computes R-R intervals, so the correlation input is available on-device.

2. **Make the 7-day rolling lnRMSSD trend and personal-band position the primary presented object, with the daily logistic % secondary. Compute the rolling trend + its coefficient of variation, and present today's value as inside/below/above a stated band (choose 0.5 SD or 1.0 SD and state it) rather than as a noisy standalone dot.** — The science is consistent that the trend and band position carry the signal while the daily point is noise [4][5][6]; both vendors normalize to a rolling baseline for exactly this reason. NOOP currently shows a per-day % and uses |z|<=1.0 for 'normal range' (Baselines.swift:81) with no trend/CV surfaced. Highest-value presentation change and mostly additive.

3. **Split skin-temp and respiratory rate out of the score as a separate, directional illness/overreach flag: surface a sustained skin-temp RISE and/or respiratory-rate rise (and the CV-of-7-day-lnRMSSD maladaptation marker) as their own alert, and stop entering skin-temp as a symmetric -|dev| penalty that discards sign (RecoveryScorer.swift:242).** — The current symmetric penalty throws away the directional information Oura uses for illness detection and penalizes benign cooling identically to a fever [7]; the days-ahead illness signal is high user value but is buried in the % instead of flagged [10][7][3]. SkinTempRelative (ChargeDrivers.swift:56) already keeps the sign for display, so the directional data exists.

4. **Fix the ChargeDrivers honesty-contract doc drift: update the file-top comment (ChargeDrivers.swift lines 19-20) so it describes the actual neutralize-to-baseline (z=0, keep weight) attribution the points() impl uses, not the omit-and-renormalize method the code's own inline comment (lines 140-153) says would be WRONG.** — This is a shipped, self-contradictory spec inside a file whose entire purpose is the transparency/honesty contract; the implementation is the correct choice, so the cheap, high-confidence fix is to correct the stale top comment. Cross-platform parity note: keep the Kotlin twin's comment aligned.

5. **Personalize the two currently-fixed terms: replace sleepPerfCenter=0.85 / sleepPerfScale=0.12 and skinTempScaleC=1.0 (RecoveryScorer.swift:49,63,65) with per-user baselines (a personal Rest-quality baseline and the personal skin-temp deviation spread), the same way HRV/RHR/resp are baselined via Baselines.swift.** — Mixing personalized and population-fixed terms mis-centers habitual short/long/variable sleepers and people with different skin-temp amplitudes against a population norm, the exact anti-pattern the personal-baseline design exists to avoid [15][7]. The Baselines EWMA machinery is already in place, so this is extending an existing pattern.

6. **Log-transform HRV (lnRMSSD) before baselining and z-scoring, rather than z-scoring raw ms with a symmetric abs-dev spread (RecoveryScorer.swift:182, zScore).** — RMSSD is right-skewed; virtually all sport-science monitoring uses lnRMSSD so deviations are near-symmetric and a robust z is valid [1][2][17]. The current raw-ms robust z treats equal-magnitude high and low deviations as equally probable, which they are not. Caveat/effort driver: baselines are stored in raw ms, so this must be threaded consistently and mirrored in the Kotlin twin to preserve the cross-platform byte-identical analytics contract.

7. **Give the Apple Watch SDNN path its own baseline config instead of feeding SDNN into the RMSSD-tuned hrvCfg (WatchRecovery.swift:60; hrvCfg bounds 5-250, floorSpread 5 in Baselines.swift:150).** — SDNN and RMSSD have materially different magnitudes and distributions, so scoring watch HRV against an RMSSD-tuned config mis-scales the deviation and therefore the watch Charge. Adding an sdnnCfg (bounds/floorSpread appropriate to SDNN) is a localized change.

8. **Resolve the dead Recovery-Index / Activity-Balance scaffolding on branch readiness-recovery-index: either delete it or wire it with driver-row + trace coverage. Prefer keeping behavioral load OUT of the morning Charge (WHOOP discipline) since RecoveryForecast.swift already owns prior-day strain and sleep-vs-need; if Recovery-Index (overnight RHR-decline slope) is kept, validate it tracks a varying input per the repo's anti-#194 rule before it gates anything.** — recoveryIndexSlope/priorDayEffort/effortBaseline are unit-tested but wired by zero production callers (grep-confirmed in no non-test Swift), and Activity-Balance would duplicate RecoveryForecast's load handling; chargeDrivers/recoveryTrace cover only the 5 original terms so new terms would be invisible in the breakdown. CLAUDE.md requires a derived signal prove it tracks a varying input, not match one vendor once.

9. **Add confounder context tags (alcohol, late meal, menstrual/luteal phase, short sleep, illness) that annotate a low morning without dragging the number, sourced from NOOP's journaling, and soften the uncited '58% WHOOP population average' logistic anchor (RecoveryScorer.swift:54-56) to an explicit design anchor.** — Confounders move these signals independent of recovery, and pairing a low score with a plausible benign cause is both more honest and avoids nocebo/'red sting' [1][15][14]; NOOP has journaling via the noop-cloud MCP as a natural tag source. The 58% anchor label claims a WHOOP-published figure that appears in no source and should be presented as a chosen anchor, consistent with NOOP's honesty posture.

