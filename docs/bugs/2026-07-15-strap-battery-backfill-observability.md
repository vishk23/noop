# 2026-07-15 — strap death, battery, backfill + observability bug sweep

Captured from a live incident: the strap drained and stopped streaming at **2026-07-14 13:27 PDT**
(last battery reading 10.9% @ 13:00, `charging=0`), a night of data went unscored, and the app was
unable to tell the wearer any of it. Every item below is **evidence-backed from the live device DB
and UserDefaults**, not speculation. Line numbers are from `origin/main` around 2026-07-15.

**The unifying failure:** the app *knows* what is happening — `strapNewestTs`, the backfill frontier,
`backfilling`, SoC, `charging`, `lastSeenAt` — and **surfaces almost none of it**. Hours were spent on
forensics the app had the data to answer instantly.

---

## A. BLE / battery / connection

### A1. Battery % never lands on a 5.0/MG  *(fix identified, ~1 line)*
The only 5/MG battery writer is standard `0x2A19` (`BLEManager.swift:3824-3830`, gated
`!= .whoop4`). Its one-shot `readValue` fires in `didDiscoverCharacteristicsFor`
(`:3467-3471`) — **pre-bond, on an unencrypted link**, which an MG rejects ("Authentication is
insufficient", see `:3476-3479`, `:3562-3567`). The failure hits the error branch (`:3806-3809`)
→ `log(...)` → `return`. **Never retried.**

`:3586` calls `enableLiveNotifications(reason: "post-bond 5/MG")` with a comment claiming it recovers
"battery that failed pre-bond" — **it does not**; it only re-subscribes notify (`:2629-2654`), never
re-issues the read. HR recovers (notify pushes 1 Hz) so the UI says "Live"; battery never does.

Proof it never landed: `LiveState.clearBiometrics()` (`:467-476`) clears `heartRate`/`rr`/
`batterySamples` but **not** `batteryPct` — so `batteryPct == nil` proves `0x2A19` never delivered once.

**Confirmed case (i):** the device log shows `Services discovered: 180D, 180A, 180F` — **180F IS
exposed**, so the characteristic exists and the read is simply never retried post-bond.

**Fix:** re-issue the read for 5/MG at the end of `enableLiveNotifications` (idempotent; reuses the
3 existing call sites). **Fix 1b (more robust):** `FrameRouter.swift:202-205` already receives 5.0
BATTERY_LEVEL events and reads `battery_charging` but **discards `battery_pct`** ("#77: flag only").
The decode exists (`Interpreter.swift:742-753`, u16 @21, `/10`). The #77 stub-100 hazard is
**4.0-only**, so gating on family gives 5/MG a self-healing source refreshing ~every 8 min.

### A2. "Active · Live" lies
`state.connected = true` is set in `didConnect` (`:3080`) **before** `discoverPrimaryServices`
(`:3113`) — true the instant the raw link exists, before any characteristic or byte. `DevicesView.swift:101,351`
shows "Active · Live" on `device.status == .active && live.connected`. Combined with iOS
state-restoration of a **dead** peripheral, the UI claimed "live" for a strap silent 21 hours.
**Fix:** gate the live indication on actual data flow / completed bond, not the raw link object.

### A3. Charging can never display
`LiquidTodayView.swift:1529-1543`: the `bolt.fill` charging indicator is nested **inside**
`if let pct = live.batteryPct`. With pct nil the charging state is structurally unreachable — the
wearer was on the charger and the app could not say so. Also `:1546-1550`: `bolt.slash` is a
**no-data placeholder that reads as "battery dead"** (the wearer read it exactly that way).
**Fix:** render charging independent of pct; split "not connected" from "connected, no reading yet";
accessibility label (`:1558`) should say "no reading yet".

### A4. The app spins forever on a zombie restored peripheral
After iOS state-restoration returns a dead peripheral, the app marks it connected, the handshake never
completes, and it retries the **same dead handle** indefinitely — never cancelling, never re-scanning.
Observed: 40+ minutes of `Backfill: deferred — connect handshake not done yet` every 1–3 min,
persisting after the strap came off the charger. Only a **manual force-quit** recovered it.
**Fix:** bounded stalled-handshake timeout → cancel + re-scan.

### A5. Backfill drain throttled by an arbitrary cap  *(worst practical impact)*
`BLEManager.swift:320`: `static let defaultMaxAutoContinues = 6`. `shouldAutoContinue` (`:349`)
chains sessions back-to-back but every call site (`:1881`, `:1895`, `:1907`) caps at 6 → **7 sessions
per connection**, then falls back to `startBackfillTimer()` (`:2487`) → `backfillIntervalSeconds = 900`
(**15 min** between ~60s sessions).

**Measured on device:** ~29 min of strap data recovered per session; ~18 h backlog ⇒ ~37 sessions ⇒
7 free, then 30 × 15 min = **~7.5 hours** for data the strap streams in minutes.

**The cap is redundant:** `shouldAutoContinue` already has `guard lastTrimAdvanced` (the real anti-spin
guard) plus future-clock checks. **Fix:** scale/bypass the cap while genuinely behind
(`strapNewestTs - frontier > behindGapSeconds` && `lastTrimAdvanced`), keeping a large runaway ceiling.
**Constraint:** each ~60s session blocks the WHOOP4 realtime keep-alive (`guard !backfilling`, see `:1509`
/ #160) — an aggressive drain must not starve live HR on a 4.0.

**Workaround today:** `consecutiveCount` is **per connection** — force-quit + reopen resets it, buying
another ~7 sessions (~3.4 h of data) per cycle.

### A6. Charging flag never lands
Newest live row: `ts 2026-07-15 10:58:06, soc=31.6, charging=0` **while actively charging**. Distinct
from A3 (there pct was nil; here pct exists and charging still reads 0). Unknown whether the 5/MG
emits the bit on this path at all. If it genuinely never reports it, the UI must **infer** charging
(rising SoC) or say nothing — never imply "not charging".

### A7. `lastSeenAt` frozen at pairing → "last seen 18 days ago"
```
my-whoop | added 2026-06-26 12:06:20 | lastSeen 2026-06-26 12:06:20   ← IDENTICAL
oura-api | added 2026-07-10          | lastSeen 2026-07-13            ← updates fine
```
The strap's registry `lastSeenAt` is written once at pairing and **never refreshed**. Only the WHOOP
source is affected.

---

## B. Observability (the wearer's #1 ask)

### B1. Backfill progress is invisible
No way to see that a recovery is running, how far along, or how much remains. Direct quote:
> "All of this stuff, like backfill progress, should be something you can see on the app. It is kind of
> misleading me right now."

The data exists (`strapNewestTs`, frontier/trim cursor, `backfilling`). Surface e.g.
*"Recovering strap history — July 14 14:31, ~15h behind"*. Pure, testable display-state function.

### B2. Battery shown with no staleness marker
A 21-hour-old reading rendered identically to a live one. *"Last seen 21h ago at 11%"* would have
explained the entire incident instantly.

### B3. Rest carries but Charge/Effort don't → a half-broken dashboard
On a dead-strap day the app shows a plausible Rest (carried from the last scored night) beside two
blanks, with **no signal that last night has no data**. Wearer repeatedly asked "are these stale?".
Verified: `2026-07-15` row is entirely NULL; the displayed Rest 72.4 / Charge 46.7 / Effort 25.2 are
**July 14's**, correctly computed. **Fix:** either carry consistently or say "no data for last night".

### B4. Battery is invisible over MCP  *(tool built, not deployed)*
The `battery` table (soc/mv/charging) and the `event` table (**11,457 rows**, `BATTERY_LEVEL` carrying
`battery_pct`) were never exposed. `battery_series`, `device_events`, `imu_coverage` are built + tested
in noop-cloud (branch `tz-upload`), **pending deploy**.

### B5. Burst-capture census + firmware are not in the DB at all
`PuffinRawProbe.finishSession()` writes the R22 census JSON only to a file +
`UserDefaults(noop.probe.rawCensus)`; firmware lives in `UserDefaults(noop.lastFirmware)`, and neither
`device` nor `pairedDevice` has a firmware column. `ingest.ts` drops `settings.json` entirely.
⇒ **The MCP can never see R22 capture health or strap firmware** without a producer-side migration
(e.g. `probeRun(deviceId, ts, version, fw, capturedFrames, censusJSON)`).

---

## C. Alerts

### C1. Battery alerts fire once, then latch — no escalation
Device state: `batteryLowAlerted = true`, `batteryRuntimeAlerted = true` — **both fired, and the strap
still died.** `BatteryAlertPolicy` fires low once per discharge cycle, re-arming only above
`lowRearmAbove = 25`. The runtime alert fires at `runtimeAlertHours = 24` — at the measured 1.65 %/h
that is **39.6% SoC, ~18 h early** — then latches. Net: **~3 hours of silence from 15% to death.**
Both toggles default ON (`BehaviorStore.swift:100-101`), so that is not the explanation.
*Being fixed:* critical 12% alert + bedtime night-guard, each with independent gates.

### C2. Runtime estimate ignores the strap's cutoff
`BatteryEstimator.swift:99`: `remaining = max(0, current) / rate` — time to **0%**. The strap appears
to stop near ~10%, so every estimate overstates runway.

### C3. Rated-path predictive alert is unreachable on a 5.0
`ratedHours = 288` (`BLEManager.swift:1005`) puts the 24 h line at **8.33% SoC — below the cutoff**.
A 5.0 falling back to the rated path therefore gets **no predictive alert, ever**.

---

## D. Cloud sync

### D1. Upload can never complete from the background  *(fix built)*
`CloudSyncClient.swift:34` uses `URLSession.shared` (foreground). Zero `beginBackgroundTask`, zero
background `URLSessionConfiguration`. A push grants ~30 s; deflate-zipping ~400 MB (→ ~81.5 MB) blows
past it and in-flight tasks die on suspension. Device proof: `cloudsync.lastStatus` frozen at
`"Uploaded 81.5 MB · 12:21 PM"` yesterday — and it is written on **every** completion, success or
failure ⇒ nothing has *completed* since.

### D2. Warm resume triggers no sync
`autoSyncIfDue`'s only iOS call site is `RootTabView.swift:133` inside `.task {}`, which does not
re-run on resume. `scenePhase == .active` (`StrandiOSApp.swift:205-223`) does not call CloudSync.

### D3. Server volume ~1 upload from ENOSPC
1008 MiB total, ~461 used, **~547 free**; an ingest needs ~400 MB staged **alongside** the ~460 MB
mirror. `MAX_INGEST_BYTES = 768MB` exceeds the entire volume. Also `/ingest` logs nothing on receipt,
success, or the 400 path — it cannot distinguish "nothing arrived" from "arrived and was rejected".

---

## E. Deep data / MG

### E1. 2140 B optical frames are rejected — no home on this build
Live log: `Backfill: rejected frame[N] 2140B` (repeating). The live DB has **no `ppgWaveformSample`
table** (migrations top out at v28; upstream's `v27-ppg-waveform` / #415 is newer than the installed
build). ⇒ Every 2140 B optical buffer — **the SpO2/BP substrate** — is dropped on the floor.
**Action:** rebuild + install current fork main (which merged v27) to start storing them.

### E2. 1244 B (IMU) frames also logged as rejected — unexplained
IMU decode demonstrably works (`imuActivity` = 2,945 rows), yet 1244 B frames appear in the reject log
during this offload. Needs investigation; do not guess.

### E3. Deep IMU capture is barely running
`imuActivity`: **2,945 rows — all inside ONE 58-minute window across 8 months.** Whatever gates the
deep-buffer capture is almost never on.

---

## F. Scoring (latent)

### F1. Charge silently vanishes after 14 stale nights
`Baselines.swift:40` documents `case stale // usable but no update for > STALE_DAYS nights`, but
`:69` defines `usable = (status == .provisional || status == .trusted)` — **`.stale` excluded** — and
`staleDays = 14`. `RecoveryScorer.swift:417` then does `if !hrvBaselineUsable { return nil }`.
⇒ 14 nights without a valid HRV night ⇒ **Charge silently returns nil**, no explanation surfaced.
The comment and the code disagree; one of them is wrong.
