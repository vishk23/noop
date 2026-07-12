# noop-cloud Phase 3 — Phone Sync-Back + Apple Health Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Tasks 1 is in `/Users/vk/VKDEV/NOOP/noop-cloud` (TypeScript); Tasks 2–6 are in `/Users/vk/VKDEV/NOOP/noop` (Swift, personal fork lane). Steps use checkbox syntax.

**Goal:** Confirmed cloud edits (sleep bounds/stages, workout fixes/deletes/adds, HR-range deletions, metric-point deletions) land on VK's iPhone — applied through recompute-safe store APIs — and corrected sleep/workouts/HR re-export to Apple Health via the merged write-back; every applied edit is acked back so the server journal tracks phone state.

**Architecture:** The phone PULLS `GET /edits?since=<cursor>` (never pushed to). A gated `Strand/CloudSync/` module (compiled only under `CLOUD_SYNC`, same untracked-xcconfig mechanism as `OURA_CLOUD_IMPORT`) fetches active journal rows, applies them via a `CloudEditApplier` that uses `applySleepEdit`/`updateSleepStages` (userEdited=1 → survives recompute), physical deletes + a new `cloudTombstone` table (migration v26) so recompute/re-import can't resurrect deletions, and the `"noop-cloud"` source namespace for adds/corrected copies. After a batch that touched sleep/workouts/HR, the module triggers the existing HealthKit write-back for the affected window. Cursor lives in the store's `cursors` table; acks POST back with rw.

**Tech Stack:** Swift (app target `Strand/CloudSync/`, package `Packages/WhoopStore`), XCTest (StrandTests + WhoopStore package tests), TypeScript/vitest for the server ack endpoint. Device deploy via the established personal-signing pipeline.

## Global Constraints

- **Fork-only, flag-gated.** Every new app-target file starts with `#if CLOUD_SYNC` and the header comment pattern used by `Strand/Oura/*` ("Compiled ONLY when the CLOUD_SYNC compilation condition is set…"). The flag is added to `SWIFT_ACTIVE_COMPILATION_CONDITIONS` in the untracked `Strand/Oura/OuraSecrets.xcconfig` (rename-scope stays; the example file documents it). A default build contains none of this code.
- **Never mutate another source's rows in place.** Sleep edits go through `applySleepEdit` / `updateSleepStages` ONLY (they set/require `userEdited=1`). `fix_workout` = tombstone original + corrected copy under `deviceId "noop-cloud"`. `add_workout` under `"noop-cloud"`. Deletions = physical delete + `cloudTombstone` row; resurrection guards live in the store's upsert/insert paths.
- **Journal replay semantics:** apply rows in `seq` order where `kind != "undo" AND undoneBySeq == null` and seq > cursor. A row that arrives ALREADY undone is skipped (never applied). An edit undone AFTER the phone applied it is **out of MVP scope**: the applier detects it (acked seq now shows `undoneBySeq != null`) and surfaces "N server undos need manual attention" in the sync status — documented, not silently ignored.
- **`set_baseline_note` is server-only** — the applier records it as acked-no-op.
- **Idempotency:** re-applying an already-applied edit must be harmless (applySleepEdit is last-write-wins on the same values; deletes of absent rows are 0-row no-ops; adds under noop-cloud upsert on the same key). The cursor only advances after a successful batch + ack.
- **Migrations:** new migration is **`v26-cloud-tombstone`**, registered AFTER `v25-oura-raw`, additive only, with a migration test. Never edit existing migrations.
- **HealthKit:** iOS-only (`#if os(iOS)`); reuse the merged write-back (`HealthKitBridge.writeBack` path) rather than new HK write code — Task 5 first READS `StrandiOS/Health/HealthKitBridge.swift` to determine the public trigger + dedup semantics and adapts (expose a minimal public entry if needed; do not duplicate its sample-building logic).
- **Both app targets must compile** (`Strand` macOS + `NOOPiOS`) — CLOUD_SYNC files are shared; HealthKit calls guarded `#if os(iOS) && canImport(HealthKit)`. CI won't catch app-target breaks: build both locally.
- **Server change (Task 1) is additive**: `POST /edits/ack {seqs:[...]}` (rw) sets `ackedAt` on journal rows (new nullable column via `ALTER TABLE` guarded `IF NOT EXISTS`-style check); `GET /edits` gains `ackedAt` passthrough. SDK/pins unchanged; deploy at the end of Task 1.
- **Commits:** conventional, no Claude attribution (repo rule).

---

### Task 1 (noop-cloud repo): `POST /edits/ack` + `ackedAt`

**Files:**
- Modify: `noop-cloud/src/serverdb.ts` (add `ackedAt INTEGER` to editJournal CREATE; plus a startup `ALTER TABLE` catch for existing DBs)
- Modify: `noop-cloud/src/staging.ts` (`ackEdits(cfg, seqs: number[]): number`; include `ackedAt` in `JournalRow`)
- Modify: `noop-cloud/src/server.ts` (route)
- Test: `noop-cloud/test/edits-ack.test.ts`

**Interfaces:**
- Produces: `POST /edits/ack` (rw scope), JSON body `{ seqs: number[] }` (1..500 ints) → `{ acked: number }` (count of rows updated where `ackedAt IS NULL`); invalid body → 400 `{ error: "bad_seqs" }`.
- `JournalRow` gains `ackedAt: number | null`; `GET /edits` responses now carry it (additive field).

- [ ] **Step 1: Failing test** `test/edits-ack.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from "vitest";
import fs from "node:fs"; import path from "node:path"; import http from "node:http";
import { appendJournal, journalSince } from "../src/staging.js";
import { createApp } from "../src/server.js";

const dataDir = path.join(process.cwd(), "test/.tmp/edits-ack");
function cfg() { return { dataDir, mirrorPath: path.join(dataDir, "mirror.sqlite"), serverDbPath: path.join(dataDir, "server.sqlite"), maxIngestBytes: 262_144_000, roToken: "ro".padEnd(40, "x"), rwToken: "rw".padEnd(40, "y"), port: 0 } as any; }
function post(port: number, token: string, body: object): Promise<{ status: number; json: any }> {
  return new Promise((resolve) => {
    const payload = JSON.stringify(body);
    const r = http.request({ port, path: "/edits/ack", method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" } }, (res) => {
      let d = ""; res.on("data", (c) => (d += c)); res.on("end", () => resolve({ status: res.statusCode!, json: d ? JSON.parse(d) : null }));
    });
    r.end(payload);
  });
}
beforeAll(() => {
  fs.rmSync(dataDir, { recursive: true, force: true }); fs.mkdirSync(dataDir, { recursive: true });
  appendJournal(cfg(), { editId: "a1", kind: "set_baseline_note", payloadJSON: "{}", beforeJSON: null, rationale: null });
  appendJournal(cfg(), { editId: "a2", kind: "set_baseline_note", payloadJSON: "{}", beforeJSON: null, rationale: null });
});
describe("POST /edits/ack", () => {
  it("requires rw (ro → 401)", async () => {
    const app = createApp(cfg()); const s = app.listen(0); const port = (s.address() as any).port;
    expect((await post(port, cfg().roToken, { seqs: [1] })).status).toBe(401); s.close();
  });
  it("acks rows once and exposes ackedAt via GET /edits", async () => {
    const app = createApp(cfg()); const s = app.listen(0); const port = (s.address() as any).port;
    const r1 = await post(port, cfg().rwToken, { seqs: [1, 2] });
    expect(r1.json.acked).toBe(2);
    const r2 = await post(port, cfg().rwToken, { seqs: [1, 2] });
    expect(r2.json.acked).toBe(0); // already acked
    s.close();
    const rows = journalSince(cfg(), 0);
    expect(rows.every((e: any) => e.ackedAt !== null)).toBe(true);
  });
  it("400 on garbage", async () => {
    const app = createApp(cfg()); const s = app.listen(0); const port = (s.address() as any).port;
    expect((await post(port, cfg().rwToken, { seqs: "x" })).status).toBe(400); s.close();
  });
});
```

- [ ] **Step 2: FAIL run** (`npm test -- edits-ack`).
- [ ] **Step 3: serverdb.ts** — add `ackedAt INTEGER` to the editJournal CREATE, and after the `db.exec`, a guarded migration for pre-existing DBs:

```typescript
const cols = db.prepare("PRAGMA table_info(editJournal)").all() as any[];
if (!cols.some((c) => c.name === "ackedAt")) db.exec("ALTER TABLE editJournal ADD COLUMN ackedAt INTEGER");
```

- [ ] **Step 4: staging.ts** — `ackedAt: number | null` on `JournalRow`; and:

```typescript
export function ackEdits(cfg: C, seqs: number[]): number {
  return withDb(cfg, (db) => {
    const stmt = db.prepare("UPDATE editJournal SET ackedAt = ? WHERE seq = ? AND ackedAt IS NULL");
    const now = Math.floor(Date.now() / 1000);
    let n = 0; for (const s of seqs) n += stmt.run(now, s).changes;
    return n;
  });
}
```

- [ ] **Step 5: server.ts route** (after GET /edits, before error middleware):

```typescript
app.post("/edits/ack", requireScope(cfg, "rw"), express.json({ limit: "64kb" }), (req, res) => {
  const seqs = (req.body as any)?.seqs;
  if (!Array.isArray(seqs) || seqs.length === 0 || seqs.length > 500 || !seqs.every((s) => Number.isInteger(s) && s > 0)) {
    return res.status(400).json({ error: "bad_seqs" });
  }
  res.json({ acked: ackEdits(cfg, seqs) });
});
```
(import `ackEdits` alongside `journalSince`)

- [ ] **Step 6: PASS + full suite (expect 77) + build.**
- [ ] **Step 7: Commit `feat: POST /edits/ack — phone-applied tracking` and deploy: `fly deploy --ha=false --yes`; smoke: ack with rw → `{acked:N}`, ro → 401.**

---

### Task 2 (NOOP repo): migration v26 + `CloudTombstoneStore` + resurrection guards

**Files:**
- Modify: `Packages/WhoopStore/Sources/WhoopStore/Database.swift` (migration `v26-cloud-tombstone`)
- Create: `Packages/WhoopStore/Sources/WhoopStore/CloudTombstoneStore.swift`
- Modify: `Packages/WhoopStore/Sources/WhoopStore/JournalWorkoutAppleCache.swift` (`upsertWorkouts` skips tombstoned)
- Modify: `Packages/WhoopStore/Sources/WhoopStore/MetricSeriesStore.swift` (`upsertMetricSeries` skips tombstoned)
- Modify: `Packages/WhoopStore/Sources/WhoopStore/StreamStore.swift` (`insert` filters HR samples inside tombstoned ranges)
- Create: `Packages/WhoopStore/Sources/WhoopStore/CloudEditDeletes.swift` (`deleteHrRange`, `deleteMetricPoint` physical deletes)
- Test: `Packages/WhoopStore/Tests/WhoopStoreTests/CloudTombstoneTests.swift`

**Interfaces:**
- Migration `v26-cloud-tombstone`:

```swift
migrator.registerMigration("v26-cloud-tombstone") { db in
    try db.create(table: "cloudTombstone") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("kind", .text).notNull()        // "workout" | "hrRange" | "metricPoint"
        t.column("deviceId", .text).notNull()
        t.column("startTs", .integer)             // workout: startTs; hrRange: fromTs
        t.column("endTs", .integer)               // hrRange: toTs
        t.column("sport", .text)                  // workout
        t.column("day", .text)                    // metricPoint
        t.column("key", .text)                    // metricPoint
        t.column("editSeq", .integer).notNull()   // server journal seq (idempotency)
        t.column("createdAt", .integer).notNull()
        t.uniqueKey(["kind", "editSeq"])
    }
    try db.create(index: "idx_cloudTombstone_kind_device", on: "cloudTombstone", columns: ["kind", "deviceId"])
}
```
- `CloudTombstoneStore` (actor-friendly `WhoopStore` extension, same style as `OuraRawStore`):
  - `addTombstone(kind: String, deviceId: String, startTs: Int?, endTs: Int?, sport: String?, day: String?, key: String?, editSeq: Int) async throws` (INSERT OR IGNORE on the unique key)
  - `workoutTombstones(deviceId: String) async throws -> [(startTs: Int, sport: String)]`
  - `hrTombstoneRanges(deviceId: String) async throws -> [(fromTs: Int, toTs: Int)]`
  - `metricPointTombstones(deviceId: String) async throws -> [(day: String, key: String)]`
- Guards (all inside the store's existing write paths, same DB connection):
  - `upsertWorkouts`: before insert, drop input rows matching a `cloudTombstone` row `kind='workout' AND deviceId=? AND startTs=? AND sport=?` (single pre-query into a Set).
  - `upsertMetricSeries`: same for `kind='metricPoint'` on `(day,key)`.
  - `StreamStore.insert`: load `hrRange` tombstones for the deviceId once per call; filter `streams.hr` samples with `fromTs <= ts <= toTs`.
- `CloudEditDeletes`: `deleteHrRange(deviceId: String, fromTs: Int, toTs: Int) async throws -> Int`; `deleteMetricPoint(deviceId: String, day: String, key: String) async throws -> Int` (plain DELETEs returning changes).

- [ ] **Step 1: Failing test** `CloudTombstoneTests.swift`:

```swift
import XCTest
@testable import WhoopStore
import WhoopProtocol

final class CloudTombstoneTests: XCTestCase {
    func testWorkoutTombstoneBlocksResurrection() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertWorkouts([WorkoutRow(startTs: 100, endTs: 200, sport: "running", source: "whoop", durationS: 100, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)], deviceId: "d1")
        try await store.addTombstone(kind: "workout", deviceId: "d1", startTs: 100, endTs: nil, sport: "running", day: nil, key: nil, editSeq: 7)
        _ = try await store.deleteWorkouts(deviceId: "d1", sport: "running", from: 100, to: 100)
        // Re-import attempts to resurrect — the guard must drop it.
        let n = try await store.upsertWorkouts([WorkoutRow(startTs: 100, endTs: 200, sport: "running", source: "whoop", durationS: 100, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)], deviceId: "d1")
        XCTAssertEqual(n, 0)
        // Idempotent tombstone insert (same kind+editSeq).
        try await store.addTombstone(kind: "workout", deviceId: "d1", startTs: 100, endTs: nil, sport: "running", day: nil, key: nil, editSeq: 7)
    }
    func testHrRangeTombstoneFiltersInserts() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.addTombstone(kind: "hrRange", deviceId: "d1", startTs: 1000, endTs: 2000, sport: nil, day: nil, key: nil, editSeq: 8)
        try await store.insert(Streams(hr: [HRSample(ts: 1500, bpm: 60), HRSample(ts: 2500, bpm: 61)]), deviceId: "d1")
        let survivors = try await store.hrSamples(deviceId: "d1", from: 0, to: 10_000, limit: 10)
        XCTAssertEqual(survivors.map(\.ts), [2500])
    }
    func testDeleteHelpersAndMetricGuard() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(Streams(hr: [HRSample(ts: 1200, bpm: 60)]), deviceId: "d1")
        XCTAssertEqual(try await store.deleteHrRange(deviceId: "d1", fromTs: 1000, toTs: 2000), 1)
        _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-07-01", key: "ref_sleep_score", value: 80)], deviceId: "d1")
        try await store.addTombstone(kind: "metricPoint", deviceId: "d1", startTs: nil, endTs: nil, sport: nil, day: "2026-07-01", key: "ref_sleep_score", editSeq: 9)
        XCTAssertEqual(try await store.deleteMetricPoint(deviceId: "d1", day: "2026-07-01", key: "ref_sleep_score"), 1)
        let n = try await store.upsertMetricSeries([MetricPoint(day: "2026-07-01", key: "ref_sleep_score", value: 81)], deviceId: "d1")
        XCTAssertEqual(n, 0)   // guard drops the tombstoned point
    }
}
```
(Adjust `WorkoutRow`/`MetricPoint`/`Streams` initializers to the real signatures — read the source files first; the test intent is contractual, exact initializers are whatever the package defines.)

- [ ] **Step 2: FAIL** — `swift test --package-path Packages/WhoopStore --filter CloudTombstoneTests`.
- [ ] **Step 3: implement migration + store + guards + deletes** per Interfaces (read each modified file first; guards are small pre-filters, mirror existing code style; keep guard queries indexed).
- [ ] **Step 4: PASS filter + FULL package suite** (`swift test --package-path Packages/WhoopStore`) — zero regressions.
- [ ] **Step 5: Commit** `feat(store): cloudTombstone (v26) + resurrection guards + cloud delete helpers`

---

### Task 3 (NOOP repo): `CloudSyncClient` + settings (gated app-target module)

**Files:**
- Create: `Strand/CloudSync/CloudSyncSettings.swift` (Keychain URL+token, same pattern as `OuraTokenStore`)
- Create: `Strand/CloudSync/CloudEdit.swift` (Decodable journal row + `/edits` response)
- Create: `Strand/CloudSync/CloudSyncClient.swift` (fetch since-cursor, ack)
- Test: `StrandTests/CloudSyncClientTests.swift` (URLProtocol stub, same pattern as `OuraURLProtocolStub`)

**Interfaces:**
- All files `#if CLOUD_SYNC` … `#endif`, header comment per house pattern.
- `CloudSyncSettings`: `static var serverURL: String?` / `static var token: String?` (Keychain service `"com.noop.cloudsync"`, account `"server-url"` / `"rw-token"`); `static var isConfigured: Bool`.
- `CloudEdit: Decodable, Equatable`: `seq: Int, editId: String, kind: String, payloadJSON: String, beforeJSON: String?, rationale: String?, appliedAt: Int, undoneBySeq: Int?, ackedAt: Int?`.
- `CloudSyncClient` (init `(baseURL: URL, token: String, session: URLSession = .shared)`):
  - `fetchEdits(since: Int) async throws -> (edits: [CloudEdit], latestSeq: Int)` — GET `/edits?since=`, Bearer auth, decodes `{edits, latestSeq}`.
  - `ack(seqs: [Int]) async throws -> Int` — POST `/edits/ack`, returns `acked`.
  - Non-2xx → `CloudSyncError.badResponse(status, bodyPrefix)`.
- Tests: stubbed 200 happy paths (fixture JSON), 401 → error, malformed JSON → error.

- [ ] **Step 1: failing tests → Step 2: implement → Step 3: PASS via** `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/CloudSyncClientTests CODE_SIGNING_ALLOWED=NO` (after adding `CLOUD_SYNC` to the untracked xcconfig — see Task 6 Step 1; for tests, StrandTests shares the app xcconfig so the flag applies).
- [ ] **Step 4: Commit** `feat(cloudsync): gated client + keychain settings (fork lane)`

---

### Task 4 (NOOP repo): `CloudEditApplier` — journal → store, recompute-safe

**Files:**
- Create: `Strand/CloudSync/CloudEditApplier.swift`
- Test: `StrandTests/CloudEditApplierTests.swift` (against `WhoopStore.inMemory()`)

**Interfaces:**
- `struct CloudApplySummary: Equatable { var applied: Int; var skipped: Int; var needsAttention: Int; var touchedSleep: Bool; var touchedWorkouts: Bool; var touchedHr: Bool; var appliedSeqs: [Int] }`
- `enum CloudEditApplier { static func apply(_ edits: [CloudEdit], store: WhoopStore) async -> CloudApplySummary }`
  - Processes in seq order. Skips (`skipped += 1`): `kind == "undo"`, `undoneBySeq != nil`, `set_baseline_note`, unknown kinds (forward-compat), malformed payloads (decode failure — log, skip, DO NOT crash).
  - `adjust_sleep_bounds` → decode `{deviceId, startTs, newStartTs?, newEndTs?}`; fetch the session's current bounds via the store read; call `applySleepEdit(deviceId:detectedStartTs:newStartTs:newEndTs:)` (missing new value = keep current). 0-row result (session absent) → `needsAttention`.
  - `edit_sleep_stages` → `{deviceId, startTs, stages[]}` re-encoded to the app's stagesJSON shape `[{start,end,stage}]` → `updateSleepStages(deviceId:detectedStartTs:stagesJSON:)`. NOTE: `updateSleepStages` only touches `userEdited=1` rows — when the target row has `userEdited=0`, first promote it via `applySleepEdit` with its CURRENT bounds (sets the flag), then update stages. 0 rows → `needsAttention`.
  - `delete_workout` → `{deviceId, startTs, sport}` → `deleteWorkouts(deviceId:sport:from:startTs to:startTs)` + `addTombstone(kind:"workout"…, editSeq: seq)`.
  - `fix_workout` → tombstone + delete original (as above), then upsert the corrected copy (original fields overlaid with `patch`) under `deviceId "noop-cloud"`; requires `beforeJSON` (the server snapshot) for the original's full fields — if `beforeJSON` nil → `needsAttention`.
  - `add_workout` → upsert under `"noop-cloud"`.
  - `delete_hr_range` → `deleteHrRange` + `addTombstone(kind:"hrRange"…)`; `delete_metric_point` → `deleteMetricPoint` + tombstone.
  - First successful apply that used `"noop-cloud"` registers the pairedDevice row once (id `"noop-cloud"`, brand `"noop-cloud"`, model `"Cloud edits"`, `.cloudImport`, `.paired`) — same registration style as `OuraSyncWriter.persist` step 0.
  - Sets `touchedSleep/touchedWorkouts/touchedHr` per kind; `appliedSeqs` collects for ack.
- Tests (in-memory store): one test per kind family — sleep bounds survive a re-`upsertSleepSessions` (recompute simulation asserts userEdited protection engaged); stage edit on a userEdited=0 row (promotion path); fix_workout produces tombstone + noop-cloud copy; malformed payload skips without throwing; undone row skipped; summary flags correct.

- [ ] **Steps: failing tests → implement → PASS (`-only-testing:StrandTests/CloudEditApplierTests`) → commit** `feat(cloudsync): CloudEditApplier — recompute-safe journal application`

---

### Task 5 (NOOP repo): sync coordinator + Apple Health re-export + UI card

**Files:**
- Create: `Strand/CloudSync/CloudSyncCoordinator.swift` (fetch→apply→ack→cursor; HK trigger)
- Create: `Strand/CloudSync/CloudSyncModel.swift` (@MainActor ObservableObject; mirrors `OuraConnectModel` shape: busy/statusText; actions `pullNow(repo:)`, `saveSettings(url:token:)`)
- Modify: `Strand/Screens/DataSourcesView.swift` (add `cloudSyncCard` under `#if CLOUD_SYNC`, staggered below the Oura card; fields: server URL, token (SecureField), "Pull edits now" button, status line)
- Modify: `StrandiOS/Health/HealthKitBridge.swift` (ONLY IF NEEDED: expose a public `func rerunWriteBack(whoopStore:days:)` wrapper around the existing private write-back — read the file first; if a public trigger already exists, use it)
- Test: `StrandTests/CloudSyncCoordinatorTests.swift`

**Interfaces:**
- `CloudSyncCoordinator.pull(store: WhoopStore, client: CloudSyncClient) async throws -> CloudApplySummary`:
  1. `since = store.cursor("cloud_edits") ?? 0` (the cursors table — `setCursor`/`cursor` exist on the store).
  2. `fetchEdits(since:)` → `CloudEditApplier.apply` → if `appliedSeqs` non-empty: `ack(seqs:)` then `setCursor("cloud_edits", latestSeq)`. Cursor advances to `latestSeq` even when everything was skipped-but-acked… **No**: cursor advances to `latestSeq` only after ack succeeds; if ack throws, cursor stays (re-apply is idempotent by design).
  3. Returns summary (UI renders "Applied 3 · skipped 1 · 0 need attention").
- HK trigger (in `CloudSyncModel.pullNow`, iOS-only guard): when `summary.touchedSleep || touchedWorkouts || touchedHr`, call the write-back entry (days: 30) inside a `do/catch` that appends "· Apple Health re-export failed: <msg>" to status rather than failing the pull.
- Coordinator tests use a stub `CloudSyncClient` seam (protocol `CloudEditFetching` with fetch/ack, client conforms — mirror `OuraPageFetching` pattern): cursor advances only after ack; ack failure keeps cursor; needsAttention surfaces in summary.

- [ ] **Steps: read HealthKitBridge.swift first (record the chosen trigger + its dedup semantics in the report) → failing tests → implement → PASS coordinator tests + BOTH app builds (`Strand` macOS CODE_SIGNING_ALLOWED=NO; `NOOPiOS` device destination signed) → commit** `feat(cloudsync): coordinator + Data Sources card + Apple Health re-export hook`

---

### Task 6 (controller, not subagent): flag, device deploy, live E2E

- [ ] **Step 1:** Add `CLOUD_SYNC` to the untracked xcconfig (`Strand/Oura/OuraSecrets.xcconfig`): append ` CLOUD_SYNC` to its `SWIFT_ACTIVE_COMPILATION_CONDITIONS` line (create the line `SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) OURA_CLOUD_IMPORT CLOUD_SYNC` if absent). Mirror documentation line in `OuraSecrets.example.xcconfig` (committed).
- [ ] **Step 2:** `xcodegen generate`; build + install NOOPiOS on the iPhone (established pipeline); launch.
- [ ] **Step 3:** On-device: Data Sources → Cloud Sync card → paste `https://vk-noop-cloud.fly.dev` + rw token (from noop-cloud/.env) → **Pull edits now** (server journal currently holds the smoke-test rows: one edit_sleep_stages + its undo → expect "applied 0 · skipped 2" — both rows are undone/undo).
- [ ] **Step 4:** Real E2E: via Claude Code (noop-cloud MCP): propose+confirm a small `set_baseline_note` AND an `adjust_sleep_bounds` against a REAL night from VK's data (after his real .noopbak upload) — or against fixture data if the mirror still holds fixtures (then bounds target the fixture night, which won't exist on the phone → exercises needsAttention honestly). Pull on phone; verify NOOP UI reflects the sleep change (if real data) and Apple Health shows the corrected night (Health app). Ack verified: `GET /edits` shows `ackedAt` set.
- [ ] **Step 5:** Ledger + memory update.

---

## Self-Review

**Spec coverage (design §5 Phase 3):** pull transport `GET /edits?since=` ✅ (T1 ack + existing endpoint; T3 client); apply rules — sleep via `userEdited=1` paths ✅ (T4, incl. the updateSleepStages promotion subtlety), corrections under `"noop-cloud"` namespace + registration ✅ (T4), DB-backed tombstones replacing the UserDefaults gap ✅ (T2), ack-back ✅ (T1/T5). Apple Health via merged write-back ✅ (T5). Fork-only gating ✅ (Global Constraints + T6).
**Placeholder scan:** T2 test notes initializer signatures must be read from source — that is an explicit instruction to verify, not a TBD; all other steps carry code or exact commands. T5 deliberately defers HealthKitBridge internals to a read-first step because the file is #249's merged code (unknown to this plan) — the task's Interface pins the REQUIRED behavior (public trigger, days window, error containment).
**Type consistency:** `CloudEdit` fields = server `JournalRow` + `ackedAt` (T1); `CloudApplySummary` consumed by T5; store APIs referenced (applySleepEdit/updateSleepStages/deleteWorkouts/upsertWorkouts/upsertMetricSeries/insert/cursor/setCursor) verified to exist by controller scout (grep) — signatures re-checked in-task.
**Known risk:** `updateSleepStages` stage-string vocabulary (app uses its stagesJSON `stage` strings — verify in-task that "awake|light|deep|rem" match the app's legend; if the app uses different tokens (e.g. "wake"), map in the applier and record it).
