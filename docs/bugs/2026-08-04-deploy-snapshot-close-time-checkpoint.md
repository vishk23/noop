# The per-deploy liters snapshot: SQLite's close-time checkpoint, and its fix (2026-08-04)

**Status: fixed in `Packages/WhoopStore` (branch `claude/eloquent-carson-7bc8a8`).** Fork-only:
the liters replication trial is iOS-only, and nothing here changes behaviour for a build that never
calls `StoreReplication.configure`.

## Symptom

With the liters page replicator live, the **first push after every deploy** degraded to a full
snapshot of the whole database (~400 MB and growing with the DB), with the replicator reporting
`"wal overwritten"`. On 2026-08-04 that re-baseline PUT outlived the server proxy's request window
twice (HTTP 408). Ordinary day-to-day pushes were unaffected — deltas as small as 198 bytes — so
this was **install cost, not per-sync cost**, and it recurred on every `devicectl install`.

## Mechanism

A page replicator keeps a long-lived resume offset into the WAL, so anything that **restarts** the
WAL (new header salts, frame 1) forces it to re-baseline. The app-side checkpointers were already
silenced under `WalCheckpointing.external` (`wal_autocheckpoint = 0` on every pool connection, and
backups staged through the Online Backup API instead of `checkpointWAL()` — see the 2026-07-28
checkpoint lesson in `WhoopStore.writeConsistentCopy`). What remained:

- **SQLite checkpoints the WAL when the file's last connection closes.** That is a separate
  mechanism from autocheckpoint; no pragma touches it. A graceful app termination closes every
  `DatabasePool`, the close-time checkpoint fully backfills the WAL, and SQLite restarts it on the
  next write. `devicectl install` terminates the app gracefully — so **every deploy bought one
  snapshot**. A normal iOS SIGKILL suspension never closes the connection and was measured to cost
  nothing (a reopened writer ships a delta).
- **A second, unnoticed restarter with the same shape:** `quarantineIncompatibleDatabase` (#222)
  opens a plain probe `DatabaseQueue` on the live file **before** the pool, on every open of an
  existing file. At a cold launch that probe is the file's *only* connection, so its close is a
  last-connection close — it would checkpoint and restart the WAL that had survived the previous
  run, re-introducing the snapshot one launch later no matter what the pools did.

## Fix

`SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE` (`sqlite3_db_config` verb 1006) disables the close-time
checkpoint per connection. Under `WalCheckpointing.external`, `WhoopStore(path:)` now sets it on
**every** connection it opens — the pool's writer and readers via `Configuration.prepareDatabase`,
and the quarantine probe (the checkpointing mode is threaded through `StoreOpenGate` into it).

Design points, in the order they bit previous attempts:

- **Coverage is not per-call-site.** The flag rides the same `walCheckpointing` parameter whose
  default `StoreReplication` supplies, so both existing pools (`Repository.ensureStore`,
  `BLEManager.bootstrapStore`) and any opener written later are covered without being touched. An
  opener that missed it would silently reintroduce the snapshot on every graceful exit — the exact
  "nothing throws, nothing logs" failure `StoreReplication` exists to prevent. For the same reason,
  a failure to apply the flag **throws and fails the open** rather than degrading silently.
- **`sqlite3_db_config` is C-variadic, which Swift cannot call** (the SDK marks it unavailable),
  and a `dlsym` cast to a fixed-arity function pointer is an ABI mismatch on arm64, where variadic
  arguments travel on the stack. The verb is wrapped in a new `WhoopStoreCShims` C target
  (`whoopstore_disable_checkpoint_on_close` + a read-back form for tests).
- **Close-time only.** Explicit checkpoints are unaffected: `checkpointWAL()`, the
  `WalBackstopMonitor`'s emergency TRUNCATE (the load-bearing 64 MiB ceiling under `.external`),
  and the replicator's own checkpoints all run exactly as before. The backstop suite passes with
  the flag in force.
- **`.automatic` is untouched, byte-for-byte** — upstream's close-time checkpoint is part of stock
  behaviour (it is what keeps a plain build's `-wal` from lingering), and tests pin both the
  config read-back (0 on writer and reader) and the behaviour (salts change across close/reopen).

## Verification

`WalCheckpointingTests` (399/399 package tests green; macOS app compiles):

- `testExternalWalSurvivesCloseAndReopenAppendsToIt` — the on-disk property: open `.external`,
  write, capture the WAL header salts (bytes 16..<24) and `-wal` size, close the pool → the `-wal`
  still exists with byte-identical salts and size; reopen on the same path (which also exercises
  the quarantine probe — a probe without the flag fails this leg), write → **same salts, larger
  file**: the reopened writer appended instead of restarting.
- `testAutomaticCloseRestartsTheWal` — the contrast run: same choreography under `.automatic`
  lands on different salts, pinning the flag's absence from the default path.
- `testExternalDisablesCloseTimeCheckpointOnWriterAndReader` /
  `testAutomaticLeavesCloseTimeCheckpointEnabled` — direct config read-back on both connection
  kinds. Reader coverage matters: `DatabasePool.close()` closes the writer *first*, so the
  last-connection close is a reader's.

## Still open / worth watching

- **Field confirmation:** `SyncPushTelemetry.snapshotRate` should show the first push after the
  next deploy shipping a delta instead of a `"wal overwritten"` re-baseline. That was the last
  mechanical blocker on trial → default for the replicator (background upload remains the open
  upstream one).
- **`DatabaseIntegrity.quickCheckFailure`'s read-write fallback** is now the one connection in the
  tree that can reach the live store without the flag. It is left alone deliberately: its
  close-time checkpoint is *desired* for the staged backup files it normally probes, and against
  the live store it is never the last connection while the app's pool is open. If a restore flow
  ever probes the live file with no pool open, revisit.
- `Repository.checkpointForBackup()` still truncates deliberately (manual Export + at-most-daily
  folder backup) — unchanged, per the 2026-07-28 lesson.
