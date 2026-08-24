# 2026-08-24 — cloud mirror 23h stale; request_sync push produced no sync; app open didn't catch up

Captured from a live incident (all times ET). The noop-cloud mirror's last replication was
2026-08-23 18:30Z (~14:30 ET). On 2026-08-24 the server's `request_sync` sent an APNs push at ~13:05
(`devices:1, pushed:1, expectFreshWithinSec:90`). The mirror did **not** refresh within 90s. VK then
opened the app and pulled-to-refresh repeatedly; the mirror finally refreshed at **13:23**, via the
liters page-replication lane (`lastWriteSource: replication`), ~23h stale at that point.

The build on the phone was **216** (`noop-phone-build`, branch `build/216-ecg-gate`), which carries
an *uncommitted* instrumented push handler (delivery-receipt breadcrumbs + a background-task
assertion) — but nothing surfaced those breadcrumbs in any UI, so "did iOS deliver the push at all"
was unanswerable without a debugger.

| | Meaning |
|---|---|
| **CONFIRMED** | re-derived from current code; still true |
| **UNVERIFIED** | consistent with the evidence but not provable remotely |

## A. Why the app open didn't upload immediately — CONFIRMED (fixed this sweep)

The 20h "zero-touch" catch-up (`CloudSyncModel.autoSyncIfDue`) is wired **only** to
`RootTabView`'s launch `.task` (and `RootView`'s on macOS). A SwiftUI `.task` runs once per view
lifetime — i.e. on a **cold launch only**. A suspended app brought back to the foreground re-runs
the `scenePhase == .active` handler, which kicks the **strap** sync (`requestSync(.foreground)`,
#267) but never the cloud lane. So a warm re-open left the mirror exactly as stale as iOS kept the
process alive — and `bluetooth-central` keeps this process alive for days.

**Fix:** `StrandiOSApp`'s `.active` handler now also runs `backgroundSyncIfDue` (the existing
4h-gated entry point — same gate the BGAppRefresh path uses, so rapid re-opens are a UserDefaults
read and nothing else). Overlap with the cold-launch `autoSyncIfDue` is `CloudSyncGate`'s job.

## B. Pull-to-refresh never touches the cloud lane — CONFIRMED (not changed)

On build 216, pull-to-refresh on 11 of 12 screens is a bare `repo.refresh()` — a local-DB re-read
(see `docs/bugs/2026-08-03` sweep on the unmerged `claude/elastic-ramanujan-17b750`, commits
`876a7827`+`142f9e0c`, which makes the gesture kick the **strap** offload). Even that fix
deliberately does not kick the cloud upload from the gesture, and that decision stands: the upload
has its own cadence/gates, and fix A above now covers the "I opened the app, freshen the mirror"
expectation. VK's repeated swipes today acquired nothing by construction.

## C. Why the push produced no sync — UNVERIFIED (two candidates, now distinguishable)

The handler chain itself is sound and CONFIRMED wired: `remote-notification` background mode
(project.yml), `aps-environment: development` (local pin in the phone build, matching the server's
sandbox APNs default), server sends an **alert-type, priority-10** push with `content-available: 1`
riding along (silent-only pushes were already measured undeliverable — see noop-cloud
`src/push/apns.ts`), and `didReceiveRemoteNotification` runs `syncFromPush` → the full gated sync.

What cannot be told apart from the server side (APNs answers 200 for tokens it hasn't marked
Unregistered — `request_sync` says so itself):

1. **iOS never delivered the push.** A force-quit app is never woken for `content-available`; Low
   Power Mode and Background App Refresh both suppress it; the banner half additionally needs
   notification authorization.
2. **The push arrived but the sync bailed silently** — most plausibly on a wedged
   `CloudSyncGate`: a sync that died without releasing (suspension mid-push; the liters FFI call's
   network waits are not bounded by URLSession timeouts) parked `inFlight` forever in a
   long-lived process, and every later attempt returned "Sync already in progress" with no record.

**Fixes:** the build-216 instrumentation is now committed (receipt breadcrumb records
delivery + the measured background budget + `sync ran=`/`EXPIRED` outcomes; the assertion keeps the
export+upload alive past the bare push-wake budget); `CloudSyncGate` reclaims holds older than
30 min (`staleHoldS`) and breadcrumbs the reclaim; and the Test Centre's replication card now shows
all three breadcrumbs (registration / receipt / gate reclaim), so the next silent failure is
attributable from the phone in one glance.

## D. No staleness indicator, no manual affordance visibility — CONFIRMED (fixed this sweep)

The Data Sources card showed only `lastPersistedStatus` — the last **attempt's** outcome line,
success or failure alike — so a run of failures (or no runs at all) read as an aging "Last sync"
line at best. It now also shows "Cloud mirror current as of …" from a new
`cloudsync.lastUploadConfirmedAt` stamp, written only when a sync verifiably left the server
holding this device's current content (bytes shipped, liters "in sync", or content token matched
the last delivered upload). "Sync now" on the same card remains the manual affordance.

## What is NOT verified

- Nothing here is push-validated on hardware yet: the next `request_sync` against a build carrying
  this sweep is the validation, and the receipt breadcrumb is the evidence either way.
- The 13:23 recovery's exact trigger (cold-launch `autoSyncIfDue` vs a manual Sync-now tap) is
  unknowable in hindsight — build 216 recorded no trigger provenance. The status line still doesn't
  record *which entry point* ran a sync; acceptable, since the breadcrumbs now bound the question.
- Android: no twin — the CLOUD_SYNC lane is fork-only Apple code (`CLOUD_SYNC` compilation
  condition; a default build contains none of it), so the parity contract is not in play.
