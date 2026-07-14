# Readiness / HRV-readiness (if distinct from Charge) — science

```json
{
  "summary": "## Readiness / HRV-readiness \u2014 how it *should* be computed (science/medical lens)\n\n**Physiological anchor.** The dominant readiness signal is *vagally-mediated* (parasympathetic) heart-rate variability, best captured by **RMSSD** \u2014 \"the primary time-domain measure used to estimate the vagally mediated changes reflected in HRV\" (Shaffer & Ginsberg 2017). Higher night-time RMSSD \u2248 parasympathetic (recovered) dominance; an acute drop \u2248 sympathetic/stress load, incomplete recovery, illness, alcohol, or accumulated fatigue. RMSSD is right-skewed, so it should be **log-transformed (lnRMSSD)** before any SD-based math; this is standard in the athlete-monitoring literature (Buchheit 2014) and is what WHOOP uses.\n\n**The core method is a *personal baseline-band*, not an absolute number.** Between-individual RMSSD variation is enormous (healthy-adult short-term norm \u2248 42 \u00b1 15 ms, range 19\u201375 ms; Shaffer & Ginsberg 2017), so population norms are useless for readiness. The established recipe, converged on by the sports-science literature and by HRV4Training/Oura/WHOOP alike:\n\n- **Baseline (chronic signal):** a **7-day rolling average of lnRMSSD**, which suppresses the large night-to-night noise of single readings (Plews 2013; Buchheit 2014).\n- **Normal range (personal band):** built from a trailing **~60-day** window of the individual's own values; the band is **baseline \u00b1 the \"smallest worthwhile change\" (SWC \u2248 0.5 \u00d7 the between-day standard deviation)** (athletedata/Altini synthesis of Plews & Buchheit). Interpretation flips from \"higher is better\" to **\"normal is better\"** \u2014 readiness is high when today's value (or the 7-day baseline) sits *within or above* the band, and degrades as it falls *below* it (Altini, \"What's your normal range for HRV\").\n- **Coefficient of variation (CV = SD/mean of the rolling window)** is the second-order signal: a **rising CV alongside a falling baseline is the classic early warning of maladaptation/accumulated fatigue**, and can flag trouble even while the baseline is still nominally in-range (Altini; Plews & Buchheit, \"variation in variability\").\n\n**Combining acute vs chronic.** *Acute* = last night's lnRMSSD (and RHR) relative to the personal band. *Chronic* = the trajectory of the 7-day baseline vs the 60-day mean, plus the CV. Readiness should be driven primarily by HRV **and resting heart rate together** (RHR drifting ~3\u20137 bpm above baseline is one of the most robust, hard-to-fake recovery signals; Oura), with skin-temperature and respiratory-rate elevations as illness/strain modifiers. This is exactly how the vendors structure it: **WHOOP Recovery** = a 0\u2013100% score from HRV(lnRMSSD, measured during sleep) + RHR + respiratory rate + sleep + skin temp + SpO\u2082, banded green 67\u2013100 / yellow 34\u201366 / red 0\u201333; **Oura Readiness** exposes contributors including **HRV Balance (recent ~14-day HRV vs 3-month baseline)**, RHR vs long-term average, body-temperature deviation vs a 2-month baseline, and a single-night Recovery Index.\n\n**Readiness vs Recovery \u2014 the key distinction.** They are *not* synonyms, though marketed loosely. **\"Recovery\" (WHOOP-style, \u2248 NOOP's \"Charge\")** is a physiology-only snapshot: normalized autonomic state (HRV+RHR+resp+sleep) expressed as a % of the person's own range \u2014 it answers *\"how recovered is my nervous system right now?\"* **\"Readiness\" (Oura/Garmin-style)** is a *broader composite* that folds the recovery signal together with **load and context** \u2014 training-load balance, sleep debt/regularity, circadian/temperature, previous-day activity \u2014 answering *\"given my recovery **and** my recent load and sleep, how prepared am I to take on strain today?\"* Garmin makes this explicit: Training Readiness combines sleep score, **HRV status**, recovery time, acute load, sleep history, and stress history into one morning figure. So if NOOP already has a recovery-type \"Charge,\" an *HRV-readiness* score should differ by **scope**, not restate the same inputs: either (a) surface the pure HRV-baseline-band trend as its own high-resolution contributor, or (b) be the load-aware composite (Charge + training-load balance + sleep debt + temperature). Building two near-identical 0\u2013100 scores is the failure mode to avoid.\n\n**Evidence for morning-readiness guidance.** Acting on the daily HRV band has RCT support. The original **Kiviniemi 2007** trial guided daily running intensity off morning HRV vs a **reference value of the 10-day mean \u2212 1 SD**: HRV in-range \u2192 high intensity; below-range or falling 2 days \u2192 easy/rest \u2014 and the HRV-guided group improved more than fixed programming. **Vesterinen 2016** replicated this (\"train hard when HRV is within the normal range, otherwise easy\"), improving 3-km performance where predefined training did not. A **meta-analysis of 6 RCTs / 195 participants** found HRV-guided training beat traditional programming for VO\u2082max (**ES 0.402, 95% CI 0.273\u20130.531** vs 0.215), *but* the effect is **small and highly heterogeneous (I\u00b2 \u2248 94%)** \u2014 honest framing matters. On *when to measure*: consistent **morning supine ~5-min** readings are the classic protocol (Buchheit 2014), but **nocturnal sleep-derived HRV** (the wearable approach) is at least as sensitive and in one head-to-head was **more responsive to training-induced change** than morning readings (Malik/Nummela group, 2024) \u2014 which validates NOOP's on-device sleep-window approach.",
  "howComputed": "RECOMMENDED TARGET METHOD for a NOOP HRV-readiness score (concrete, implementable):\n\n1) NIGHTLY INPUTS from the strap:\n   - vagal HRV = RMSSD from R-R intervals over a stable sleep window (WHOOP measures during slow-wave/deep sleep; equivalently, the most stationary nocturnal segment). Compute x = ln(RMSSD) \u2014 RMSSD is right-skewed, so all SD math is on the ln scale.\n   - RHR = lowest sustained nocturnal heart rate.\n   - (modifiers) respiratory rate; wrist/skin-temperature deviation.\n\n2) CHRONIC BASELINE: baseline_t = 7-day rolling average of ln(RMSSD) (simple or exponentially-weighted). This is the load-bearing smoother \u2014 single-night lnRMSSD is noisy (within-person CV often ~5\u201310%+), so day-to-day decisions must ride the 7-day line, not one night (Plews 2013; Buchheit 2014).\n\n3) PERSONAL NORMAL BAND: over a trailing ~60-day window of nightly ln(RMSSD), compute the between-day SD. Band = long-run-mean \u00b1 SWC, with SWC \u2248 0.5 \u00d7 between-day SD (the \"smallest worthwhile change\"). Readiness is high when today's value / the 7-day baseline is WITHIN or ABOVE the band; it degrades as it drops below. Ethos: \"normal is good,\" not \"higher is always better\" (Altini).\n\n4) SECOND-ORDER SIGNAL: CV = SD/mean of the rolling lnRMSSD window (%). Rising CV + falling baseline = accumulated fatigue/maladaptation; escalate the penalty even if the mean is still marginally in-range (Plews & Buchheit \"variation in variability\").\n\n5) ACUTE vs CHRONIC FUSION into 0\u2013100 (or %): score each input by its signed deviation from its own personal band (z-like), weight HRV and RHR as the two dominant terms (RHR elevated ~3\u20137 bpm above baseline is a strong, hard-to-fake negative; Oura), add temperature/respiratory-rate elevations as illness/strain modifiers, clamp to [0,100]. Expose the contributors individually (Oura-style) and draw the band (HRV4Training-style) so the number is explainable, not a black box.\n\n6) READINESS vs RECOVERY scoping (avoid double-counting): a pure \"Recovery/Charge\" score = steps 1\u20135 physiology only. A distinct \"Readiness\" score = that recovery term PLUS load/context \u2014 acute:chronic training-load balance, sleep debt & regularity, circadian/temperature \u2014 mirroring Garmin Training Readiness (sleep + HRV status + recovery time + acute load + sleep/stress history). Differentiate the two scores by SCOPE, not by re-summing the same inputs.\n\n7) GUIDANCE MAPPING (evidence-based, from HRV-guided-training RCTs): in-band \u2192 normal/hard training OK; 1 day below \u2192 proceed, trim volume; \u22652\u20133 days below (or Kiviniemi's \"below 10-day mean \u2212 1 SD\" / 2-day downward trend) \u2192 swap intensity for easy/rest; sustained below-band with rising CV \u2192 genuine recovery days.\n\nMEASUREMENT: consistent nightly sleep-window (device approach) is valid and was more sensitive than morning readings in a 2024 head-to-head; if ever done manually, use morning-supine ~5-min, same time, before stimulants (Buchheit 2014).",
  "sources": [
    {
      "url": "https://support.ouraring.com/hc/en-us/articles/360057791533-Readiness-Contributors",
      "supports": "Oura Readiness contributor definitions and baseline windows: HRV Balance = recent ~14-day HRV vs 3-month average (recent days weighted more); RHR vs long-term average; Body Temperature vs ~2-month nighttime baseline; single-night Recovery Index; Activity/Sleep Balance windows."
    },
    {
      "url": "https://ouraring.com/blog/readiness-score/",
      "supports": "Oura Readiness is a 0-100 composite of seven personalized contributors (sleep, sleep balance, activity, RHR, HRV balance, body temperature, recovery index); score bands 85+/70-84/<70; contributors are personal to the individual."
    },
    {
      "url": "https://developer.whoop.com/docs/whoop-101/",
      "supports": "WHOOP Recovery is a 0-100% score computed on waking from HRV, RHR, respiratory rate, sleep, skin temperature and SpO2; color bands green 67-100%, yellow 34-66%, red 0-33%."
    },
    {
      "url": "https://www.whoop.com/us/en/thelocker/heart-rate-variability-hrv/",
      "supports": "WHOOP computes HRV using RMSSD (log-transformed, lnRMSSD) measured automatically during deep/slow-wave sleep for a stable nightly reading."
    },
    {
      "url": "https://marcoaltini.substack.com/p/whats-your-normal-range-for-heart",
      "supports": "Personal HRV normal range built from the past ~60 days of the individual's own data; 'normal is better' rather than 'higher is better'; readings compared to this individual frame of reference (example daily 55 below a 63-84 band)."
    },
    {
      "url": "https://www.athletedata.health/guides/hrv-guided-training",
      "supports": "Concrete baseline-band recipe: normal range = 7-day rolling average +/- smallest worthwhile change (~0.5 x between-day SD); CV = SD/mean of daily readings (example 6/60 = 10%); rising CV + dropping baseline = early fatigue warning; staged decision rules; morning same-time measurement."
    },
    {
      "url": "https://pubmed.ncbi.nlm.nih.gov/17849143/",
      "supports": "Kiviniemi 2007 RCT: original HRV-guided training; morning HRV vs a reference value of the 10-day mean minus 1 SD; HRV increase/unchanged -> high intensity, significant decrease (or 2-day downward trend) -> low intensity/rest; HRV-guided group improved more than predefined training (26 males)."
    },
    {
      "url": "https://pmc.ncbi.nlm.nih.gov/articles/PMC7663087/",
      "supports": "Meta-analysis (6 RCTs, 195 participants): HRV-guided training effect on VO2max ES 0.402 (95% CI 0.273-0.531) vs traditional 0.215; decision logic HRV in-range->high intensity, decreased->moderate/rest; 4-week baseline; high heterogeneity I2 ~ 94%."
    },
    {
      "url": "https://www.firstbeat.com/en/blog/smarter-endurance-training-heart-rate-variability-guidance/",
      "supports": "Vesterinen 2016 method: high/moderate intensity programmed when daily HRV (RMSSD) is within the individual's normal range, otherwise low intensity; 3000 m performance improved in HRV-guided group but not predefined-training group."
    },
    {
      "url": "https://pubmed.ncbi.nlm.nih.gov/23852425/",
      "supports": "Plews 2013 (Sports Medicine): recommends weekly (7-day) rolling averages of vagal HRV (lnRMSSD) over isolated measures to handle day-to-day noise; individual HRV 'fingerprint'; HRV saturation in elite athletes."
    },
    {
      "url": "https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2014.00073/full",
      "supports": "Buchheit 2014 canonical methods review: lnRMSSD as the most reliable day-to-day index (morning supine ~5-min or ultra-short), 7-day rolling averages, coefficient of variation, and smallest-worthwhile-change thresholds for interpreting meaningful change; value of combining HR and HRV."
    },
    {
      "url": "https://pmc.ncbi.nlm.nih.gov/articles/PMC5624990/",
      "supports": "Shaffer & Ginsberg 2017: RMSSD reflects vagally-mediated (parasympathetic) cardiac control and is the preferred short-term time-domain index; healthy-adult short-term norm 42 +/- 15 ms (range 19-75 ms); large inter-individual variation; recording-length guidance."
    },
    {
      "url": "https://pmc.ncbi.nlm.nih.gov/articles/PMC11541970/",
      "supports": "Morning vs nocturnal HR/HRV to intensified training (24 recreational runners, 2024): morning and nocturnal correlate at baseline (r 0.42-0.91) but diverge under load; nocturnal (sleep) lnRMSSD segments were more responsive to training-induced change, validating device sleep-window measurement."
    },
    {
      "url": "https://the5krunner.com/garmin-features/training/training-readiness/",
      "supports": "Garmin Training Readiness is a composite combining sleep score, HRV status, recovery time, acute training load, sleep history and stress history - illustrating readiness = recovery signal + load/context, distinct from a physiology-only recovery score; needs ~3-4 weeks to calibrate."
    },
    {
      "url": "https://www.researchgate.net/publication/221863314",
      "supports": "Plews & Buchheit 'variation in variability' case comparison: the coefficient of variation of the 7-day rolling lnRMSSD average as an index of adaptation; rising variability signals poor coping/maladaptation."
    }
  ],
  "unknowns": [
    "Exact weighting/formula by which Oura, WHOOP, and Garmin/Firstbeat combine contributors into the final Readiness/Recovery number is proprietary and unpublished - none disclose the coefficients, the normalization curves, or how the 0-100 (or %) mapping is shaped.",
    "WHOOP does not publicly state the precise SD/percentile normalization behind its Recovery percentage, nor the exact sleep segment/window and artifact-rejection used for the nightly RMSSD.",
    "The exact SD multiplier for the normal band is not standardized: the literature/apps use roughly 0.5 x between-day SD (SWC) but some implementations use ~0.5-1.0 SD, and HRV4Training does not publish its precise multiplier; NOOP would need to pick and validate its own.",
    "Whether a composite readiness score actually outperforms simply trending the raw 7-day lnRMSSD baseline for guiding decisions is not established; added contributors (temperature, respiratory rate, activity balance) improve face validity but their independent predictive value in a consumer readiness score is largely unvalidated.",
    "Efficacy evidence for HRV-guided decisions is drawn from training-performance RCTs in (mostly) fit adults with a small, highly heterogeneous pooled effect (ES ~0.4, I2 ~94%); it does not validate day-to-day 'readiness' guidance for general wellness, illness prediction, or non-athletes.",
    "Optimal baseline/normal-range window lengths (7-day baseline, ~60-day normal range) are conventions from Altini/Plews, not the output of a formal optimization; the best windows likely vary by person and data density and are not settled.",
    "Sex/menstrual-cycle, age, alcohol, altitude, and acute-illness effects on the band are known confounders but there is no published consensus formula for adjusting a readiness score for them."
  ],
  "actionabilityNotes": "To be ACTIONABLE without overclaiming: (1) Show the trend, not just a number - plot the 7-day lnRMSSD baseline with the shaded personal normal band (HRV4Training pattern) and expose contributors individually (Oura pattern) so a low score is explainable (e.g. 'RHR +6 bpm and HRV below band'). (2) Drive guidance off the BAND and the 7-day trend, never a single night: in-band -> normal load OK; 1 night below -> proceed, ease volume; >=2-3 nights below or rising CV with falling baseline -> reduce intensity / add recovery. (3) Require a warm-up period: bands are meaningless until ~2-4 weeks (Garmin says 3-4) and stabilize with ~60 days - gate the score or widen uncertainty early on. (4) Separate Recovery(=Charge, physiology-only) from Readiness(=+load/sleep-debt/context) by SCOPE so the two scores aren't redundant. MEDICAL CAUTIONS a clinician would insist on: this is a NON-CLINICAL wellness approximation - RMSSD-based readiness is not a diagnostic and must never imply detection of arrhythmia, infection, or disease. Population norms (42+/-15 ms) must NOT be shown as targets; only the person's own baseline is meaningful given huge inter-individual spread. Confounders (alcohol, late meals, poor sleep, alcohol, illness, menstrual phase, altitude, measurement position/time) move HRV and should be surfaced as caveats, not silently scored as 'fatigue.' A persistently abnormal RHR/HRV/temperature pattern warrants 'consider seeing a clinician,' not a NOOP interpretation. Do not fabricate a band or a score from insufficient nights - honest 'not enough data yet' beats a false readiness reading.",
  "confidence": "high"
}
```

# Readiness / HRV-readiness (if distinct from Charge) — competitive

```json
{
  "summary": "## Readiness vs Recovery \u2014 how Oura and WHOOP actually do it (competitive lens)\n\nThe single biggest divergence is **architectural**: Oura folds recovery, sleep, and load-balance into **one** morning \"Readiness\" number; WHOOP splits the day into **two axes** \u2014 a purer autonomic **Recovery %** (\"how recovered am I\") and a separate **Strain Target** (\"how much can I do today\"). Garmin's **Training Readiness** sits between them.\n\n### Oura \u2014 \"Readiness\" (there is no separate daily \"Recovery\")\nOura publishes a **named-contributor** model. The Readiness Score (0\u2013100) is built from up to **nine contributors**: Resting Heart Rate, HRV Balance, Body Temperature, Recovery Index, Sleep, Sleep Balance, Sleep Regularity, Previous-Day Activity, and Activity Balance. Each contributor is defined as a comparison of a recent value to a **personal long-term baseline** with specific windows:\n- **Resting HR**: lowest HR of the previous night vs long-term average.\n- **HRV Balance**: mean overnight HRV over the last **14 days** vs the **3-month** average, recent days weighted more.\n- **Body Temperature**: previous night's nocturnal temperature deviation vs long-term nighttime average; \"significantly above or below your normal range will lower your score\" (illness signal).\n- **Recovery Index**: how long after HR reaches its nightly nadir the RHR stabilizes; needs \u2265~6 h post-nadir for an optimal reading.\n- **Sleep / Sleep Balance / Sleep Regularity**: last-24 h sleep vs baseline; 2-week sleep vs age-based need; consistency of bed/wake times over 2 weeks.\n- **Activity contributors**: prior-day activity/inactivity and 14-day vs 2-month activity load.\n\nBands: **85\u2013100 Optimal, 70\u201384 Good, 60\u201369 Fair, 0\u201359 Pay Attention**. Baselines take **up to 2 weeks** to learn; menstrual cycle and pregnancy are accounted for. Framing: Readiness \"reflects how balanced your recovery and activity are.\" Oura's long-term recovery analog is **Resilience** (a **14-day** rolling balance of daytime stress vs restorative/sleep recovery that reuses HRV Balance, Recovery Index, and RHR) \u2014 closer to Garmin's chronic view than to a daily recovery score. **Resolution: one score per day** (computed on wake), plus separate live Daytime Stress.\n\n### WHOOP \u2014 \"Recovery %\" + \"Strain Target\" (two-axis)\nWHOOP Recovery is \"a daily measure of how prepared your body is to perform,\" a **0\u2013100%** score from four primary inputs \u2014 **HRV (the dominant driver), Resting HR, Respiratory Rate, and Sleep (need-met/performance)** \u2014 plus (4.0+) **skin temperature and blood oxygen**. Mechanistic specifics WHOOP does publish:\n- HRV and RHR are taken **during sleep, weighted toward slow-wave sleep (SWS)**; HRV is reported as **RMSSD (ms)**. This deliberately samples the most stable autonomic state.\n- **Respiratory rate** was added specifically because it \"contained information about next-day performance not already captured by HRV, RHR, and Sleep.\"\n- Every metric is normalized to the **individual's personal baseline**, not population norms.\n- Bands: **Green 67\u2013100%** (primed for strain), **Yellow 34\u201366%** (maintaining), **Red 0\u201333%** (rest).\n\nThe \"what should I do today\" question is answered by a **separate** output \u2014 **Strain Coach / Strain Target** \u2014 which reads the morning Recovery and prescribes an **optimal Strain range** on the 0\u201321 (Borg-based, non-linear) Strain scale, updating live as strain accrues; higher recovery \u2192 higher target, and the user can bias it toward overreaching or restorative. **Resolution: Recovery recomputed each morning after main sleep; Strain Target continuous through the day.**\n\n### Garmin (Firstbeat) \u2014 \"Training Readiness\" for reference\nA **1\u2013100** score continuously recomputed from **six enumerated factors**: last night's Sleep score, Recovery Time (countdown), HRV Status (vs personal baseline), Acute Load (~7-day), Sleep History (3 nights), Stress History (3 days). Levels: **Prime 95\u2013100, High 75\u201394, Moderate 50\u201374, Low 25\u201349, Poor 1\u201324**. It is the only one of the three that puts **explicit training load** *inside* the readiness number.\n\n### Where they diverge\n1. **Construct isolation.** WHOOP Recovery is a comparatively **pure autonomic-recovery** signal (HRV-led) and deliberately keeps sleep-quantity and training-load as *other* axes. Oura Readiness **blends** autonomic recovery with sleep quantity/regularity and activity balance, so a low score doesn't localize cleanly to under-recovery vs merely short sleep. Garmin blends recovery with acute load and a recovery-time countdown.\n2. **Load awareness.** Neither Oura Readiness nor WHOOP Recovery ingests training load directly (WHOOP handles load on the Strain side; Oura via Activity Balance only loosely). Garmin bakes acute/chronic load in.\n3. **Illness signal.** Oura leans hardest on **skin/body temperature** deviation as an early-illness flag inside the score; WHOOP includes skin temp/SpO2 but weights HRV; Garmin uses neither temperature nor SpO2 in Training Readiness.\n4. **Transparency vs actionability.** Oura is most **explainable** (named contributors with published baseline windows) but its aggregation is opaque and arguably conflates constructs. WHOOP is least transparent on inputs' weighting but most **actionable** (recovery \u2192 explicit strain prescription).\n\n### Which is more defensible \u2014 and the NOOP implication\nFor a **recovery/HRV-readiness** signal specifically, **WHOOP's approach is the more defensible target**: it isolates one physiological construct (parasympathetic recovery), measures HRV where it is most reliable (RMSSD over stable SWS), personalizes to a rolling individual baseline, and \u2014 critically \u2014 **decouples \"how recovered\" from \"how much should I do,\"** so each number means one thing and the pair is directly actionable. Oura's genuine advantages worth borrowing are (a) **temperature-driven illness detection** and (b) **contributor-level transparency** with explicit baseline windows. The most defensible NOOP design is therefore a **two-axis, WHOOP-style model** \u2014 a personalized recovery/HRV-readiness score (HRV-dominant on stable sleep segments + RHR + respiratory rate + sleep-need-met + skin-temp illness guard, all vs a personal rolling baseline) presented **separately** from a strain/load target \u2014 while adopting Oura-style **named contributors with disclosed baseline windows** so the score is explainable and honestly non-clinical. Avoid Oura's single blended 0\u2013100 that mixes recovery, sleep, and activity into one opaque number.",
  "howComputed": "CONCRETE, published mechanisms per vendor (weights/aggregation functions are NOT published by any of the three \u2014 see unknowns).\n\nOURA READINESS (0\u2013100, once per day at wake): score = opaque aggregation of up to 9 contributor sub-scores, each a deviation of a recent value from a personal baseline. Inputs \u2192 transforms: (1) Resting HR = min overnight HR vs long-term avg; (2) HRV Balance = mean overnight HRV(14d, recent-weighted) vs 3-month avg; (3) Body Temperature = prior-night nocturnal temp deviation vs long-term nighttime avg (large deviation drops score sharply); (4) Recovery Index = hours of sleep after nightly HR nadir until RHR stabilizes (\u2265~6h post-nadir = optimal); (5) Sleep = last-24h total vs baseline; (6) Sleep Balance = 14d sleep vs age need; (7) Sleep Regularity = bed/wake consistency over 14d; (8) Previous-Day Activity vs long-term avg; (9) Activity Balance = 14d vs ~2-month load. Baselines learned over ~2 weeks; cycle/pregnancy adjusted. Bands 85/70/60. Long-term analog = Resilience (14-day balance of daytime stress vs restorative+sleep recovery, reusing HRV Balance/Recovery Index/RHR).\n\nWHOOP RECOVERY (0\u2013100%, recomputed each morning after main sleep): proprietary (patented, ML) combination of HRV (dominant), RHR, respiratory rate, and sleep performance (+skin temp, SpO2 on 4.0). HRV = RMSSD in ms, taken during sleep weighted to slow-wave sleep; RHR similarly weighted to SWS. Each metric normalized to the individual's personal baseline (rolling; ~30d per third-party sources, not officially confirmed). Respiratory rate included because it added next-day-performance signal beyond HRV/RHR/sleep. Bands: Green 67\u2013100, Yellow 34\u201366, Red 0\u201333. The prescriptive layer is SEPARATE: Strain Coach maps today's Recovery \u2192 an optimal target on the 0\u201321 non-linear (Borg) Strain scale, updated live.\n\nGARMIN TRAINING READINESS (1\u2013100, continuous; Firstbeat): combination of six factors \u2014 last-night Sleep score, Recovery Time countdown, HRV Status vs baseline, Acute Load (~7d), Sleep History (3 nights), Stress History (3 days). Levels Prime/High/Moderate/Low/Poor (95/75/50/25). Uniquely ingests training load directly.",
  "sources": [
    {
      "url": "https://support.ouraring.com/hc/en-us/articles/360057791533-Readiness-Contributors",
      "supports": "Oura Readiness contributor list (9 contributors) and each contributor's input, transform, and personal-baseline windows (RHR vs long-term avg; HRV Balance 14d vs 3-month; temperature deviation; Recovery Index; sleep/activity balance windows)"
    },
    {
      "url": "https://support.ouraring.com/hc/en-us/articles/360025589793-An-Introduction-to-Your-Readiness-Score",
      "supports": "Oura Readiness definition, 0-100 bands (85/70/60), inputs, ~2-week baseline learning, and readiness-vs-activity framing"
    },
    {
      "url": "https://ouraring.com/blog/readiness-score/",
      "supports": "Oura framing of Readiness as one of three daily scores, temperature significantly lowering score, and that there is no separate daily Recovery score (Readiness feeds Resilience)"
    },
    {
      "url": "https://support.ouraring.com/hc/en-us/articles/25358829055251-Resilience",
      "supports": "Oura Resilience = 14-day balance of daytime stress vs restorative/sleep recovery; reuses HRV Balance, Recovery Index, RHR; serves as Oura's long-term recovery analog"
    },
    {
      "url": "https://developer.whoop.com/docs/whoop-101/",
      "supports": "WHOOP Recovery defined as 0-100% daily readiness-to-perform from HRV/RHR/respiratory rate/sleep; green 67-100 / yellow 34-66 / red 0-33; Strain 0-21 non-linear Borg scale"
    },
    {
      "url": "https://www.whoop.com/us/en/thelocker/how-does-whoop-recovery-work-101/",
      "supports": "WHOOP Recovery inputs including skin temperature and blood oxygen, HRV as most influential, personalization to individual baseline not population norms, color-band meanings"
    },
    {
      "url": "https://www.whoop.com/us/en/thelocker/podcast-84-recovery-update/",
      "supports": "WHOOP added respiratory rate to Recovery because it carried next-day-performance information not already captured by HRV, RHR, and sleep"
    },
    {
      "url": "https://support.whoop.com/hc/en-us/articles/360023313394-Strain-Coach",
      "supports": "WHOOP Strain Coach/Strain Target recommends how much strain to take on today based on the morning Recovery score (separate 'how much can I do today' axis)"
    },
    {
      "url": "https://www.whoop.com/us/en/thelocker/strain-coach/",
      "supports": "Strain Target gives a daily optimal Strain range keyed to Recovery, updating live; higher recovery -> higher target; user can bias toward overreaching or restorative"
    },
    {
      "url": "https://www.whoop.com/us/en/thelocker/heart-rate-variability-training/",
      "supports": "WHOOP measures HRV during sleep (weighted to slow-wave sleep) and reports RMSSD as the recovery HRV metric"
    },
    {
      "url": "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8160717/",
      "supports": "Independent validation of WHOOP wrist PPG heart rate and HRV (RMSSD) against ECG during sleep \u2014 supports the physiological grounding of the HRV input"
    },
    {
      "url": "https://www8.garmin.com/manuals/webhelp/GUID-C001C335-A8EC-4A41-AB0E-BAC434259F92/EN-US/GUID-C21BE0C8-A08E-4DA1-B6C6-2E0E2DDDB372.html",
      "supports": "Garmin Training Readiness definition, six input factors (sleep score, recovery time, HRV status, acute load, sleep history, stress history), and 1-100 levels Prime/High/Moderate/Low/Poor"
    },
    {
      "url": "https://www.garmin.com/en-US/garmin-technology/running-science/physiological-measurements/training-readiness/",
      "supports": "Garmin official positioning of Training Readiness as a continuously updated readiness-to-train score (Firstbeat), corroborating the six-factor inputs"
    }
  ],
  "unknowns": [
    "Oura does NOT publish the weighting or aggregation function that combines the 9 Readiness contributors into the 0-100 score, nor the per-contributor scoring curves (how a given deviation maps to points). Body temperature is stated to lower the score 'significantly' but no numeric weight or override rule is published.",
    "WHOOP's Recovery formula is explicitly proprietary and patented: the exact weights and ML transform combining HRV, RHR, respiratory rate, and sleep (and skin temp/SpO2) are undisclosed. HRV being the 'dominant' driver is stated qualitatively, not quantified.",
    "WHOOP's official personal-baseline window is not published; the commonly cited ~30-day rolling baseline comes from third-party sources, not WHOOP documentation. Whether the score uses raw RMSSD or an ln-transformed RMSSD internally is not published.",
    "The precise definition of WHOOP's HRV sampling window ('during sleep, weighted to slow-wave sleep' / 'last SWS period') is described in WHOOP educational material but the exact algorithm (which epochs, how weighted) is not formally specified.",
    "Garmin/Firstbeat do not publish how the six Training Readiness factors are weighted or combined, nor the exact acute/chronic load math feeding it.",
    "None of the three publishes validation specifically of the composite readiness/recovery score's predictive accuracy for next-day performance; published validation (e.g., WHOOP PPG study) covers the underlying HR/HRV sensor accuracy, not the derived score.",
    "Oura's exact Recovery Index thresholds and the exact recency-weighting inside HRV Balance (how much extra weight recent days get) are described directionally, not numerically."
  ],
  "confidence": "high",
  "actionabilityNotes": "The competitive read directly sets NOOP's target methodology. Adopt WHOOP's two-axis separation: (1) a daily recovery/HRV-readiness score that isolates autonomic recovery \u2014 HRV-dominant (RMSSD) sampled over the most stable sleep segments, plus RHR, respiratory rate, sleep-need-met, and a skin-temperature illness guard \u2014 all scored as deviations from a PERSONAL rolling baseline; and (2) a separate strain/load-target output for 'how much today', rather than Oura's single blended 0-100 that mixes recovery, sleep, and activity. Borrow Oura's transparency: surface named contributors each with its disclosed baseline window and show the top 1-2 drivers behind today's score, plus a 3-4 band scale. Because NOOP is explicitly non-clinical, present every component as an approximation vs the user's own baseline: a temperature deviation is an 'off-baseline' flag, never a fever/illness diagnosis; low HRV is 'below your recent norm', not autonomic dysfunction. Require a personal-baseline warm-up (Oura uses ~2 weeks; WHOOP personalizes from ~30 days) and clearly label the score as provisional until enough nights exist. A medical view would caution: wrist/finger PPG HRV is validated at the SENSOR level during sleep but the composite score's predictive validity is unpublished for all vendors, so NOOP should frame the score as a self-relative wellness trend, avoid absolute/normative claims, and never imply the number diagnoses or rules out illness, overtraining, or cardiovascular risk."
}
```

# Readiness / HRV-readiness (if distinct from Charge) — audit

```json
{
  "howNoopComputes": "NOOP has THREE distinct engines under this lens; only the first is the shipped, default-visible \"Readiness\". None of them is the Charge/recovery 0-100 score (that is RecoveryScorer).\n\n=== (1) ReadinessEngine \u2014 the shipped \"Readiness\" (Today/Liquid/Coupled cards). CATEGORICAL, not a number. ===\n`ReadinessEngine.evaluate(days:[DailyMetric], today:String?)` (ReadinessEngine.swift:79) is a pure, deterministic, DB-free function. Result is memoized (AnalyticsMemoCache capacity 16) keyed by `today` + an order-independent FNV fingerprint over only (day, avgHrv, restingHr, respRateBpm, strain) (rowsFingerprint, :97).\nINPUTS -> TRANSFORM: sort rows by day; pick `latest` = the row whose `day == today` if `today` given (dashboard passes device local day), else the most-recent row (:122-123); `history` = all rows strictly before latest.day (:130). Then build up to 5 independent SIGNALS:\n - HRV: `zSignal` (:218) over `latest.avgHrv` vs baseline `history.suffix(baselineWindow=30).compactMap{avgHrv}`, need >= minBaseline=7. z=(v-mean)/SD, higherIsBetter=true. Bands (:229): z>=0.5 good; -0.5..<0.5 neutral; -1.0..<-0.5 watch; else (< -1.0) bad. Uses RAW ms (no log).\n - Resting-HR: same zSignal, 30-night baseline, higherIsBetter=false (:149).\n - Respiratory rate: only if latest.respRateBpm in SleepStager.respPlausibleRangeBpm (8.0...25.0) and baseline mean also in band (:167-170); z vs 30-night mean with WIDER thresholds \u2014 z>=2.0 bad, z>=1.5 watch, else no signal (never emits good/neutral) (:172-180).\n - Training-stress-balance (ACWR): needs strainSeries.count>=minChronic=14; acute=mean(last acuteWindow=7 strain), chronic=mean(last chronicWindow=28), ratio=acute/chronic (:185-194). Bands (acwrSignal :240): <0.8 watch(\"ramping down\"); 0.8..<1.3 good(\"sweet spot\"); 1.3..<1.5 watch(\"building fast\"); >=1.5 bad(\"spiking\").\n - Monotony (Foster): over last 7 strain days (need >=4), mono=mean/SD; mono>=2.0 -> watch (:197-206).\nSYNTHESIS (`synthesize` :275): count bad/watch/good; recoveryDown = any of {hrv,rhr,respRate} flagged bad; loadHigh = acwr bad. Rules: bad.count>=2 OR (recoveryDown&&loadHigh) -> `.rundown`; else recoveryDown||loadHigh||bad>=1 -> `.strained`; else good.count>=2 && watch empty -> `.primed`; else `.balanced`. No history/no signals -> `.insufficient`.\nOUTPUT: `Readiness{ level: Level(primed|balanced|strained|rundown|insufficient), headline, summary, signals:[Signal(key,label,evidence,detail,flag)], acwr:Double?, monotony:Double? }`. There is NO 0-100 readiness number anywhere \u2014 the only \"score\" is the 5-way Level enum plus per-signal 4-way flags (good/neutral/watch/bad). Stats helpers are ReadinessEngine.mean and sampleSD (n-1) (:304-313).\n\n=== (2) HRVReadiness \u2014 opt-in EXPERIMENTAL \"HRV readiness (Plews/Altini)\" tier. Test Centre only, feeds nothing. ===\n`HRVReadiness.evaluate(avgHrv:[Double?]) -> HRVReadinessResult?` (HRVReadiness.swift:93). Drop nils + out-of-range via Baselines.hrvCfg (5..250 ms); honesty gate: nil (\"calibrating\") if valid.count < minNights=14 (:101). Work in LOG domain: ell = ln(max(v,1.0)) (:104). baseline7 = RecoveryForecaster.mean(last rollWindow=7 ell) (:107). Personal-normal window longWin = 60 if valid>=60 else longWindowFallback=30 (:110); longMean = mean(last longWin ell); longSD = RecoveryForecaster.sampleSD(longEll) floored at longSDFloor=1e-9 (:117). SWC band = longMean \u00b1 swcK(0.5)\u00b7longSD (:120-122). Tier: baseline7>normalHigh -> primed; >=normalLow -> normal; else suppressed (:126). overreachingWatch (informational only, never changes tier): OLS slope of a rolling-7 CV series over last cvTrendWindow=28 nights < 0 AND baseline7 < longMean (:138-149). OUTPUT: tier + baseline7Ms/normalLowMs/normalHighMs (exp back to ms) + overreachingWatch. Surfaced only in TestCentreView.hrvReadinessReadout behind PuffinExperiment.hrvReadinessKey=\"noopHrvReadiness\" (default OFF, PuffinExperiment.swift:82-87); explicitly n=1, not validated; changes NOTHING downstream.\n\n=== (3) WatchRecovery \u2014 actually a CHARGE (0-100) path, NOT Readiness. Included for contrast. ===\n`WatchRecovery.compute(todaySDNN:, todayRHR:, sdnnHistory:, rhrHistory:)` (WatchRecovery.swift:60) builds HRV(SDNN) + RHR baselines through the PRODUCTION `Baselines.foldHistory` (Winsorized EWMA + cold-start gating) and feeds the SAME `RecoveryScorer.recovery(...)` the strap uses, renormalizing to HRV+RHR (drops resp/sleep/skin-temp) -> recovery in [0,100] + ScoreConfidence. Honesty gate: nil recovery + .calibrating unless todaySDNN present, hrvBase.usable, and sdnnHistory.count>=minBaselineNights=7. This proves the codebase HAS a rigorous baseline pipeline \u2014 which the shipped Readiness engine (1) deliberately does NOT use.",
  "inputs": [
    "ReadinessEngine (shipped Readiness): [DailyMetric] rows, each carrying day (YYYY-MM-DD), avgHrv (nightly RMSSD, ms, Double?), restingHr (bpm, Int?), respRateBpm (mean sleeping resp, breaths/min, Double?), strain (daily strain, Double?); plus optional `today` anchor string (device local logical day, Repository.logicalDayKey)",
    "Per-signal windows are trailing slices of the SORTED daily history: HRV/RHR/resp baseline = history.suffix(30) nights (min 7); ACWR = strain suffix(7) acute / suffix(28) chronic (min 14 chronic points); monotony = strain suffix(7) (min 4)",
    "HRVReadiness (experimental): a single [Double?] nightly RMSSD series (DailyMetric.avgHrv mapped, oldest->newest); no other inputs; needs >=14 in-range (5..250 ms) nights",
    "WatchRecovery (Charge path): todaySDNN (ms), todayRHR (bpm), and ordered nightly sdnnHistory[]/rhrHistory[] arrays from Apple Watch daily aggregates",
    "All inputs are NIGHTLY/DAILY aggregates already computed upstream (one HRV/RHR/resp/strain value per day). Neither readiness engine touches raw RR intervals, epochs, or intraday HR."
  ],
  "baselineApproach": "ReadinessEngine (the shipped Readiness) uses a NAIVE cross-day baseline that is deliberately NOT the app's production Baselines pipeline: for each of HRV/RHR/resp it takes an UNWEIGHTED trailing-window arithmetic mean + sample SD (n-1) over `history.suffix(30)` nights strictly before `latest.day`, requiring only minBaseline=7 valid points, then a plain z=(value-mean)/SD (RHR/resp orientation flipped). NO EWMA/recency weighting, NO Winsorization or outlier rejection (except the resp plausibility band 8-25 bpm), NO cold-start damping, NO staleness penalty, NO log transform for HRV (raw ms). Missing nights are simply compactMap'd away, so a 30-calendar-day window with gaps silently shrinks and a weeks-old baseline can still anchor today with no penalty. Cold-start = the hard `insufficient` cliff (needs history + >=7 baseline nights, or >=14 strain points for ACWR); there is no graduated confidence on the Readiness card. This contrasts sharply with the SAME repo's Baselines.foldHistory (Winsorized EWMA + cold-start .calibrating/.provisional/.trusted/.stale states, minNightsSeed=4, hard bounds hrv 5..250 / restingHR 30..120 / resp 4..40) that RecoveryScorer and WatchRecovery/Charge use. HRVReadiness (experimental) is more principled: LOG-domain (ln RMSSD), a short 7-night rolling baseline compared against a 60-night (fallback 30) personal-normal band of \u00b10.5 SD (smallest-worthwhile-change), with hard-bound rejection (5..250) \u2014 but still plain arithmetic mean over log values (RecoveryForecaster.mean), no EWMA, no Winsorization. So the two readiness engines even disagree on domain (raw ms vs ln) and on baseline construction.",
  "resolution": "Fully DAILY / one-reading-per-night grain. Both readiness engines consume nightly aggregates (one avgHrv/restingHr/respRateBpm/strain per YYYY-MM-DD) and emit one verdict per day; there is no hourly, epoch, or intraday resolution and no time-of-day component. `latest` is selected by exact YYYY-MM-DD string match to `today` (else most-recent row). On iOS/macOS Today, after midnight rollover before tonight is scored, computeReadiness anchors on `lastScoredRecoveryDay?.day` (carry-over #543, TodayView.swift:913-921) so the card shows the prior night's read rather than vanishing. OUTPUT is heavily QUANTIZED: ReadinessEngine collapses each continuous z into 4 flags (good/neutral/watch/bad at z cut-points 0.5/-0.5/-1.0; resp at 1.5/2.0) and the whole day into a 5-way Level enum \u2014 a z of -1.01 and -5.0 both read \"bad\"; there is no continuous 0-100 readiness score, no percentile, no severity within a band. HRVReadiness quantizes to 3 tiers (primed/normal/suppressed) off a \u00b10.5 SD log band. ACWR needs >=14 chronic strain points to appear at all; monotony needs >=4 of the last 7. Underlying stats: sample SD (n-1) throughout; ReadinessEngine.sampleSD returns nil (<2 pts) and RecoveryForecaster.sampleSD returns 0 (<2 pts).",
  "gaps": [
    "NOOP's shipped 'Readiness' is CATEGORICAL only \u2014 a 5-way Level (primed/balanced/strained/rundown/insufficient) plus 4-way per-signal flags. There is no continuous 0-100 readiness score, no percentile, no hysteresis. Hard z band edges (0.5 SD wide) make sub-band changes invisible and let the Level flip night-to-night on a single noisy input. A rigorous target would output a smoothed continuous score with confidence bands.",
    "The shipped ReadinessEngine baseline is naive and inconsistent with the app's own rigorous pipeline: unweighted trailing 30-night mean + sample SD, min 7 points, NO EWMA (recent nights not up-weighted), NO Winsorization/outlier rejection, NO cold-start damping, NO staleness penalty. One bad-decode HRV night in the window skews the mean AND inflates the SD (desensitizing the z). Meanwhile WatchRecovery/Charge in the SAME repo uses Winsorized EWMA + cold-start states \u2014 the two systems compute different baselines off the same avgHrv series and can visibly disagree.",
    "HRV z in the shipped engine uses RAW ms, but RMSSD is right-skewed; a raw z overstates high-side and understates low-side (suppression) deviations. The app's own HRVReadiness engine correctly uses ln RMSSD \u2014 so the default users see is the less-correct one, and the two engines disagree on domain.",
    "Signals are independent flags combined by COUNTING, not a weighted physiological composite. The informative coupled case (HRV down AND RHR up together) only surfaces via the coarse rundown rule, not a weighted score. No respiration/skin-temp/sleep-performance terms feed Readiness at all (they exist in Charge/RecoveryScorer), so Readiness ignores signals the platform already computes.",
    "minBaseline=7 lets the z denominator (SD) be estimated from as few as 7 nights, an unstable variance, yet the Readiness card exposes NO confidence/width (unlike Charge's ScoreConfidence). Users can't tell a solidly-grounded 'strained' from a thinly-grounded one.",
    "ACWR uses uncoupled rolling-average acute(7)/chronic(28) simple means \u2014 the biased rolling-average ACWR, not the exponentially-weighted EWMA-ACWR (Williams/Menaspa) shown to reduce bias. Monotony over only 7 days (min 4 points) is a noisy Foster estimate. Neither is personalized beyond the raw ratio.",
    "The MORE rigorous engine (HRVReadiness: log-domain, 7-night rolling vs \u00b10.5 SD SWC personal-normal band, overreaching-watch CV-slope) is opt-in, Test-Centre-only, feeds NO downstream gate, and is explicitly n=1 unvalidated. The default-visible Readiness is the naive one; the good ideas (log domain, SWC band, robust short rolling baseline, trend slope) are quarantined behind a default-off flag.",
    "No recency/staleness requirement in ReadinessEngine: nils are compactMap'd out, so gaps silently shrink the 30-night window and a weeks-old baseline can anchor today's z with no penalty. Baselines.foldHistory HAS a `.stale` status (staleDays); the Readiness path ignores it.",
    "Severity is lost: within a band all magnitudes read identically (z -1.01 == -5.0 == 'bad'). No trend/slope of HRV or RHR feeds the shipped Readiness verdict \u2014 only HRVReadiness computes a slope, and only as an informational flag, not in the tier.",
    "Resp signal only ever emits watch/bad (never good/neutral) and is gated to 8-25 bpm on both value and baseline mean, so a genuinely-low resp night can't contribute a positive signal; asymmetric by construction.",
    "Cross-engine incoherence for the user: Charge (0-100, EWMA baseline), Readiness (categorical, naive mean baseline, raw-ms z), and experimental HRV-readiness (3-tier, log SWC band) can all point different directions on the same night with no reconciliation surfaced."
  ],
  "files": [
    "/Users/vk/VKDEV/NOOP/noop/Packages/StrandAnalytics/Sources/StrandAnalytics/ReadinessEngine.swift:1-315 (full: evaluate:79, evaluateUncached:115, latest/history selection:122-130, zSignal:218-238 with bands:229-234, resp gate:167-182, ACWR acuteWindow=7/chronicWindow=28/minChronic=14:184-194 + acwrSignal:240-261, monotony:197-206, synthesize:275-300, tunables baselineWindow=30/minBaseline=7:69-73, mean/sampleSD:304-313)",
    "/Users/vk/VKDEV/NOOP/noop/Packages/StrandAnalytics/Sources/StrandAnalytics/HRVReadiness.swift:1-157 (full: constants rollWindow=7/longWindow=60/longWindowFallback=30/swcK=0.5/minNights=14/cvTrendWindow=28/longSDFloor=1e-9:64-84, evaluate:93, log domain:104, baseline7:107, SWC band:119-122, tier:124-132, overreachingWatch CV-slope:134-149)",
    "/Users/vk/VKDEV/NOOP/noop/Packages/StrandAnalytics/Sources/StrandAnalytics/WatchRecovery.swift:1-101 (full: minBaselineNights=7:49, compute:60, Baselines.foldHistory HRV+RHR:64-65, RecoveryScorer.recovery reuse:83-91, honesty gate:74-78)",
    "/Users/vk/VKDEV/NOOP/noop/Packages/StrandAnalytics/Sources/StrandAnalytics/RecoveryForecast.swift:83,198-231 (RecoveryForecaster.mean returns 0 for empty:198, sampleSD n-1 returns 0 for <2:204, leastSquaresSlope OLS:214)",
    "/Users/vk/VKDEV/NOOP/noop/Packages/StrandAnalytics/Sources/StrandAnalytics/Baselines.swift:19-27,69,98,150-162,171-172,264-374 (MetricCfg minVal/maxVal, hrv 5..250 / resting_hr 30..120 / resp 4..40 / skin_temp 20..42, minNightsSeed=4, usable=provisional||trusted, foldHistory Winsorized-EWMA)",
    "/Users/vk/VKDEV/NOOP/noop/Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStager.swift:1314 (respPlausibleRangeBpm = 8.0...25.0)",
    "/Users/vk/VKDEV/NOOP/noop/Packages/WhoopStore/Sources/WhoopStore/MetricsCache.swift:43-81 (DailyMetric fields: day, avgHrv, restingHr, respRateBpm, strain, recovery, etc.)",
    "/Users/vk/VKDEV/NOOP/noop/Strand/Screens/TodayView.swift:879-933 (readiness accessor + memoization todayInputKey + computeReadiness carry-over anchor #543 :913-921), :698-701 (readinessWord), :1536-1640 (readinessCard/levelWord/flagWord/flagColor)",
    "/Users/vk/VKDEV/NOOP/noop/Strand/Liquid/LiquidTodayView.swift:56,843,900-904 (cachedReadiness, ReadinessEngine.evaluate over repo.days)",
    "/Users/vk/VKDEV/NOOP/noop/Strand/Screens/CoupledView.swift:93-99 (readinessLevel = ReadinessEngine.evaluate(...).level)",
    "/Users/vk/VKDEV/NOOP/noop/Strand/BLE/PuffinExperiment.swift:82-96 (hrvReadinessKey='noopHrvReadiness', default OFF, read-only, changes nothing downstream)",
    "/Users/vk/VKDEV/NOOP/noop/Strand/Screens/TestCentreView.swift:265-317 (hrvReadinessReadout: HRVReadiness.evaluate(avgHrv: repo.days.map{avgHrv}), tier label mapping, calibrating N/minNights readout)"
  ]
}
```

# Readiness / HRV-readiness (if distinct from Charge) — verify

```json
{
  "checkedClaims": [
    {
      "claim": "RMSSD is 'the primary time-domain measure used to estimate the vagally mediated changes reflected in HRV' (Shaffer & Ginsberg 2017).",
      "verdict": "supported",
      "note": "Verbatim match on PMC5624990. Load-bearing physiology anchor is solid."
    },
    {
      "claim": "Healthy-adult short-term RMSSD norm approximately 42 +/- 15 ms, range 19-75 ms (Shaffer & Ginsberg 2017).",
      "verdict": "supported",
      "note": "Confirmed in Table 6 (mean 42, SD 15, range 19-75). Original data is Nunan et al. n=21,438, reproduced in the Shaffer review; attribution acceptable. Used correctly as a 'do NOT use population norms as targets' caution."
    },
    {
      "claim": "Oura HRV Balance = mean overnight HRV over past 14 days vs 3-month average, recent days weighted more.",
      "verdict": "supported",
      "note": "Exact match on Oura Readiness Contributors page: 'past 14 days against your three-month average, with data from the past few days being weighted more.'"
    },
    {
      "claim": "Oura Body Temperature contributor baselines against a ~2-month nighttime average; Recovery Index needs >=6h sleep after HR nadir.",
      "verdict": "supported",
      "note": "Both confirmed verbatim ('past two months'; 'minimum of six hours of sleep after this point')."
    },
    {
      "claim": "Oura Readiness = up to 9 named contributors (RHR, HRV Balance, Body Temp, Recovery Index, Sleep, Sleep Balance, Sleep Regularity, Previous-Day Activity, Activity Balance).",
      "verdict": "supported",
      "note": "All nine confirmed on the support page. COMPETITIVE's contributor model is accurate."
    },
    {
      "claim": "Oura Readiness bands are 85-100 Optimal / 70-84 Good / 60-69 Fair / 0-59 Pay Attention.",
      "verdict": "supported",
      "note": "COMPETITIVE version confirmed exactly on the Oura intro page. NOTE: SCIENCE's rendering as '85+/70-84/<70' is imprecise \u2014 it collapses the bottom two bands. Use COMPETITIVE's four-band scale."
    },
    {
      "claim": "Oura Resilience = 14-day balance of daytime stress vs restorative/sleep recovery, reusing HRV Balance, Recovery Index, and RHR.",
      "verdict": "supported",
      "note": "Confirmed on Oura Resilience page: '14-day average', reuses 'HRV balance, recovery index, and resting heart rate.'"
    },
    {
      "claim": "WHOOP Recovery = HRV + RHR + respiratory rate + sleep + skin temperature + SpO2, computed on waking; bands green 67-100 / yellow 34-66 / red 0-33.",
      "verdict": "supported",
      "note": "All inputs, the 'computed when you wake up' timing, and the exact band ranges confirmed on WHOOP 101. Strain 0-21 Borg-based/non-linear also confirmed verbatim."
    },
    {
      "claim": "WHOOP measures HRV as RMSSD during sleep weighted to slow-wave/deep sleep.",
      "verdict": "supported",
      "note": "WHOOP-stated in educational material, but note the WHOOP 101 doc itself does NOT mention RMSSD, and the exact epochs/weighting are unpublished. Directionally correct; do not over-specify the algorithm."
    },
    {
      "claim": "WHOOP uses lnRMSSD (log-transformed RMSSD) \u2014 SCIENCE states 'this is standard... and is what WHOOP uses.'",
      "verdict": "proprietary-unknown",
      "note": "KEY CORRECTION and an internal contradiction between the two outputs. lnRMSSD as standard HRV-monitoring practice is well-supported, but WHOOP does not publish that its Recovery score log-transforms, and WHOOP displays HRV to users as raw RMSSD in ms. Only secondary sources (Altini, review articles) assert internal ln-transform. COMPETITIVE correctly lists this as unknown; SCIENCE overstates it as fact."
    },
    {
      "claim": "WHOOP added respiratory rate because it 'contained information about next-day performance not already captured by HRV, RHR, and Sleep.'",
      "verdict": "marketing-or-unverified",
      "note": "Accurately attributed to a WHOOP podcast, but it is a vendor self-claim; the incremental predictive value of respiratory rate in the score has no independent validation. Frame as 'WHOOP states', not established fact."
    },
    {
      "claim": "WHOOP normalizes to a ~30-day personal rolling baseline.",
      "verdict": "proprietary-unknown",
      "note": "COMPETITIVE already flags this as third-party-sourced, not official WHOOP documentation. Affirmed \u2014 keep the hedge."
    },
    {
      "claim": "Garmin Training Readiness combines sleep score, recovery time, HRV status, acute load, sleep history (3 nights), stress history (3 days); levels Prime 95-100 / High 75-94 / Moderate 50-74 / Low 25-49 / Poor 1-24.",
      "verdict": "supported",
      "note": "Confirmed verbatim against Garmin's OFFICIAL manual (factors and all five band cutoffs). A secondary (the5krunner) fetch gave conflicting labels/Body Battery, but that was a fetch artifact; the official source vindicates the claim."
    },
    {
      "claim": "Kiviniemi 2007: reference value = 10-day mean - 1 SD; 26 males; HRV-guided group improved more than predefined training.",
      "verdict": "supported",
      "note": "Reference value '[10-day mean-SD]', N=26 males (8/9/9), and the 2-day-downtrend rule confirmed. NUANCE the synthesis must honor: the HRV-guided advantage was in running performance/max velocity (significant); VO2peak showed NO significant between-group difference. 'Improved more' is true for performance, not VO2max."
    },
    {
      "claim": "Meta-analysis (6 RCTs, 195 participants): HRV-guided VO2max ES 0.402 (95% CI 0.273-0.531) vs traditional 0.215; I^2 ~94%.",
      "verdict": "supported",
      "note": "Every figure confirmed exactly on PMC7663087 (I^2 = 94.24%). Keep the honest framing: small, highly heterogeneous effect, athlete-performance context only."
    },
    {
      "claim": "2024 study: nocturnal (sleep) lnRMSSD was more responsive to training-induced change than morning readings; 24 recreational runners; morning-nocturnal r = 0.42-0.91.",
      "verdict": "supported",
      "note": "Confirmed on PMC11541970: 24 runners, r 0.42-0.91 at baseline, overload-period changes correlated with performance 'only in nocturnal segments.' Small single study \u2014 validates the device sleep-window approach but should be presented as suggestive, not definitive."
    },
    {
      "claim": "'RHR drifting ~3-7 bpm above baseline is one of the most robust, hard-to-fake recovery signals (Oura)' \u2014 used to justify weighting RHR heavily.",
      "verdict": "marketing-or-unverified",
      "note": "Direction is well-supported (RHR elevation as a recovery/illness signal). But the specific '3-7 bpm' figure attributed to Oura is not verifiable; Oura-adjacent published figures are ~5-10 bpm, and Oura reports ~8.5 bpm average when members tag fever/flu. Drop or soften the precise number."
    },
    {
      "claim": "The exact weighting / aggregation / normalization curves that map inputs to the final Oura, WHOOP, and Garmin 0-100 (or %) scores are proprietary and unpublished.",
      "verdict": "proprietary-unknown",
      "note": "Affirmed \u2014 both outputs state this honestly and repeatedly. This is the single most important guardrail: no specific vendor weight, coefficient, or normalization shape may be presented as known."
    },
    {
      "claim": "Personal normal band = baseline +/- SWC (~0.5 x between-day SD); 7-day rolling lnRMSSD baseline; ~60-day normal-range window.",
      "verdict": "supported",
      "note": "Legitimate sports-science convention traceable to Plews/Buchheit/Altini. But the specific 0.5-SD multiplier and the 7-day/60-day windows are conventions, not optimized values (the athletedata source is a commercial guide). Both outputs correctly hedge this in unknowns; keep it as 'convention to validate on NOOP data,' not settled fact."
    }
  ],
  "overallReliability": "high",
  "correctionsForSynthesis": "The research is unusually well-sourced: I spot-checked every load-bearing external number against its primary source and nearly all matched exactly (RMSSD vagal claim and 42+/-15 ms norm; Oura 9 contributors with 14-day/3-month/2-month windows and 4-band scale; Oura Resilience 14-day; WHOOP inputs and 67/34/0 bands; Garmin's exact six factors and Prime/High/Moderate/Low/Poor cutoffs per the OFFICIAL manual; Kiviniemi's 10-day-mean-minus-1-SD rule and N=26; the meta-analysis ES 0.402 / CI 0.273-0.531 / I^2 94%; the 2024 nocturnal-vs-morning study). Reliability is high. Honor these specific corrections:\n\n1) DO NOT state WHOOP uses lnRMSSD as fact. This is the one genuine overclaim (SCIENCE asserts it; COMPETITIVE correctly lists it as unknown). Correct framing: 'log-transforming RMSSD (lnRMSSD) is standard practice in HRV monitoring and NOOP should do it; WHOOP publicly reports HRV as raw RMSSD in ms and does not disclose whether its Recovery score transforms internally.'\n\n2) Drop or soften the specific 'RHR +3-7 bpm (Oura)' figure. Keep the direction (RHR elevation is a robust, hard-to-fake recovery/illness signal) but say 'several bpm above baseline'; note Oura-adjacent numbers are ~5-10 bpm and ~8.5 bpm average for fever/flu tags. The '3-7 bpm' precise figure is not attributable to Oura.\n\n3) Frame WHOOP's respiratory-rate rationale ('added because it carried next-day-performance information beyond HRV/RHR/sleep') as a WHOOP claim, not validated fact. No vendor publishes validation of any composite readiness/recovery score's predictive accuracy \u2014 only underlying sensor accuracy is independently validated.\n\n4) Keep the proprietary-formula guardrail front and center: never present any specific weight, coefficient, normalization curve, or 0-100 mapping shape for Oura/WHOOP/Garmin as known \u2014 all are unpublished. WHOOP's 'weighted to slow-wave sleep' is WHOOP-stated; do not over-specify epochs/weighting.\n\n5) Use the precise four-band Oura scale (85-100 / 70-84 / 60-69 / 0-59), not SCIENCE's collapsed '85+/70-84/<70'.\n\n6) Kiviniemi nuance: the HRV-guided advantage was in running performance/max velocity (significant); VO2peak was NOT significantly different between groups. State 'improved more' for performance, not VO2max. Keep HRV-guided-training evidence honestly framed as a small, highly heterogeneous effect in fit adults for athletic performance \u2014 it does NOT validate day-to-day readiness guidance for general wellness, illness prediction, or non-athletes.\n\n7) Treat the SWC multiplier (~0.5 x SD) and the 7-day baseline / ~60-day normal-range windows as conventions (Plews/Buchheit/Altini) to validate on NOOP's own data, not as optimized or settled values. The athletedata.health recipe is a commercial guide; the underlying concepts trace to legitimate primary literature.\n\n8) Retain the core, well-supported architectural finding: Readiness (load-aware composite; Oura/Garmin) should differ from Recovery/Charge (physiology-only; WHOOP) by SCOPE, not by re-summing the same inputs \u2014 this rests on accurately verified vendor facts and is the safest design guidance. Present every component as a self-relative, explicitly non-clinical approximation vs the user's own baseline."
}
```

