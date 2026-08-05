# 2026-08-03 — pull-to-refresh acquired nothing on every screen but Today

Captured from a live misdiagnosis: a day's data looked stale, the universal "go get the latest"
gesture was pulled repeatedly on Sleep / Workouts / Metric detail, each pull spun, redrew, and
reported success — and **the strap was never contacted**. Hours went into hunting a phantom sync or
decode fault before the gesture itself turned out to be the liar.

| | Meaning |
|---|---|
| **CONFIRMED** | re-derived from current code; still true |
| **FIXED** | landed; see the commit/lines named |
| **OPEN** | real and unfixed |
| **NOT VALIDATED ON HARDWARE** | compiles and the pure tests pass, which per `CLAUDE.md` proves nothing about BLE behaviour |

---

## 1. The defect — a success-reporting no-op

### 1.1 What every screen did — **CONFIRMED · FIXED**

Twelve call sites wired the gesture as `ScreenScaffold(onRefresh: { await repo.refresh() })`:

```
Strand/Screens/TodayView.swift:1260      Strand/Screens/SleepView.swift:130
Strand/Screens/WorkoutsView.swift:139    Strand/Screens/MetricExplorerView.swift:253
Strand/Screens/TrendsView.swift:238      Strand/Screens/HealthView.swift:32
Strand/Screens/AppleHealthView.swift:196 Strand/Screens/DataSourcesView.swift:97
Strand/Screens/XiaomiBandView.swift:108  StrandiOS/App/RootTabView.swift:369
Strand/Screens/HydrationView.swift:52  (local reload)  Strand/Screens/LabBookView.swift:56  (local load)
```

`Repository.refresh(days:)` (`Strand/Data/Repository.swift:681`) is **purely a local-DB re-read** — it
bumps `refreshGen`, then runs a series of `store.dailyMetrics` / `unionSleepSessions` / `unionMetricSeries`
queries against on-device SQLite. It never calls `BLEManager.syncNow()` (strap history offload) and never
calls `CloudSyncModel.syncNow(repo:)`. **Nothing in the gesture's path can produce a row that did not
already exist.**

This is worse than a gesture that does nothing. `.refreshable` renders a spinner and then a completion,
so the interaction is indistinguishable from a successful fetch. On a stale day it **actively reinforces
the false belief that the displayed values are current** — the exact failure mode the 2026-07-15 sweep's
B2 (a 21-hour-old battery reading rendered identically to a live one) already flagged in another surface.

### 1.2 Why it hid for so long — **CONFIRMED**

The correct pattern was already in the tree, twice, which is what made the gap invisible:

- **`LiquidTodayView.handlePull`** (`Strand/Liquid/LiquidTodayView.swift:421-424`, #334) does
  `ble.syncNow()` **then** `await repo.refresh()` — a hand-rolled pull gesture, not `.refreshable`, so it
  shares no code with the scaffold.
- **Android Today** (`android/…/ui/TodayScreen.kt:1092-1101`) does the same via
  `todayPullToSyncEnabled(...)` + `viewModel.syncNow()`.

So the *default* iOS screen behaved correctly, the changelog claim was accurate and narrow — 9.0.1: "Pull
to sync on **Today** (#334)" — and every *other* screen presented a visually identical gesture with none
of the behaviour. No doc over-claimed; the UI did.

---

## 2. The fix — one mechanism at the scaffold, not twelve call-site edits

**FIXED** (`Strand/Screens/ScreenScaffold.swift`, pinned by `StrandTests/PullToRefreshTests.swift`).

`PullToRefresh.run(strapSyncKick:refresh:)` (`ScreenScaffold.swift:189`) is the shared composition: **kick
the strap offload, then run the screen's local re-read.** `RefreshableIfNeeded` (`:161`) — the modifier
that already gated `.refreshable` on a non-nil hook — now routes every pull through it. **No call site
changed**, so no screen can opt out by forgetting, and a future `ScreenScaffold(onRefresh:)` screen
inherits the behaviour.

The kick is an **environment closure** (`\.strapSyncKick`, `:203`), injected once per app root as
`{ model.ble.syncNow() }`:

- `Strand/App/StrandApp.swift:54` (macOS)
- `StrandiOS/App/StrandiOSApp.swift:125` (iOS)

**Why a closure and not `@EnvironmentObject var ble: BLEManager`:** the scaffold does not need to *observe*
BLE state, and observing it would re-render every scaffold screen on connect/discovery churn — the exact
hazard `LiquidTodayView.swift:23-26` documents for its own `ble` dependency (observe `BLEManager`, never
`AppModel`, because `AppModel` publishes `bpm` on the ~1 Hz HR tick). The nil default also keeps previews
and any host without a strap context working, instead of trapping on a missing environment object.

### 2.1 What the kick is gated by — **CONFIRMED (by reading, not by strap)**

`BLEManager.syncNow()` (`Strand/BLE/BLEManager.swift:3585`) already owns every guard, so the scaffold adds
none of its own:

- `guard state.connected, state.bonded` → logs "Sync now: no strap connected — ignored."
- `if backfilling` → logs "Sync now: a sync is already in progress." (so back-to-back pulls cannot stack
  offloads)
- then `requestSync(.manual)`, which re-applies the connected/bonded/not-backfilling gate and the
  `BackfillPolicy` floor. `.manual` bypasses the 15-minute periodic floor **by design**
  (`Strand/BLE/BackfillPolicy.swift:54`) — the same path the Health screen's "Sync now" button uses.

### 2.2 Deliberate non-changes

- **No fake spinner delay when there is no strap.** A disconnected pull stays a plain local re-read. The
  existing affordances — `SyncingHistoryNote` ("Syncing strap history… N chunks pulled",
  `ScreenScaffold.swift:240`), `LiquidSyncStatusRow` / `LiquidBackfillProgressRow`, and the "History
  synced N ago" line (`relativeAgo`, `:259`) — are what disclose progress and staleness. Padding the
  spinner to make a no-op *feel* like work would re-create the original lie in a new shape.
- **Cloud sync is NOT kicked.** `CloudSyncModel.syncNow(repo:)` has its own cadence and gates
  (`autoSyncIfDue`, a 20 h/4 h floor, a background lane). Tying an outbound upload of the whole DB to a
  browsing gesture would be strictly worse than the bug being fixed — see the 2026-07-15 sweep §D1 for
  what that lane already costs when it runs at the wrong moment.
- **macOS is inert.** `.refreshable` surfaces no affordance on macOS (`ScreenScaffold.swift:10-16`), so the
  injection there is dead weight rather than a behaviour change — deliberately kept for symmetry so the
  two roots don't drift. See §5.1.

### 2.3 A consequence worth stating plainly — **ACCEPTED TRADE-OFF**

Because the mechanism lives in the scaffold, a pull on a screen whose data does **not** come from the
strap (Hydration, Lab Book) now also kicks the offload. That is intentional — "pull = acquire the latest"
is the gesture's meaning, and the strap offload is the only acquisition NOOP has — but it is not free: an
offload holds the link ~60 s and, on a WHOOP 4.0, blocks the realtime-HR keep-alive re-arm
(`guard !backfilling`, #160). The bound is `syncNow`'s own `backfilling` guard: repeated pulls during a
running offload are refused with a log line, so the cost is one offload, not one per pull.

---

## 3. Android parity — **no twin defect**

Checked, not assumed. `pulltorefresh` appears in exactly one Android file
(`android/app/src/main/java/com/noop/ui/TodayScreen.kt`), and that gesture already routes to
`viewModel.syncNow()` behind `todayPullToSyncEnabled(connected, bonded, backfilling)` —
itself a thin wrapper over `WhoopBleClient.canRequestSync` (`android/…/ui/TodayProvenance.kt:137`), pinned
by `TodayExplainabilityTest`. **No other Android screen has a refresh gesture at all**, so there is no
Kotlin twin to write: the Swift change brings the other Swift screens up to the behaviour Android's single
gesture already had.

---

## 4. Verification, and what is *not* verified

**Proven:**
- `StrandTests/PullToRefreshTests.swift` — the pure composition: the kick fires **before** the local
  re-read (order asserted, not just occurrence), and a nil kick still runs the re-read. Written first and
  **watched fail** (`Cannot find 'PullToRefresh' in scope`) before the implementation existed.
- `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' … test` — passes,
  which also compiles the whole macOS app target.
- `xcodebuild -scheme NOOPiOS -destination 'generic/platform=iOS' … build` — **BUILD SUCCEEDED**.
  (Per `CLAUDE.md`, app-target Swift has no default CI: `swift-packages.yml` does not compile it and
  `app-build.yml` is disabled, so this local build is the only thing that validates it.)

**NOT VALIDATED ON HARDWARE.** No strap was connected. That a pull *reaches* `syncNow()` is proven by
construction and tests; that the resulting offload behaves — that the link is there, the gate passes, and
rows land — is exactly what `CLAUDE.md` says compile-success cannot tell you. **Next session with a strap:
pull on Sleep while connected and confirm the strap-history chip starts and the log shows "Sync now:
manual sync requested by user."**

---

## 5. Open

### 5.1 macOS still has no refresh affordance at all — **OPEN**

`.refreshable` renders nothing on macOS, so a Mac user has no pull gesture to fix; their only manual
acquisition is the Health screen's "Sync now" button. This change does not regress that — it just doesn't
help it. A Mac-visible refresh control (toolbar item on the scaffold, calling the same
`PullToRefresh.run`) is the natural follow-up and is now a one-line wiring rather than a design question.
Not done here: it is a UI-surface decision, not a bug fix, and this branch stays one concern.

---

## What this should teach the next sweep

**A gesture that reports success is making a claim.** The bug was not that the refresh was weak — it was
that a no-op was dressed in the visual vocabulary of a completed fetch (spinner → dismissal), so the user's
correct instinct ("this data looks stale, let me refresh") was answered with a confident lie and the
investigation was pushed toward the decoder, the strap, and the DB — everywhere except the gesture.

The rule this leaves behind, and the reason the fix lives in `ScreenScaffold` rather than in six call
sites: **pull-to-refresh must ACQUIRE or DISCLOSE.** If it cannot acquire (no strap), the surrounding
affordances must say so — never a silent success. And when a correct implementation already exists in one
place (#334 on Today, and on Android), the question to ask is not "does this work?" but **"which surfaces
share this code, and which merely look like they do?"** Here the answer was one and eleven.
