# Daily Stress & autonomic scoring — redesign, illness detection, predictive analytics

Status: **DailyStressEngine implemented + validated** (this file's §3). Illness/overreach flag (§4) and
predictive layer (§5) are **designed, future work**. Grounded in a four-stream literature review
(HRV sports-science; Oura/WHOOP methodology; wearable illness detection; predictive ML), all cited inline.

---

## 0. Thesis

The old daily Stress score (`StressModel`/`StressMath` in `Strand/Screens/StressView.swift`) summed two
z-scores — `zRHR = (todayRHR − meanRHR)/sdRHR` and `zHRV = (meanHRV − todayHRV)/sdHRV` — computed with a
**naive arithmetic mean + population SD on RAW HRV milliseconds** over a single 30-day window. Four things
are wrong with that, and one deeper problem sits underneath all of them.

The four mechanical defects (each independently confirmed in the literature):
1. **Raw ms, not log.** RMSSD is right-skewed; a symmetric z on raw ms is statistically invalid and
   outlier-dominated.
2. **Naive mean+SD.** No robustness to a freak night; no σ-floor, so a tight baseline saturates the logistic.
3. **Single 30-day window.** Forces the adapt-vs-hide tradeoff (below).
4. **Equal-weight RHR+HRV sum.** Throws away the *divergence* between the two channels, which is the most
   informative part.

The deeper problem — the **confound**: HRV suppression + RHR elevation is genuine autonomic load, but it is
**"sensitive but not specific"** (Altini 2021, n≈9M, [MDPI Sensors](https://www.mdpi.com/1424-8220/21/23/7932)).
A supplement, a training block, altitude, poor sleep, illness, and psychological stress all produce the same
signature. The physiology *cannot name the cause*. So a daily "stress" score that keys on it will read high
every day a user is on a sustained autonomic-shifting influence — which is exactly what NOOP's own owner's
supplement protocol produces (nightly HRV suppressed ~85 ms vs a historical ~120–155, RHR elevated ~55 vs
~50, sustained 6+ weeks).

---

## 1. The adapt-vs-hide tradeoff (the crux)

A rolling personal baseline has one knob — the window — and it forces a bad choice:

- **Adapt (short window).** The suppressed level becomes "my recent normal" within ~2 weeks, so the daily
  score self-normalizes and stops crying "high stress." **But the sustained load has been defined away** —
  the score can no longer tell the user their baseline itself has moved.
- **Don't adapt (long/fixed window).** The score keeps flagging the shift forever — a permanent false
  "high stress" for a benign sustained cause.

Both Oura and WHOOP default to **adapt** (Oura recalibrates "daily … adapts if your baselines change";
WHOOP's 14-day window absorbs a shift in ~2–3 weeks) and simply accept the blind spot. Their context tags /
journals annotate but **do not feed the score** (Oura Tags, WHOOP Journal drive a *separate* correlational
"Impacts" view). ([Oura Daytime Stress](https://ouraring.com/blog/inside-the-ring-daytime-stress/),
[WHOOP behaviors](https://www.whoop.com/us/en/thelocker/a-new-way-to-see-insights-on-which-behaviors-affect-your-recovery/))

**Resolution: dual baselines.** A short adaptive window drives the daily 0–3 (so it normalizes), and a long
reference powers a *separate* honest readout — "your baseline itself has shifted N% for D days." Neither
vendor publicly does this; it is the only clean escape from the tradeoff, and it is what §3 implements.

---

## 2. Research foundation (cited)

### 2.1 HRV sports-science
- **Log-domain is mandatory.** Raw RMSSD test–retest CV ≈ 30%; lnRMSSD ≈ 3–13% (e.g. 5.4% over 16 wk in
  athletes). lnRMSSD is near-normal, making a symmetric z valid. (Plews 2013 [PMID 23852425](https://pubmed.ncbi.nlm.nih.gov/23852425/);
  Altini; WHOOP water-polo reliability [PMC9505647](https://pmc.ncbi.nlm.nih.gov/articles/PMC9505647/).)
- **Smallest Worthwhile Change (SWC) = mean ± 0.5 SD** (Hopkins 2000; Buchheit 2014) — inside the band is
  noise, don't act.
- **Short vs long window is the right structure for acute-vs-chronic** (Altini): acute = 7d dips below the
  60d band then recovers; chronic = the 60d band itself re-centers, after which the daily z auto-returns to 0.
- **Two windows do two jobs**: 7d = operational baseline; 60d = normal-range band (HRV4Training uses 60d).

### 2.2 The coupled quadrant (the single most important design decision)
**Buchheit 2014** ([10.3389/fphys.2014.00073](https://www.frontiersin.org/articles/10.3389/fphys.2014.00073/full))
— interpret lnRMSSD change *jointly* with RHR:

| lnRMSSD | RHR | meaning |
|---|---|---|
| ↑ | ↓ | coping well / parasympathetic adaptation |
| ↓ | **↑** | **sympathetic overactivity = real stress/fatigue** |
| ↓ | ↓ | **parasympathetic saturation (benign)** — or overtraining only if prolonged |
| ↑ | ↑ | taper / sympathetic reversal |

Low HRV is only "stress" in the **↓/↑** cell. Low HRV with **low** RHR is benign saturation. This is the exact
logic NOOP's recovery-saturation guard (upstream #461) already uses on Charge — it belongs in Stress too.
HRV should carry most of the weight (more sensitive); RHR is decisive precisely when it *diverges*
(Altini; WHOOP: RHR "adds signal mainly when it trends differently from HRV").

### 2.3 Oura / WHOOP (what they actually do)
WHOOP: lnRMSSD in deep sleep vs a 14-day baseline; HRV-primary; 0–3 stress scale. Oura: personal baseline
recalibrated daily, windows undisclosed, "cannot distinguish psychological stress from exercise, caffeine, or
other sympathetic activation" (their own words). Neither publishes the weighting, outlier handling, or a
dual-baseline. Their blogs are ~90% marketing; the rigor is in the HRV literature, not the vendor copy.

### 2.4 Illness detection → §4. ### 2.5 Predictive ML → §5.

---

## 3. Implemented: `DailyStressEngine` (StrandAnalytics)

A pure, tested package engine replacing the inline `StressMath`. Four evidence-backed changes:

1. **Log-domain HRV** — z-scores lnRMSSD via the shared spine's ln config (`readiness_hrv_ln`).
2. **Dual baselines** — a **14-night** adaptive baseline drives the daily 0–3; a **60-night** reference powers
   a separate `ChronicShift` readout. Both fold through the RD2 **window-fold spine mode**
   (`Baselines.foldHistory(..., rejectHardOutliers: false)`) so a sustained shift *adapts* (isn't rejected)
   while a single freak night is Winsor-*damped*.
3. **Coupled escalation** — `saturationDamp(hrvZ:rhrZ:)` mirrors the #461 recovery guard: when HRV is
   suppressed but RHR is **not** elevated, the HRV stress term is damped (benign saturation). Weight
   HRV 0.6 / RHR 0.4. A `Quadrant` (balanced / sympatheticStress / parasympatheticSaturation / recovered)
   carries the interpretation.
4. **SWC dead-zone** — a combined |raw| under 0.5σ reads as baseline (1.5), not stress.

**`ChronicShift`** reports `hrvPctBelowLongTerm`, `rhrBpmAboveLongTerm`, `isSustainedLoad` (both channels
shifted together — the coupled sustained-load gate), and `daysBelowBand`.

### Real-data validation (owner's 420-night history, replayed)
- **2026-07-10**: daily score **1.50 (neutral)** — the short baseline had adapted to the suppressed level —
  while the chronic readout showed **HRV −31% below the 60-day normal**. The reframe working exactly as
  designed: the daily number stops crying "stress"; the sustained load surfaces separately.
- **2026-07-13**: **2.02** — HRV genuinely dipped below the recent baseline, so a fresh elevation is correct.
- **Supplement onset (2026-06-08)**: **2.87** — the acute crash correctly reads high.
- **Coupling proven**: an identical HRV drop reads lower and classifies `parasympatheticSaturation` when RHR
  is low, vs `sympatheticStress` when RHR is high.
- **Key finding**: it is the **short adaptive window**, not the log transform, that reframes the number — an
  earlier single-30d-window A/B showed log-domain alone was a ~no-op on the owner's score.

**Honest caveat for the owner specifically**: his recent RHR *is* elevated above his own baseline (≈55 vs
≈50), so he sits in the genuine **↓HRV/↑RHR sympathetic-load** cell — the redesign does not (and should not)
make his number "calm"; it *reframes* the sustained part as a baseline shift and keeps the daily number
honest about fresh dips.

### Not yet wired (validated follow-up)
`StressModel` still calls the old `StressMath`. Wiring it to `DailyStressEngine` swaps the **primary visible
Today-card number** and should ship *with* a minimal UI surfacing of `ChronicShift` (so a lower daily number
is explained by the "baseline shifted" line), validated on real data. Sequenced deliberately after this
engine + doc land.

---

## 4. Future work — signed illness / overreach flag (M7)

The current skin-temp / respiration terms in Recovery are **symmetric penalties** (a +0.5 °C fever scores the
same as −0.5 °C benign cooling), discarding the directional illness signal. The research is clear and the fix
is well-specified.

**Physiology (directional, concordant, ~1–3 days pre-symptom):** skin temp ↑, respiratory rate ↑, RHR ↑,
HRV ↓. Respiratory rate is the **highest-SNR anchor** (baseline varies <1 rpm; illness +2–3 rpm/~17%) and is
rarely moved by alcohol/caffeine/poor sleep — the ideal disambiguator. Temperature adds the most
discriminating power when present. (TemPredict/Oura-UCSF, *Sci Rep* 2022 [PMC8891385](https://pmc.ncbi.nlm.nih.gov/articles/PMC8891385/):
AUC 0.819, sens 82%, **spec 63%**, ~2.75 d lead; Stanford/Snyder *Nat Biomed Eng* 2020
[PMC9020268](https://pmc.ncbi.nlm.nih.gov/articles/PMC9020268/), real-time CuSum caught 62.5%; Fitbit/Scripps
DETECT *Nat Med* 2021.)

**Design:**
1. **Signed / one-sided** on temp & RR — only sustained **rises** accrue illness evidence; falls are neutral.
2. **Robust personal baseline** (~14–28 nights, median/MAD), excluding known-confounded nights.
3. **Physiology-anchored thresholds**: temp > +0.3–0.5 °C (above the ~0.3–0.5 °C luteal floor), RR > +1.5–2
   rpm / >10–15%, RHR > +5–7 bpm, HRV a meaningful SD below.
4. **Concordance + persistence gating**: `major` only when ≥3 of {temp↑, RR↑, RHR↑, HRV↓} agree and hold
   ≥2 nights; `minor` for one strong/transient signal. Weight temp + RR highest (most infection-specific).
5. **Context attribution, not suppression**: annotate the likely driver (logged supplement, hard training,
   travel/altitude, luteal phase) rather than hiding the flag; cycle-adjust temperature (the one benign cause
   that mimics fever).
6. **Surface separately** from the score (a badge beside it), never folded in — Oura keeps Symptom Radar
   separate from Readiness for exactly this reason.

**Honesty bar**: even the best peer-reviewed models sit at 60–70% specificity / low PPV (4–10% in independent
validation). Ship as "a signal worth attention," never a diagnosis, and never advertise an unvalidated
lead-time/accuracy number. Much of the naive apparent signal is *behavior change after learning you're sick*
(Cleary 2022, AUC 0.75→0.63 on pre-result-only data).

This flag **directly sharpens the daily stress score too**: a concordant temp+RR+RHR rise is the one context
where "this sustained load is likely illness/overreach, not a benign supplement" can be said honestly.

---

## 5. Future work — predictive analytics (P0/P1/P2)

The ML review's blunt conclusion: **for a per-user, on-device, privacy-first, inspectable-math app, the
honest state of the art is transparent statistical anomaly detection on a personal baseline — not deep
learning.** Every vendor "predictive readiness/recovery" score is, on inspection, a **nowcast** (a reweighted
baseline-deviation of last night's data relabeled as prediction). The only genuinely forward-looking task
with replicated evidence — illness 1–3 days out — is best solved by change-point/CuSum methods that run
trivially on-device.

Evidence that simple beats complex *on this kind of noisy, small-N, per-user series*: M4 Competition (best
pure-ML method less accurate than the worst statistical one); Makridakis 2018; DLinear (a one-layer linear
model beat every Transformer, AAAI 2023). Per-user deep forecasting is data-starved (one user ≈ hundreds–2k
nightly points) and there is **no** evidence it beats a tuned EWMA on nightly HRV.

**Roadmap:**
- **P0 — dual-timescale trend + change-point (largely DONE via §3).** Fast EWMA (~3–5 d) vs slow baseline
  (~28–60 d) of lnRMSSD + RHR, a CV band, and a change-point flag for sustained shifts. `DailyStressEngine`'s
  dual baselines + `ChronicShift` already are this; a formal online change-point (CuSum) on the short-vs-long
  gap would complete it and give an explicit "your baseline shifted on ~date" event.
- **P1 — personal-baseline early-illness detector (= §4).** Multivariate deviation on RHR + RR + skin temp,
  NightSignal/CuSum-style. The one task with real multi-day lead time; transparent methods *are* the SOTA.
- **P2 — optional cold-start prior** (a tiny shipped population prior to bridge the first ~14 days). The one
  place a shared/pretrained component is justified; keep it small and swap to the personal baseline ASAP.

**Explicitly do NOT build**: per-user LSTM/transformer next-day forecasters (data-starved, unfalsifiable,
contradicts inspectable-math), foundation-model "digital twins" (need cloud scale, break privacy-first), or
confident overtraining/illness *classifier* verdicts (science equivocal / PPV too low). This aligns with the
app's inspectable-math philosophy — the constraint is a feature.

---

## 6. Unsettled science (flagged honestly)
- Prospective illness specificity is mediocre (~60–70%); false positives from alcohol/training/travel/luteal.
- CV-of-lnRMSSD direction with fatigue is U-shaped and context-dependent — keep it a *secondary* signal.
- The SWC 0.5 multiplier and EWMA-vs-simple-mean are conventions, not validated optima.
- Nearly all cited thresholds come from morning-supine athlete recordings, not nocturnal wrist averages.
- Saturation vs parasympathetic-overtraining (both ↓HRV/↓RHR) can't be separated without external context.

---

## 7. Sources
See inline links. Anchors: Buchheit 2014 `10.3389/fphys.2014.00073`; Plews 2013 PMID 23852425; Altini 2021
Sensors `10.3390/s21237932`; Hopkins 2000 (SWC); TemPredict PMC8891385; Snyder PMC9020268; DETECT *Nat Med*
2021; Alavi 2022 *Nat Med* PMC8799466; Quer 2020 DETECT (RHR-alone AUC 0.52); Makridakis 2018; M4 2020;
Zeng 2023 DLinear (arXiv:2205.13504).
