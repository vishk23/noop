# 2026-08-03 — offload terminal signals: "caught up" and "wedged" were indistinguishable

Captured from a live incident. A WHOOP 5/MG stopped handing over history; every signal the app offered
was **consistent with a perfectly healthy, fully-drained strap**, so the investigation spent hours inside
the sleep stager. **The sleep scoring was never wrong** — it was correct on both nights once the data
landed. What was wrong was that nothing on the surface could distinguish *drained* from *not answering*.

Source: `SESSION_2026-08-03.md` §8c. This document is the code-side record (GitHub issues are disabled on
this fork, so there is no tracker item — see the sweep convention in
`2026-07-15-strap-battery-backfill-observability.md`).

| | Meaning |
|---|---|
| **CONFIRMED** | re-derived from current code; still true |
| **FIXED** | landed; see the commit/lines named |
| **OPEN** | real and unfixed |
| **NOT STRAP-VALIDATED** | compiles + pure tests pass, which per `CLAUDE.md` proves nothing about BLE behaviour |

**All three fixes below landed in one commit** (`cbbea53d`, branch `claude/friendly-kare-c7c1c2`), with
byte-identical Kotlin twins. Line numbers are as of that commit.

---

## 0. The common defect

Each of the three signals reported **what the app concluded** rather than **what it observed**: a
terminator with no record count, a heuristic phrased as a cause, a derived label with no provenance. That
is the whole finding, and it is why the fixes are mostly copy-level with a very high diagnostic payoff.

The same trap appears throughout the previous sweep's "What this sweep should teach the next one": *an
absence of data read as evidence of a specific cause.* Here the absence (`trim=0xFFFFFFFF`, an empty
offload, a null clock signal) was rendered as a diagnosis (caught up / clock lost / clock not latched)
that the observation did not support in either direction.

---

## A1. `trim=0xFFFFFFFF noCursor` carried no record count — **CONFIRMED · FIXED · NOT STRAP-VALIDATED**

On completion the log emitted:

```
[17:46:14] Backfill: reached the end of available history (trim=0xFFFFFFFF) - caught up
[connection] offload trim=0xFFFFFFFF noCursor (strap has no banked history to offload)
```

That second line is the **healthy, fully-drained** state. It is also the exact shape of the morning's
failure, when the command channel was wedged and the strap returned nothing. The only thing separating
them is whether records arrived *before* the terminator — which neither line said.

The information already existed: `BLEManager` knew (`consecutiveAutoContinues > 0` ⇒ caught up after
banking, vs a fresh offload that banked nothing) and the Backfiller's session tally knew the row count.
Neither reached the string.

**FIXED.** Both terminal lines now state the rows banked **this sync**:

- `Backfiller.noCursorLine(rowsPersisted:priorBurstRows:)` (`Strand/Collect/Backfiller.swift:354`),
  emitted at `:666`.
- `ConnectionTrace.noCursorLine(rowsThisSession:priorRowsThisSync:)`
  (`Packages/StrandAnalytics/.../ConnectionReadout.swift:115`) — the `.connection`-tagged twin.

`priorBurstRows` is a new per-connection tally, `BLEManager.burstRowsPersisted` (`:663`), folded in at
each session end (`:1994`) and threaded into `Backfiller.begin` (`:1773`). Its lifecycle deliberately
**mirrors `consecutiveAutoContinues` exactly** — cleared on the caught-up else path (`:2210`) and on
disconnect (`:4557`) — so the two can never disagree about where a burst begins and ends.

It **replaces the `continuedAfterRows` Bool**, which was a real (narrower) defect of its own: a bool can
only say "an earlier session existed", so an auto-continue burst whose earlier sessions *also* banked zero
printed *"the strap handed over its banked history earlier this sync"* — a false statement. A count falls
through to the honest zero-rows line.

Resulting lines:

```
caught up - 0 new records after 41282 this sync
nothing banked this sync - if this repeats, the strap may not be answering
```

The zero-rows strap-log line additionally **stops asserting** "This is a clock/charge state on the strap";
it now names both readings and puts the in-app restart ahead of the charge ritual (see A2).

---

## A2. Empty-offload copy asserted a diagnosis it never measured — **CONFIRMED · FIXED · NOT STRAP-VALIDATED**

The user-facing string was:

> "Synced, but your strap had no stored history to hand over - only its diagnostic output. This *usually*
> means its clock has lost sync, so it isn't saving data to flash. Fully charge it to 100%, then
> reconnect."

Note "usually". It is a **heuristic presented as a diagnosis**, and on 2026-08-03 it was wrong three ways
at once:

- the strap **was** banking (it later handed over ~29 h with valid 2026 timestamps);
- the clock was **not** lost (zero `implausible`-timestamp drops, zero `RTC_LOST` across four days);
- the prescribed fix was **not** the one that worked — an in-app strap **Reboot** cleared it; charging
  would not have.

It also could not distinguish an offload that **completed empty** (`HISTORY_COMPLETE`, zero rows) from one
that **timed out** (`reason=timeout` — no response at all). The actual state was `timeout`, never
`HISTORY_COMPLETE`. Different failure, different fix.

**FIXED.** `BLEManager.emptyOffloadUserCopy(terminal:isWhoop5:hasBankedBeforeOnThisInstall:consecutiveEmptySyncs:)`
(`Strand/BLE/BLEManager.swift:2337`) over a new `EmptyOffloadTerminal` (`:2309`) — pure and unit-tested,
the same idiom as the neighbouring `classifyCompletedOffload`.

- **`.completedEmpty`** states the observation ("the strap finished the offload without handing over any
  stored history") and drops the clock assertion entirely.
- **`.timedOutEmpty`** returns copy **only** when the evidence supports it: a 5/MG that has banked rows on
  this install before (`sync.lastWriteOkAt` is present) and is now answering nothing. That is a wedged
  command channel, and the copy recommends the Devices-screen **Restart** first
  (`Strand/Screens/DevicesView.swift:203` — offered for live-connected non-4.0 WHOOPs), with charging as
  the fallback.

Two deliberate `nil` returns, both preserving existing honest surfaces:

- a 5/MG **never** seen banking keeps the #580 "history sync experimental" state — many 5/MG firmwares
  genuinely serve no history, and that is not a fault;
- a **WHOOP 4.0** timeout keeps the existing "the strap went quiet" copy, because #275 established there
  is no safe reboot frame for a 4.0, so recommending a restart there would be dead advice.

**Clock wording survives only where clock evidence exists** — the #324/#928 future-dated banner and the
Backfiller's #773/#547 implausible-timestamp paths, both of which genuinely measure a clock fault. The
`EmptySyncTracker` doc comments that described their output as "the clock-lost banner" were corrected to
match.

---

## A3. `Clock latched: no` was a standing false negative on 5/MG — **root cause CONFIRMED · label FIXED · underlying gate OPEN**

Reported as never having read `yes` on a working 5/MG across months of demonstrably successful banking —
**both before and after** `ce958669` (#261/#274, 2026-07-12) added the `strapNewestUnix` fallback
specifically to fix this. A fix that changes nothing twice is the tell that the diagnosis was incomplete.

**Root cause — the fallback structurally never receives input on a 5/MG.**
`clockLatchedLabel` reads two signals; on a 5/MG **neither can populate**:

1. `deviceClockUnix` comes from the GET_CLOCK correlation, which is WHOOP4-only — a 5/MG's reply rides the
   puffin notify channel and never reaches that path. This was known, and is exactly what #261 set out to
   work around.
2. `strapNewestUnix` comes from `LiveState.strapRange`, written by `state.setStrapRange` — which sits
   **behind the `feedsSync` gate** (`BLEManager.swift:5298`). The 5/MG call site passes
   **`feedsSync: false`** (`:5510`, vs `true` for WHOOP4 at `:5406`), because #695 gated the 5/MG
   newest/oldest decode pending hardware validation.

So callers have no `newest` to pass, the fallback never fires, and the row printed `no` forever. Before
#695 the 5/MG range reply was skipped entirely; after it, it is parsed and logged but not published —
which is why the symptom is identical on both sides of that fix.

A comment at the `setStrapRange` call additionally claimed the window was banked
"**UNCONDITIONALLY** (observability, not gated)" while the very same line was `if feedsSync`. That comment
is corrected, and the consequence is now documented at `handleDataRangeResponse` (`:5248`) so the next
reader of that gate knows what it costs.

**FIXED (the label).** `ConnectionReadout.clockLatchedLabel(deviceClockUnix:strapNewestUnix:isWhoop5:)`
(`Packages/StrandAnalytics/.../ConnectionReadout.swift:240`) returns
**`unknown (5/MG reports no usable data range)`** when both signals are absent on a 5/MG. Either real
signal still wins if it ever arrives, and a WHOOP 4.0 with no signal keeps the honest
`no (waiting for the strap clock)` — its correlation genuinely is still coming. Both call sites
(`DevicesView`, `TestCentreView`) pass the family.

This makes the row honest; **it does not make it informative.** A row that reads "unknown" is the correct
statement of what NOOP holds, and it is strictly better than a false "no" — but the signal itself is still
absent.

**OPEN — the real fix is flipping `feedsSync` for the 5/MG**, which needs a strap log confirming the
cmdOff-10 newest/oldest decode is correct. That is a hardware task, not a code one, and it is what would
turn this row (and `rtcWarning`, and the clock-drift line) into real yes/no answers on a 5/MG. See
"Needs a decision".

---

## Verification

| Suite | Result |
|---|---|
| `swift test` — `Packages/StrandAnalytics`, full suite | **1312 tests, 0 failures** (the two touched readout suites are 29 of them) |
| `xcodebuild -scheme Strand -destination 'platform=macOS'` | **BUILD SUCCEEDED** |
| `xcodebuild test` — `BackfillerSessionTallyTests` + `EmptyBankingClassifierTests` | 41 tests, 0 failures |
| `gradlew testFullDebugUnitTest` — `BackfillerSessionTallyTest`, `EmptyBankingClassifierTest`, `ConnectionReadoutTest` | 54 tests, 0 failures (full app module compiled) |

The app-target build is not optional here: `swift-packages.yml` does **not** compile app targets and
`app-build.yml` is disabled, so `Strand/BLE/BLEManager.swift`, `Strand/Collect/Backfiller.swift` and both
Screens files have **no default CI coverage** (`CLAUDE.md`, "The trap").

**Not covered:** the live BLE path. Every change here is copy/observability — no command, no frame, no ack
timing moved — but per `CLAUDE.md` compile-success proves nothing about connection behaviour, and the
strings above are only *observed* to be right when a real strap produces each terminal.

**iOS target not built** (needs the iOS 26 SDK / macos-26). The shared files touched compile in the macOS
target; `TestCentreView` / `DevicesView` are shared, so a `NOOPiOS` build is the remaining check.

**Localization:** the new strings ride unlocalized paths — `lastSyncError` dynamic text, the strap log, and
the readout *values* interpolated into the already-localized `"Clock latched: \(latched) · last frame …"`
wrapper. No catalog literal changed, so the 8-language append requirement does not apply to this change.

---

## Needs a decision

1. **`feedsSync` for the 5/MG (A3).** The one change that would make `Clock latched`, `rtcWarning` and the
   clock-drift line *informative* rather than merely honest on a 5/MG is flipping `:5510` to
   `feedsSync: true` — which #695 deliberately deferred until a strap log validates the cmdOff-10
   newest/oldest decode. That validation is a strap task. Until it happens the row correctly reads
   "unknown". Note the flip is not free: `strapNewestTs` also feeds the liveness watchdog, the #547
   session-relative ingest gate and the auto-continue future-dated guard, so a wrong decode would reach
   sync behaviour, not just the readout. **Validate the decode first, then flip.**
2. **Strap-validate the three terminals.** Each fix is a string that only proves itself against a real
   strap producing that terminal: a fully-drained sync (A1 caught-up), a completed-empty offload (A2), and
   a wedged 5/MG that has banked before (A2 timeout path). The last one is the 2026-08-03 case and the one
   worth reproducing deliberately.
3. **The 4.0 has no restart to recommend.** A2's timeout path stays silent on a 4.0 because #275 found no
   safe reboot frame. If a 4.0 ever wedges the same way, that user gets "the strap went quiet" and no
   remedy. Whether to surface the re-pair path there instead is a product call.

---

## What this should teach the next sweep

The previous sweep's lesson was *find the state before optimising against the symptom*. This one adds the
converse, and it is cheaper to act on:

**When a signal has two opposite meanings, the fix is usually not a better inference — it is printing the
one number that already distinguishes them.** All three signals here had their disambiguator in hand at
the moment of emission: the session row count, the terminal reason, the family. None of them were in the
output. Nothing needed to be inferred, measured, or modelled; the code simply had to say what it saw.

The second lesson is A3's: **a fix that visibly changes nothing has not been diagnosed.** #261 correctly
identified that a 5/MG cannot populate `deviceClockUnix`, added the right fallback, and shipped — and the
row kept reading `no`, because the fallback's own input was gated one layer down. A report of "still
broken after the fix" is evidence about the *diagnosis*, not about the user's patience.
