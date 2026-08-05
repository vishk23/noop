# 2026-08-04 — the strap-log durable tail throttles history offloads

A 29-hour WHOOP 5/MG history offload ran measurably slower than the hardware ceiling because of the
**strap-log persistence path**, not the BLE path. The cost is paid per appended log line, so it scales
with how noisy the log is — and one diagnostic (the undecodable-record hex dump) makes it very noisy on
exactly the straps whose offloads are already the longest.

| | Meaning |
|---|---|
| **CONFIRMED** | re-derived from current code; still true |
| **FIXED** | landed; see the commit/lines named |
| **STALE** | was true when first recorded; current code had already moved |
| **OPEN** | real and unfixed |
| **NOT STRAP-VALIDATED** | compiles and unit-tests pass; per `CLAUDE.md` that proves nothing about BLE behaviour |

---

## 1. The defect

**CONFIRMED.** `LiveState.append(log:)` mirrors the rolling log to a single `UserDefaults` key
(`strapLog.tail`) so a scheduled debug export that fires hours after the last session still has
something to write (#510). `persistTail` rebuilds the last `tailLimit` (2,000) lines and re-serializes
the whole array on each call.

Its doc comment asserted the blob "stays a few hundred KB at most" — an assumption that holds only
while every line is short. Two things break it together:

1. **The hex dump.** `Backfiller` dumps the **full bytes** of up to 8 undecodable record frames per
   chunk (#91 / #30), so an unmapped firmware's record layout can be triangulated from a user's shared
   log. A 1584-byte frame renders as a **3,168-character** line.
2. **The record that triggers it.** A strap can bank *structurally valid but empty* records — see §2.
   These fail decode, so they are classified as undecodable, so they get dumped. Once per second.

**Measured on the incident device:** 1,307 of the 2,000 tail lines were 3,168-char hex dumps, putting
the persisted blob at roughly **4 MB**. `redactPii()` additionally runs three regexes over each such
line on the way in.

### 1a. The "every line" figure was already stale — **STALE**

The original write-up (`SESSION_2026-08-03.md` §4) quoted `persistTail` as running on **every** appended
line. That was true of the release measured (5.3.0-era through 8.5.2) but **not of `origin/main` at
9.3.1**: a prior optimization pass (comment cites #700/#714/#720) had already added a 32-line count
batch plus an amortized ring trim.

The count batch narrows the window but does not close it, for a reason worth stating plainly: **a
count bounds writes per line, so the write rate still scales with how fast lines arrive.** A
reject-heavy drain emits ~10 lines per 2-second chunk, so 32 lines is ~6.4 seconds — i.e. a ~4 MB plist
rewrite every ~6.4 s for the duration of the offload. (Independently measured the same day; see the
battery audit cross-reference in §5.)

Anyone re-deriving this from the session doc should re-read the code first — that is how the stale
figure survived into a second session.

## 2. Why the dumped frames carried nothing — **CONFIRMED**

1,307 rejected frames were analysed byte-wise and were identical in structure:

```
size              1584 B   (all 1307)
nonzero offsets   0–13, 15–20     ~21-byte header (magic aa, seq at 11, LE unix ts at 15–18)
                  1580–1583       4-byte CRC32 trailer
offsets 21–1579   ZERO in every frame   (1,559 bytes)
```

These are **not an unmapped layout**. They are correctly framed, correctly timestamped, and empty —
almost certainly a CRC computed over an all-zero payload. The hex dump exists to let a layout be
mapped; **1,559 zero bytes have no layout to map.** The dump was spending the log budget (and the
serialization cost everything else pays) on frames that carry no information.

Onset is datable: the raw-archive table `v18AuxSample` is empty before **2026-07-27** and then
accumulates at exactly 1 row/sec. Jul 27 is the session in which the `enable_raw_data_w_ecg` config
flag was written to the strap. **Correlation, not proven causation** — but the boundary is clean.

This is the second instance of the same shape: see
[`2026-07-15-strap-battery-backfill-observability.md`](2026-07-15-strap-battery-backfill-observability.md)
§0, where an experimental probe's R22 `SET_CONFIG` writes turned on per-second deep-buffer banking
(1244 B + 2140 B records) that the app then had to carry. **Writing a config flag to the strap can
change what it banks, permanently, with no other signal.**

## 3. The fix — **FIXED**

Three changes, one commit.

### 3a. Debounce the durable-tail write by TIME

`Strand/BLE/LiveState.swift` — replaces the 32-line count batch with at most **one write per second**,
plus a **trailing flush** so the tail is never stale by more than the debounce window (it feeds a
scheduled export, so lagging by a second is irrelevant; lagging unboundedly is not). The write rate is
now independent of the append rate. The existing flush on disconnect (`clearBiometrics`) is unchanged,
so a completed session's tail is always fully mirrored.

### 3b. Cap each PERSISTED line

`LiveState.capForPersist` truncates any line over **512 characters** with an explicit `… (+N more)`
suffix, so a capped dump is visibly capped rather than silently short, and the prefix — which carries
the frame size and the record header — survives.

The cap applies **at persist time only**. The in-memory `log` ring keeps full lines, so the Live log
card and the manual `exportableLogText()` share (where a full hex dump is exactly the point) are
byte-unchanged. This bounds the durable blob at roughly 1 MB even against a *future* firmware whose
unmapped records have genuinely non-zero payloads worth dumping.

### 3c. Skip the hex dump for all-zero payloads

`isAllZeroPayloadRecord` (new, `Packages/WhoopProtocol/…/HistoricalStreams.swift`) tests whether the
bytes between the record header and the CRC trailer are all zero. Both Backfillers now split the
rejects: **informative** frames keep the full 8-frame dump; **zero-payload** frames collapse to one
summarizing line per chunk carrying the count and the first frame's header hex.

The header is deliberately still logged — it is the part that varies (seq, timestamp) and the part
worth mapping. `headerLength` defaults to the observed 21 bytes and is intentionally generous: if a
real header is shorter, the extra assumed bytes are zero in a zero-payload frame anyway, so no
mappable byte is ever hidden by the check.

In the observed scenario this removes the 3,168-char lines **at source**, which is what actually
restores the original "a few hundred KB" claim; §3b is the backstop for the case where the dumps are
genuinely wanted.

### Cross-platform

The **hex-dump skip is mirrored in Kotlin** (`com.noop.protocol.isAllZeroPayloadRecord`,
`android/…/ble/Backfiller.kt`) with byte-identical log wording — the same defect existed there.

The **debounce and line cap are Apple-only by design.** Android's `StrapLogBuffer` is an in-memory
`ArrayDeque` with a line cap and a 24 h window, and its scheduled export reads that buffer directly;
there is no per-line persistence, so the cost this fixes does not exist on that platform. This is a
deliberate asymmetry in a *mechanism*, not a divergence in stored data or analytics — the parity
contract is unaffected.

## 4. Verification

| Check | Result |
|---|---|
| `swift test` — `WhoopProtocol/AllZeroPayloadRecordTests` | 6/6 pass (runs in `swift-packages` CI) |
| `xcodegen generate` + `xcodebuild … -scheme Strand … build` | **BUILD SUCCEEDED** |
| `xcodebuild … test` — `StrandTests/LiveStatePersistTailTests` | 5/5 pass |
| `xcodebuild … test` — `StrandTests/LiveStateDomainTagTests` (existing) | 4/4 pass |
| `./gradlew testFullDebugUnitTest --tests …AllZeroPayloadRecordTest` | 6/6 pass, 0 failures |

The app-target build was run locally on purpose: `app-build.yml` is disabled, so **no default CI
compiles `Strand/`** — a compile error there passes every green check.

**NOT STRAP-VALIDATED.** The change is confined to logging and persistence and does not touch the
CoreBluetooth, offload, or ack paths, but the throughput improvement itself has **not** been re-measured
against a live strap offload. Per `CLAUDE.md`, compile success proves nothing about BLE behaviour.

## 5. What remains open

- **OPEN — the cause, not the symptom.** Clearing `enable_raw_data_w_ecg` would stop the empty records
  being banked at all, halving offload volume. That is the higher-leverage change; this fix only stops
  the app from punishing itself for them. The empties were verified **still active** on 2026-08-04
  (`v18AuxSample` at 607,476 rows, still exactly 1 row/sec, continuing past the Aug 3 strap reboot), so
  this is live, not historical. Note that `v18AuxSample` is pruned to a rolling 7 days per device
  (`WhoopStore.v18AuxRetentionRows` = 604,800 = 7 × 86,400 strap-seconds, with a Kotlin twin
  `V18_AUX_RETENTION_ROWS`), so at 1 row/sec the table saturates at exactly that number — **a plateaued
  row count is not evidence that banking stopped**; judge by the strap log's reject lines.
- **OPEN — measure the effect.** Offload throughput and battery should be re-measured after this lands
  *and* after the flag is cleared, before any further battery work (e.g. adding GPS) is weighed.
- **OPEN — a reader for `v18AuxSample`.** This table held the decisive evidence, unread, for six days
  (`readBy: null`). Capture without a reader is how findings get missed.
- **Related, separate:** the throughput *attribution* in `SESSION_2026-08-03.md` §13 (a mid-drain
  slowdown blamed on session restarts) was retracted — four uncontrolled confounds, including that the
  session-boundary count was taken from this very 2,000-line rolling tail, whose wall-clock coverage
  shrinks as the log gets noisier. **The two code-level findings above do not rest on that timing
  data**: the persistence cost is a plain reading of `append(log:)`, and the zero-payload structure is a
  byte census over 1,307 frames.
