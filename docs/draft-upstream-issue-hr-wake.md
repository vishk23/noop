# Sleep scoring over-calls WAKE when resting HR is elevated but the wrist is motionless (supplement / fever / alcohol nights)

## Summary

Both stagers (`SleepStager` V1 and the default `SleepStagerV2`) call **wake** primarily off HR and
HR-variability, and the session-detection HR gate (`SleepStager.confirmSleepWithHR`) rejects a still
in-bed run whose median HR sits above the sleep band. Neither path consults **motion** or **posture**
before making that call. On a night whose resting HR is held elevated **without the wearer getting up**
— a supplement protocol, a fever, a hot room, alcohol — the HR-led logic reads hot-but-motionless
sleep as wake. This over-calls WAKE (tanking efficiency, Rest, and the debt ledger) and mis-places
sleep onset, and it has required manual relabeling on multiple confirmed nights.

The motion-aware wake refinement in **#402** (merged 2026-07-13) does not prevent this, for three
compounding reasons detailed below.

## Evidence — two confirmed nights (both manually corrected)

**Night A (2026-07-13).** A supplement protocol held overnight resting HR at ~55–60 (vs a natural
~47–51) and skin temp +0.4…+1.2 °C. The scorer produced **194 min WAKE** across a ~6.4 h in-bed span
(efficiency ≈ 0.50). Minute-level review of the largest WAKE blocks found **zero walking cadence**:
each was a brief turn-over burst (a single-minute posture-variance spike) bracketed by minutes of
complete stillness (per-minute posture variance < 0.05, no step ticks), recurring on a ~90-min rhythm
consistent with hot-but-atonic REM being scored as wake. Correct WAKE was ~67 min.

**Night B (2026-07-14, PDT).** Onset was scored **1:41 AM vs a sensor truth of ~1:29** (wrist still
from 1:29:00, HR at 50 by 1:31), and a **44-min solid WAKE block 1:41–2:27** was emitted where motion
shows stillness with occasional turn-overs and HR 55–65. Sleep end (7:32:38) was correct.

The discriminating pattern, in both nights:
- **Sleeping:** per-minute posture variance < 0.01–0.05 with **zero** walk ticks; HR flat 50–65.
- **Genuinely awake / out of bed:** sustained walking cadence (walk ticks > 0 held for minutes, e.g.
  35–53 steps/min) **or** sustained high posture variance **with** an HR jump (79–100 bpm, 46–109
  steps/min).

Elevated-but-**flat** HR with a motionless wrist is not in the "awake" column.

## Why #402 does not prevent this

1. **Default-OFF.** The refinement ships behind `PuffinExperiment.motionAwareWakeEnabled`, default off.
   A wearer on a supplement protocol gets no protection unless they know to toggle an Experimental flag.
2. **Wrong layer.** It is a **post-pass over an already-staged hypnogram** — it only reclassifies WAKE
   *stage segments inside an already-accepted session* to `light`. It never participates in
   `detectSleep` / `confirmSleepWithHR`, so it cannot fix Night B's late **onset** or protect a session
   the HR gate rejected outright. And on Night A the over-called WAKE is produced by the **stager's own
   HR-led emission model**, upstream of any post-pass tuning.
3. **Requires dense STEP data.** Its density self-gate (`isMotionDense`) needs ≥80% of minutes to carry
   `StepSample` records with an `activityClass`. Its corroboration keys on **walk-class step ticks**.
   When that stream is sparse or the activity class is unattributed, the gate declines and the pass is a
   no-op — exactly on the nights that need it.

## Proposed fix — motion-corroborated wake, on by default, at both layers

The rule: **elevated HR alone is insufficient to call wake.** An epoch or run at the night's quiescent
**motion** floor with **unchanged posture** cannot be scored WAKE on cardiac evidence alone. Corroborate
with the **gravity posture/jerk** signal both stagers already consume (always present), not step ticks.

- **(a) Stage level (default `SleepStagerV2`).** On a **motion-quiescent** epoch (no observed movement;
  peak per-second jerk at/below the night's own quiescent floor × the wake-gate multiplier), clamp the
  cardiac contribution to the AWAKE emission to ≤ 0 — keep any wake-*suppressing* (low, flat HR) evidence,
  discard the wake-*promoting* half. Genuine motion (the movement z-score and the night-relative jerk
  gate, which by construction cannot fire on a quiescent epoch) still drives wake. A still low-HR sleep
  epoch is byte-identical; only a still epoch whose *elevated* HR was about to push it awake is held.

- **(b) Detection level (`confirmSleepWithHR`).** When a run is **deeply motion-quiescent** (≥ ~90% of its
  dense-gravity minutes are posture-stable, per-minute variance < 0.05), widen the HR sleep band from
  ×1.05 to ×1.30, so a supplement-elevated but motionless overnight run is not rejected. The band still
  keeps a **floor**: a run whose median HR is above even the widened band is rejected even when still, so
  genuine all-night in-bed wakefulness is not scored asleep. With no gravity evidence the strict band
  stands (unchanged).

- **(c) Personalised adaptive HR baseline.** Derive the sleep band from the wearer's **recent overnight
  medians** (`adaptiveOvernightHRBaseline`) rather than a fixed day-median, so a sustained supplement /
  fitness era self-calibrates; keep a floor so a wakeful era can't collapse the band.

Out-of-bed detection is untouched: sustained walking cadence and sustained posture change with an HR jump
still break runs and score WAKE.

## Notes

- Swift lands first (`Packages/StrandAnalytics`); the Kotlin analytics twin
  (`com.noop.analytics`) transcription is a deliberate follow-up to preserve the parity contract.
- All thresholds are named constants fixed a-priori from the two reference nights, not fit to labels,
  consistent with the repo's rule for a derived physiological signal.
