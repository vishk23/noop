# noop-cloud Phase 2 — Gated Writes + Edit Journal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AI can *propose* data corrections (with a human-readable diff and a snapshot of the original), a human *confirms* with the rw credential, confirmed edits land in an append-only journal + overlay that read tools reflect — and the pristine mirror is never touched.

**Architecture:** All write state lives in `server.sqlite` (two new tables: `proposal`, `editJournal`). `propose_edit` validates the payload per edit-kind, captures a **before-snapshot** from the mirror, renders a human diff, and stages a proposal. `confirm_edit` (rw-only, invisible to ro callers) moves it to the append-only journal; `undo_edit` appends a reversal entry (the journal never mutates). Read tools consult a computed **overlay** derived from active journal entries. A new `GET /edits?since=<seq>` endpoint exposes the sequenced journal for Phase-3 phone pull. Scope is threaded per request: the stateless `/mcp` route detects ro-vs-rw from the bearer token and builds the MCP server with only the tools that scope may see.

**Tech Stack:** unchanged — TypeScript 5.6, Express 4, `@modelcontextprotocol/sdk` pinned **1.29.0**, `better-sqlite3` pinned **12.11.1**, zod, vitest. Repo `/Users/vk/VKDEV/NOOP/noop-cloud` (Phase 1 deployed at `https://vk-noop-cloud.fly.dev`; 41 tests green).

## Global Constraints

- **The mirror is never written.** Overlay + journal live only in `server.sqlite`. Any SQL against `mirror.sqlite` stays read-only (`{ readonly: true, fileMustExist: true }`).
- **Scope model (spec §5/§6):** `propose_edit`, `list_pending`, `edit_journal` available to **ro** (routines may stage, never apply). `confirm_edit`, `reject_edit`, `undo_edit` **registered only for rw callers** — invisible in ro `tools/list`, not merely rejected. rw implies ro.
- **Journal is append-only and idempotent by edit id.** Undo appends a reversal row (`kind='undo'`) and marks the original's `undoneBySeq`; rows are never updated otherwise, never deleted. `seq` (AUTOINCREMENT) is the Phase-3 pull cursor.
- **Every proposal carries `beforeJSON`** — the affected row(s) as they exist at propose time — so "what the data originally said" is permanently auditable.
- **Edit kinds (exactly these six):** `fix_workout`, `delete_workout`, `add_workout`, `adjust_sleep_bounds`, `delete_metric_point`, `set_baseline_note`. `add_workout` rows carry `deviceId: "noop-cloud"` (the server's own source namespace — spec §5 Phase 3 rule).
- **Annotations:** propose/list/journal → `readOnlyHint` false/true as appropriate but `destructiveHint: false`; `confirm_edit` and `undo_edit` → `destructiveHint: true`. (These drive client approval UI; enforcement stays server-side.)
- **Guard pattern (house style):** tools that read the mirror keep the `!fs.existsSync(cfg.mirrorPath)` → `notIngested: true` guard. Proposing an edit against a missing mirror returns a structured error, not a throw.
- **Overlay honesty:** overlay changes what `sleep_summary` / `workout_summary` / `metric_series` return (with `edited: true` / `added: true` provenance), but `dailyMetric`-derived numbers (`health_snapshot`, `compare_sources`, `totalSleepMin`) still come from the phone's own rollups — corrections reach those only after Phase 3 applies the edit on-phone and the next upload returns. Tool descriptions must say this plainly.
- **No secrets in git**; same pins; deploy via `fly deploy --ha=false` at the end.

---

### Task 1: `serverdb.ts` (shared server-DB opener + staging schema) and `staging.ts` (state machine)

**Files:**
- Create: `noop-cloud/src/serverdb.ts`
- Create: `noop-cloud/src/staging.ts`
- Modify: `noop-cloud/src/ingest.ts` (import `openServerDb` from serverdb.js; delete its local copy)
- Test: `noop-cloud/test/staging.test.ts`

**Interfaces:**
- Consumes: `Config` (`serverDbPath`).
- Produces (serverdb.ts): `openServerDb(cfg: Pick<Config,"serverDbPath">): Database.Database` — WAL, `CREATE TABLE IF NOT EXISTS` for `ingestLog` (unchanged shape), `proposal`, `editJournal`.
- Produces (staging.ts):
  - `interface ProposalRow { id: string; kind: string; payloadJSON: string; rationale: string; beforeJSON: string | null; diffText: string; status: "pending"|"confirmed"|"rejected"; createdAt: number; resolvedAt: number | null }`
  - `interface JournalRow { seq: number; editId: string; kind: string; payloadJSON: string; beforeJSON: string | null; rationale: string | null; appliedAt: number; undoneBySeq: number | null }`
  - `createProposal(cfg, p: Omit<ProposalRow,"status"|"createdAt"|"resolvedAt">): ProposalRow`
  - `getProposal(cfg, id: string): ProposalRow | null`
  - `listPending(cfg): ProposalRow[]`
  - `resolveProposal(cfg, id: string, status: "confirmed"|"rejected"): ProposalRow | null` (only from `pending`; returns null if absent or already resolved)
  - `appendJournal(cfg, e: { editId: string; kind: string; payloadJSON: string; beforeJSON: string | null; rationale: string | null }): number` — returns `seq`; UNIQUE(editId) makes double-apply throw (caller treats as idempotency signal)
  - `journalSince(cfg, since: number): JournalRow[]` (seq > since, ascending)
  - `activeEdits(cfg): JournalRow[]` — `undoneBySeq IS NULL AND kind != 'undo'`, ascending
  - `markUndone(cfg, targetSeq: number, bySeq: number): void`

- [ ] **Step 1: Write the failing test**

`test/staging.test.ts`:

```typescript
import { describe, it, expect, beforeEach } from "vitest";
import fs from "node:fs"; import path from "node:path";
import { createProposal, getProposal, listPending, resolveProposal, appendJournal, journalSince, activeEdits, markUndone } from "../src/staging.js";

const dataDir = path.join(process.cwd(), "test/.tmp/staging");
const cfg = { serverDbPath: path.join(dataDir, "server.sqlite") } as any;
beforeEach(() => { fs.rmSync(dataDir, { recursive: true, force: true }); fs.mkdirSync(dataDir, { recursive: true }); });

const draft = (id: string) => ({ id, kind: "delete_workout", payloadJSON: JSON.stringify({ deviceId: "my-whoop", startTs: 100, sport: "running" }), rationale: "duplicate", beforeJSON: JSON.stringify({ sport: "running" }), diffText: "- running workout @100" });

describe("staging state machine", () => {
  it("propose → pending → confirm; not listed after", () => {
    createProposal(cfg, draft("edit_a"));
    expect(listPending(cfg).map((p) => p.id)).toEqual(["edit_a"]);
    const r = resolveProposal(cfg, "edit_a", "confirmed");
    expect(r?.status).toBe("confirmed");
    expect(listPending(cfg)).toEqual([]);
  });
  it("resolve is single-shot (second resolve returns null)", () => {
    createProposal(cfg, draft("edit_b"));
    expect(resolveProposal(cfg, "edit_b", "rejected")?.status).toBe("rejected");
    expect(resolveProposal(cfg, "edit_b", "confirmed")).toBeNull();
  });
  it("journal is append-only, sequenced, idempotent by editId", () => {
    const s1 = appendJournal(cfg, { editId: "edit_c", kind: "delete_workout", payloadJSON: "{}", beforeJSON: null, rationale: null });
    const s2 = appendJournal(cfg, { editId: "edit_d", kind: "set_baseline_note", payloadJSON: "{}", beforeJSON: null, rationale: null });
    expect(s2).toBe(s1 + 1);
    expect(() => appendJournal(cfg, { editId: "edit_c", kind: "delete_workout", payloadJSON: "{}", beforeJSON: null, rationale: null })).toThrow();
    expect(journalSince(cfg, s1).map((j) => j.seq)).toEqual([s2]);
  });
  it("undo marks original inactive; undo rows never count as active", () => {
    const s1 = appendJournal(cfg, { editId: "edit_e", kind: "delete_workout", payloadJSON: "{}", beforeJSON: null, rationale: null });
    const s2 = appendJournal(cfg, { editId: "undo_of_e", kind: "undo", payloadJSON: JSON.stringify({ targetSeq: s1 }), beforeJSON: null, rationale: null });
    markUndone(cfg, s1, s2);
    expect(activeEdits(cfg)).toEqual([]);
    expect(journalSince(cfg, 0).length).toBe(2); // history intact
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- staging`
Expected: FAIL — `Cannot find module '../src/staging.js'`.

- [ ] **Step 3: Implement `src/serverdb.ts`**

```typescript
import Database from "better-sqlite3";
import type { Config } from "./config.js";

/** Single opener for the server-owned DB (never the mirror). All CREATEs are idempotent. */
export function openServerDb(cfg: Pick<Config, "serverDbPath">): Database.Database {
  const db = new Database(cfg.serverDbPath);
  db.pragma("journal_mode = WAL");
  db.exec(`
    CREATE TABLE IF NOT EXISTS ingestLog (id INTEGER PRIMARY KEY AUTOINCREMENT, receivedAt INTEGER, bytes INTEGER, latestDay TEXT);
    CREATE TABLE IF NOT EXISTS proposal (
      id TEXT PRIMARY KEY, kind TEXT NOT NULL, payloadJSON TEXT NOT NULL, rationale TEXT NOT NULL,
      beforeJSON TEXT, diffText TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','confirmed','rejected')),
      createdAt INTEGER NOT NULL, resolvedAt INTEGER);
    CREATE TABLE IF NOT EXISTS editJournal (
      seq INTEGER PRIMARY KEY AUTOINCREMENT, editId TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
      payloadJSON TEXT NOT NULL, beforeJSON TEXT, rationale TEXT,
      appliedAt INTEGER NOT NULL, undoneBySeq INTEGER);
  `);
  return db;
}
```

- [ ] **Step 4: Implement `src/staging.ts`**

```typescript
import type { Config } from "./config.js";
import { openServerDb } from "./serverdb.js";

type C = Pick<Config, "serverDbPath">;

export interface ProposalRow {
  id: string; kind: string; payloadJSON: string; rationale: string;
  beforeJSON: string | null; diffText: string;
  status: "pending" | "confirmed" | "rejected"; createdAt: number; resolvedAt: number | null;
}
export interface JournalRow {
  seq: number; editId: string; kind: string; payloadJSON: string;
  beforeJSON: string | null; rationale: string | null; appliedAt: number; undoneBySeq: number | null;
}

function withDb<T>(cfg: C, fn: (db: ReturnType<typeof openServerDb>) => T): T {
  const db = openServerDb(cfg);
  try { return fn(db); } finally { db.close(); }
}

export function createProposal(cfg: C, p: Omit<ProposalRow, "status" | "createdAt" | "resolvedAt">): ProposalRow {
  return withDb(cfg, (db) => {
    const createdAt = Math.floor(Date.now() / 1000);
    db.prepare(`INSERT INTO proposal (id, kind, payloadJSON, rationale, beforeJSON, diffText, status, createdAt)
                VALUES (?,?,?,?,?,?, 'pending', ?)`)
      .run(p.id, p.kind, p.payloadJSON, p.rationale, p.beforeJSON, p.diffText, createdAt);
    return { ...p, status: "pending", createdAt, resolvedAt: null };
  });
}
export function getProposal(cfg: C, id: string): ProposalRow | null {
  return withDb(cfg, (db) => (db.prepare("SELECT * FROM proposal WHERE id = ?").get(id) as ProposalRow | undefined) ?? null);
}
export function listPending(cfg: C): ProposalRow[] {
  return withDb(cfg, (db) => db.prepare("SELECT * FROM proposal WHERE status = 'pending' ORDER BY createdAt, id").all() as ProposalRow[]);
}
export function resolveProposal(cfg: C, id: string, status: "confirmed" | "rejected"): ProposalRow | null {
  return withDb(cfg, (db) => {
    const r = db.prepare("UPDATE proposal SET status = ?, resolvedAt = ? WHERE id = ? AND status = 'pending'")
      .run(status, Math.floor(Date.now() / 1000), id);
    if (r.changes === 0) return null;
    return db.prepare("SELECT * FROM proposal WHERE id = ?").get(id) as ProposalRow;
  });
}
export function appendJournal(cfg: C, e: { editId: string; kind: string; payloadJSON: string; beforeJSON: string | null; rationale: string | null }): number {
  return withDb(cfg, (db) => {
    const r = db.prepare(`INSERT INTO editJournal (editId, kind, payloadJSON, beforeJSON, rationale, appliedAt)
                          VALUES (?,?,?,?,?,?)`)
      .run(e.editId, e.kind, e.payloadJSON, e.beforeJSON, e.rationale, Math.floor(Date.now() / 1000));
    return Number(r.lastInsertRowid);
  });
}
export function journalSince(cfg: C, since: number): JournalRow[] {
  return withDb(cfg, (db) => db.prepare("SELECT * FROM editJournal WHERE seq > ? ORDER BY seq").all(since) as JournalRow[]);
}
export function activeEdits(cfg: C): JournalRow[] {
  return withDb(cfg, (db) => db.prepare("SELECT * FROM editJournal WHERE undoneBySeq IS NULL AND kind != 'undo' ORDER BY seq").all() as JournalRow[]);
}
export function markUndone(cfg: C, targetSeq: number, bySeq: number): void {
  withDb(cfg, (db) => db.prepare("UPDATE editJournal SET undoneBySeq = ? WHERE seq = ? AND undoneBySeq IS NULL").run(bySeq, targetSeq));
}
```

- [ ] **Step 5: Point `src/ingest.ts` at the shared opener**

In `src/ingest.ts`: delete its local `openServerDb` function, add `import { openServerDb } from "./serverdb.js";`, keep `latestIngest` and the `ingestLog` insert working exactly as before (the table shape is unchanged). Re-export for compatibility: `export { openServerDb } from "./serverdb.js";`

- [ ] **Step 6: Run to verify pass**

Run: `npm test` — Expected: staging 4/4 new + all 41 existing = 45 passing. `npm run build` clean.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: staging store — proposals + append-only edit journal in server.sqlite"
```

---

### Task 2: Edit kinds — payload validation, before-snapshot, human diff

**Files:**
- Create: `noop-cloud/src/edits/kinds.ts`
- Create: `noop-cloud/src/edits/diff.ts`
- Test: `noop-cloud/test/edits-diff.test.ts`

**Interfaces:**
- Consumes: `Mirror` (Task 4 of Phase 1), `Config`.
- Produces (kinds.ts):
  - `const EDIT_KINDS = ["fix_workout","delete_workout","add_workout","adjust_sleep_bounds","delete_metric_point","set_baseline_note"] as const; type EditKind = typeof EDIT_KINDS[number];`
  - `payloadSchema(kind: EditKind): z.ZodTypeAny` with shapes:
    - `fix_workout`: `{ deviceId: string, startTs: number, sport: string, patch: { sport?: string, startTs?: number, endTs?: number, energyKcal?: number|null, distanceM?: number|null } }` (patch must be non-empty)
    - `delete_workout`: `{ deviceId, startTs, sport }`
    - `add_workout`: `{ startTs: number, endTs: number, sport: string, energyKcal?: number, distanceM?: number, notes?: string }` (deviceId is NOT accepted — forced to `"noop-cloud"`)
    - `adjust_sleep_bounds`: `{ deviceId, startTs, newStartTs?: number, newEndTs?: number }` (at least one of newStartTs/newEndTs)
    - `delete_metric_point`: `{ deviceId, day: string (YYYY-MM-DD regex), key: string }`
    - `set_baseline_note`: `{ note: string (1..500), deviceId?: string }`
- Produces (diff.ts):
  - `class EditTargetError extends Error { constructor(public code: "target_not_found"|"not_ingested", msg?: string) }`
  - `captureBefore(cfg: Config, kind: EditKind, payload: any): object | null` — reads the mirror; returns the affected row for fix/delete/adjust kinds (throws `EditTargetError("target_not_found")` if absent; throws `EditTargetError("not_ingested")` if no mirror); returns `null` for `add_workout`/`set_baseline_note`.
  - `renderDiff(kind: EditKind, payload: any, before: object | null): string` — short human-readable text, e.g. `sleep 2026-06-13 03:00→10:00 ⇒ end 06:00 (was 10:00)`.

- [ ] **Step 1: Write the failing test**

`test/edits-diff.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from "vitest";
import fs from "node:fs"; import path from "node:path";
import { buildNoopbak } from "./fixtures/make-fixture.js";
import { ingestNoopbak } from "../src/ingest.js";
import { payloadSchema, EDIT_KINDS } from "../src/edits/kinds.js";
import { captureBefore, renderDiff, EditTargetError } from "../src/edits/diff.js";

const dataDir = path.join(process.cwd(), "test/.tmp/edits-diff");
const cfg = { dataDir, mirrorPath: path.join(dataDir, "mirror.sqlite"), serverDbPath: path.join(dataDir, "server.sqlite"), maxIngestBytes: 262_144_000 } as any;
const RUN_TS = Math.floor(new Date("2026-06-12T18:00:00Z").getTime() / 1000); // fixture running workout

beforeAll(() => { fs.rmSync(dataDir, { recursive: true, force: true }); fs.mkdirSync(dataDir, { recursive: true }); const z = path.join(dataDir, "b.noopbak"); buildNoopbak(z); ingestNoopbak(fs.readFileSync(z), cfg); });

describe("edit kinds", () => {
  it("validates payloads per kind", () => {
    expect(payloadSchema("delete_workout").safeParse({ deviceId: "my-whoop", startTs: RUN_TS, sport: "running" }).success).toBe(true);
    expect(payloadSchema("adjust_sleep_bounds").safeParse({ deviceId: "my-whoop", startTs: 1 }).success).toBe(false); // needs a new bound
    expect(payloadSchema("add_workout").safeParse({ startTs: 1, endTs: 2, sport: "yoga", deviceId: "my-whoop" }).success).toBe(false); // deviceId not accepted
    expect(EDIT_KINDS.length).toBe(6);
  });
  it("captureBefore snapshots the real row and errors on a missing target", () => {
    const before = captureBefore(cfg, "delete_workout", { deviceId: "my-whoop", startTs: RUN_TS, sport: "running" }) as any;
    expect(before.sport).toBe("running");
    expect(() => captureBefore(cfg, "delete_workout", { deviceId: "my-whoop", startTs: 1, sport: "nope" })).toThrow(EditTargetError);
  });
  it("renderDiff is human-readable and mentions old and new values", () => {
    const before = captureBefore(cfg, "adjust_sleep_bounds", { deviceId: "my-whoop", startTs: Math.floor(new Date("2026-06-13T03:00:00Z").getTime() / 1000), newEndTs: Math.floor(new Date("2026-06-13T06:00:00Z").getTime() / 1000) });
    const d = renderDiff("adjust_sleep_bounds", { deviceId: "my-whoop", startTs: Math.floor(new Date("2026-06-13T03:00:00Z").getTime() / 1000), newEndTs: Math.floor(new Date("2026-06-13T06:00:00Z").getTime() / 1000) }, before);
    expect(d).toContain("06:00");
    expect(d.toLowerCase()).toContain("end");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- edits-diff` — Expected: FAIL, module not found.

- [ ] **Step 3: Implement `src/edits/kinds.ts`**

```typescript
import { z } from "zod";

export const EDIT_KINDS = ["fix_workout", "delete_workout", "add_workout", "adjust_sleep_bounds", "delete_metric_point", "set_baseline_note"] as const;
export type EditKind = (typeof EDIT_KINDS)[number];

const DAY = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "YYYY-MM-DD");
const workoutKey = { deviceId: z.string().min(1), startTs: z.number().int(), sport: z.string().min(1) };

const schemas: Record<EditKind, z.ZodTypeAny> = {
  fix_workout: z.object({
    ...workoutKey,
    patch: z.object({
      sport: z.string().min(1).optional(), startTs: z.number().int().optional(), endTs: z.number().int().optional(),
      energyKcal: z.number().nullable().optional(), distanceM: z.number().nullable().optional(),
    }).refine((p) => Object.keys(p).length > 0, "patch must not be empty"),
  }).strict(),
  delete_workout: z.object(workoutKey).strict(),
  add_workout: z.object({
    startTs: z.number().int(), endTs: z.number().int(), sport: z.string().min(1),
    energyKcal: z.number().optional(), distanceM: z.number().optional(), notes: z.string().max(500).optional(),
  }).strict().refine((p) => p.endTs > p.startTs, "endTs must be after startTs"),
  adjust_sleep_bounds: z.object({
    deviceId: z.string().min(1), startTs: z.number().int(),
    newStartTs: z.number().int().optional(), newEndTs: z.number().int().optional(),
  }).strict().refine((p) => p.newStartTs !== undefined || p.newEndTs !== undefined, "need newStartTs and/or newEndTs"),
  delete_metric_point: z.object({ deviceId: z.string().min(1), day: DAY, key: z.string().min(1) }).strict(),
  set_baseline_note: z.object({ note: z.string().min(1).max(500), deviceId: z.string().min(1).optional() }).strict(),
};

export function payloadSchema(kind: EditKind): z.ZodTypeAny { return schemas[kind]; }
```

- [ ] **Step 4: Implement `src/edits/diff.ts`**

```typescript
import fs from "node:fs";
import Database from "better-sqlite3";
import type { Config } from "../config.js";
import type { EditKind } from "./kinds.js";

export class EditTargetError extends Error {
  constructor(public code: "target_not_found" | "not_ingested", msg?: string) { super(msg ?? code); }
}

const iso = (ts: number) => new Date(ts * 1000).toISOString().slice(0, 16).replace("T", " ") + "Z";

/** Read-only peek at the mirror for the row an edit targets. null for kinds with no target. */
export function captureBefore(cfg: Pick<Config, "mirrorPath">, kind: EditKind, payload: any): object | null {
  if (kind === "add_workout" || kind === "set_baseline_note") return null;
  if (!fs.existsSync(cfg.mirrorPath)) throw new EditTargetError("not_ingested");
  const db = new Database(cfg.mirrorPath, { readonly: true, fileMustExist: true });
  try {
    let row: unknown;
    if (kind === "fix_workout" || kind === "delete_workout") {
      row = db.prepare("SELECT * FROM workout WHERE deviceId=? AND startTs=? AND sport=?").get(payload.deviceId, payload.startTs, payload.sport);
    } else if (kind === "adjust_sleep_bounds") {
      row = db.prepare("SELECT * FROM sleepSession WHERE deviceId=? AND startTs=?").get(payload.deviceId, payload.startTs);
    } else if (kind === "delete_metric_point") {
      row = db.prepare("SELECT * FROM metricSeries WHERE deviceId=? AND day=? AND key=?").get(payload.deviceId, payload.day, payload.key);
    }
    if (!row) throw new EditTargetError("target_not_found", `${kind}: no matching row in the mirror`);
    return row as object;
  } finally { db.close(); }
}

export function renderDiff(kind: EditKind, payload: any, before: any): string {
  switch (kind) {
    case "delete_workout":
      return `DELETE workout ${before.sport} @ ${iso(before.startTs)} (${before.durationS ? Math.round(before.durationS / 60) + " min" : "?"}, source ${before.source ?? "?"}, ${payload.deviceId})`;
    case "fix_workout": {
      const parts = Object.entries(payload.patch).map(([k, v]) => `${k}: ${JSON.stringify((before as any)[k])} ⇒ ${JSON.stringify(v)}`);
      return `FIX workout ${before.sport} @ ${iso(before.startTs)} (${payload.deviceId}): ${parts.join(", ")}`;
    }
    case "add_workout":
      return `ADD workout ${payload.sport} ${iso(payload.startTs)} → ${iso(payload.endTs)} (source noop-cloud${payload.energyKcal ? `, ${payload.energyKcal} kcal` : ""})`;
    case "adjust_sleep_bounds": {
      const bits: string[] = [];
      if (payload.newStartTs !== undefined) bits.push(`start ${iso(before.startTs)} ⇒ ${iso(payload.newStartTs)}`);
      if (payload.newEndTs !== undefined) bits.push(`end ${iso(before.endTs)} ⇒ ${iso(payload.newEndTs)}`);
      return `ADJUST sleep @ ${iso(before.startTs)} (${payload.deviceId}): ${bits.join(", ")}`;
    }
    case "delete_metric_point":
      return `DELETE metric ${payload.key}=${before.value} on ${payload.day} (${payload.deviceId})`;
    case "set_baseline_note":
      return `NOTE${payload.deviceId ? ` [${payload.deviceId}]` : ""}: ${payload.note}`;
  }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `npm test -- edits-diff` — Expected: 3/3 PASS. Full: `npm test` → 48. Build clean.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: edit kinds — zod payloads, before-snapshot capture, human diffs"
```

---

### Task 3: Overlay computation

**Files:**
- Create: `noop-cloud/src/edits/overlay.ts`
- Test: `noop-cloud/test/overlay.test.ts`

**Interfaces:**
- Consumes: `activeEdits` (Task 1), payload shapes (Task 2).
- Produces:
  - `interface Overlay { sleepBounds: Map<string, { newStartTs?: number; newEndTs?: number; editId: string }>; deletedWorkouts: Set<string>; patchedWorkouts: Map<string, { patch: any; editId: string }>; addedWorkouts: { editId: string; deviceId: "noop-cloud"; startTs: number; endTs: number; sport: string; energyKcal: number | null; distanceM: number | null; notes: string | null }[]; deletedMetricPoints: Set<string>; baselineNotes: { note: string; deviceId: string | null; at: number }[] }`
  - Keys: workouts `"${deviceId}|${startTs}|${sport}"`, sleep `"${deviceId}|${startTs}"`, metric points `"${deviceId}|${day}|${key}"`. Export `workoutKeyOf(deviceId,startTs,sport)`, `sleepKeyOf(deviceId,startTs)`, `pointKeyOf(deviceId,day,key)`.
  - `computeOverlay(cfg: Pick<Config,"serverDbPath">): Overlay` — folds `activeEdits` in seq order (later edits to the same target win).

- [ ] **Step 1: Write the failing test**

`test/overlay.test.ts`:

```typescript
import { describe, it, expect, beforeEach } from "vitest";
import fs from "node:fs"; import path from "node:path";
import { appendJournal, markUndone } from "../src/staging.js";
import { computeOverlay, workoutKeyOf, sleepKeyOf } from "../src/edits/overlay.js";

const dataDir = path.join(process.cwd(), "test/.tmp/overlay");
const cfg = { serverDbPath: path.join(dataDir, "server.sqlite") } as any;
beforeEach(() => { fs.rmSync(dataDir, { recursive: true, force: true }); fs.mkdirSync(dataDir, { recursive: true }); });

describe("overlay", () => {
  it("folds active edits into lookup structures", () => {
    appendJournal(cfg, { editId: "e1", kind: "delete_workout", payloadJSON: JSON.stringify({ deviceId: "my-whoop", startTs: 100, sport: "running" }), beforeJSON: null, rationale: null });
    appendJournal(cfg, { editId: "e2", kind: "adjust_sleep_bounds", payloadJSON: JSON.stringify({ deviceId: "my-whoop", startTs: 200, newEndTs: 999 }), beforeJSON: null, rationale: null });
    appendJournal(cfg, { editId: "e3", kind: "add_workout", payloadJSON: JSON.stringify({ startTs: 300, endTs: 400, sport: "yoga" }), beforeJSON: null, rationale: null });
    const o = computeOverlay(cfg);
    expect(o.deletedWorkouts.has(workoutKeyOf("my-whoop", 100, "running"))).toBe(true);
    expect(o.sleepBounds.get(sleepKeyOf("my-whoop", 200))?.newEndTs).toBe(999);
    expect(o.addedWorkouts[0]).toMatchObject({ deviceId: "noop-cloud", sport: "yoga" });
  });
  it("undone edits leave the overlay", () => {
    const s = appendJournal(cfg, { editId: "e4", kind: "delete_workout", payloadJSON: JSON.stringify({ deviceId: "d", startTs: 1, sport: "s" }), beforeJSON: null, rationale: null });
    const u = appendJournal(cfg, { editId: "u4", kind: "undo", payloadJSON: JSON.stringify({ targetSeq: s }), beforeJSON: null, rationale: null });
    markUndone(cfg, s, u);
    const o = computeOverlay(cfg);
    expect(o.deletedWorkouts.size).toBe(0);
  });
  it("later sleep adjustments to the same session win", () => {
    appendJournal(cfg, { editId: "e5", kind: "adjust_sleep_bounds", payloadJSON: JSON.stringify({ deviceId: "d", startTs: 5, newEndTs: 10 }), beforeJSON: null, rationale: null });
    appendJournal(cfg, { editId: "e6", kind: "adjust_sleep_bounds", payloadJSON: JSON.stringify({ deviceId: "d", startTs: 5, newEndTs: 20 }), beforeJSON: null, rationale: null });
    expect(computeOverlay(cfg).sleepBounds.get(sleepKeyOf("d", 5))?.newEndTs).toBe(20);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- overlay` — Expected: FAIL, module not found.

- [ ] **Step 3: Implement `src/edits/overlay.ts`**

```typescript
import type { Config } from "../config.js";
import { activeEdits } from "../staging.js";

export const workoutKeyOf = (deviceId: string, startTs: number, sport: string) => `${deviceId}|${startTs}|${sport}`;
export const sleepKeyOf = (deviceId: string, startTs: number) => `${deviceId}|${startTs}`;
export const pointKeyOf = (deviceId: string, day: string, key: string) => `${deviceId}|${day}|${key}`;

export interface Overlay {
  sleepBounds: Map<string, { newStartTs?: number; newEndTs?: number; editId: string }>;
  deletedWorkouts: Set<string>;
  patchedWorkouts: Map<string, { patch: any; editId: string }>;
  addedWorkouts: { editId: string; deviceId: "noop-cloud"; startTs: number; endTs: number; sport: string; energyKcal: number | null; distanceM: number | null; notes: string | null }[];
  deletedMetricPoints: Set<string>;
  baselineNotes: { note: string; deviceId: string | null; at: number }[];
}

export function computeOverlay(cfg: Pick<Config, "serverDbPath">): Overlay {
  const o: Overlay = { sleepBounds: new Map(), deletedWorkouts: new Set(), patchedWorkouts: new Map(), addedWorkouts: [], deletedMetricPoints: new Set(), baselineNotes: [] };
  for (const e of activeEdits(cfg)) {
    const p = JSON.parse(e.payloadJSON);
    switch (e.kind) {
      case "delete_workout": o.deletedWorkouts.add(workoutKeyOf(p.deviceId, p.startTs, p.sport)); break;
      case "fix_workout": {
        const k = workoutKeyOf(p.deviceId, p.startTs, p.sport);
        const prev = o.patchedWorkouts.get(k)?.patch ?? {};
        o.patchedWorkouts.set(k, { patch: { ...prev, ...p.patch }, editId: e.editId });
        break;
      }
      case "add_workout":
        o.addedWorkouts.push({ editId: e.editId, deviceId: "noop-cloud", startTs: p.startTs, endTs: p.endTs, sport: p.sport, energyKcal: p.energyKcal ?? null, distanceM: p.distanceM ?? null, notes: p.notes ?? null });
        break;
      case "adjust_sleep_bounds": {
        const k = sleepKeyOf(p.deviceId, p.startTs);
        const prev = o.sleepBounds.get(k) ?? { editId: e.editId };
        o.sleepBounds.set(k, { ...prev, ...(p.newStartTs !== undefined ? { newStartTs: p.newStartTs } : {}), ...(p.newEndTs !== undefined ? { newEndTs: p.newEndTs } : {}), editId: e.editId });
        break;
      }
      case "delete_metric_point": o.deletedMetricPoints.add(pointKeyOf(p.deviceId, p.day, p.key)); break;
      case "set_baseline_note": o.baselineNotes.push({ note: p.note, deviceId: p.deviceId ?? null, at: e.appliedAt }); break;
    }
  }
  return o;
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npm test -- overlay` — 3/3 PASS. Full suite 51. Build clean.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: overlay — fold active journal edits into read-side lookups"
```

---

### Task 4: Scope threading + `propose_edit` / `list_pending` / `edit_journal`

**Files:**
- Create: `noop-cloud/src/tools/writes.ts`
- Modify: `noop-cloud/src/auth.ts` (export `tokenScope`)
- Modify: `noop-cloud/src/mcp.ts` (`buildMcpServer(cfg, scope)`)
- Modify: `noop-cloud/src/server.ts` (detect scope in the /mcp route; pass through)
- Modify: `noop-cloud/src/tools/index.ts` (`registerTools(server, cfg, scope)` → call `registerWriteTools`)
- Test: `noop-cloud/test/tools-writes.test.ts`

**Interfaces:**
- Produces (auth.ts): `tokenScope(cfg: Config, authHeader: string | undefined): "rw" | "ro" | null` (timing-safe; rw checked first).
- Produces (mcp.ts): `buildMcpServer(cfg: Config, scope: "ro" | "rw"): McpServer` — existing callers in tests must pass a scope; the /mcp route passes the detected one.
- Produces (writes.ts): `registerWriteTools(server: McpServer, cfg: Config, scope: "ro" | "rw"): void` registering for ALL scopes: `propose_edit`, `list_pending`, `edit_journal`; and ONLY when `scope === "rw"`: `confirm_edit`, `reject_edit`, `undo_edit` (Task 5 implements those bodies; this task registers propose/list/journal only and leaves a `// Task 5:` marker).
  - `propose_edit(kind, payload, rationale)`: validate kind ∈ EDIT_KINDS and payload via `payloadSchema`; `captureBefore` (structured errors `{ error: "not_ingested" | "target_not_found" }` as tool results, not throws); `renderDiff`; `createProposal` with id `"edit_" + crypto.randomBytes(5).toString("hex")`; returns `{ id, kind, diff, rationale, status: "pending", hint: "confirm_edit requires the read-write credential" }`.
  - `list_pending()`: `{ pending: [{ id, kind, diff, rationale, createdAt }] }`.
  - `edit_journal({ since?: number })`: `{ edits: JournalRow[], latestSeq: number }` (since default 0).
  - Annotations: propose `{ readOnlyHint: false, destructiveHint: false }`; list/journal `{ readOnlyHint: true }`.

- [ ] **Step 1: Write the failing test**

`test/tools-writes.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from "vitest";
import fs from "node:fs"; import path from "node:path"; import http from "node:http";
import { buildNoopbak } from "./fixtures/make-fixture.js";
import { ingestNoopbak } from "../src/ingest.js";
import { createApp } from "../src/server.js";

const dataDir = path.join(process.cwd(), "test/.tmp/writes");
function cfg() { return { dataDir, mirrorPath: path.join(dataDir, "mirror.sqlite"), serverDbPath: path.join(dataDir, "server.sqlite"), maxIngestBytes: 262_144_000, roToken: "ro".padEnd(40, "x"), rwToken: "rw".padEnd(40, "y"), port: 0 } as any; }
const RUN_TS = Math.floor(new Date("2026-06-12T18:00:00Z").getTime() / 1000);

function mcp(port: number, token: string, body: object): Promise<any> {
  return new Promise((resolve) => {
    const payload = JSON.stringify(body);
    const r = http.request({ port, path: "/mcp", method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json", accept: "application/json, text/event-stream" } }, (res) => {
      let d = ""; res.on("data", (c) => (d += c)); res.on("end", () => {
        const line = d.split("\n").find((l) => l.startsWith("data:")) ?? d;
        resolve(JSON.parse(line.replace(/^data:\s*/, "")));
      });
    });
    r.end(payload);
  });
}

beforeAll(() => { fs.rmSync(dataDir, { recursive: true, force: true }); fs.mkdirSync(dataDir, { recursive: true }); const z = path.join(dataDir, "b.noopbak"); buildNoopbak(z); ingestNoopbak(fs.readFileSync(z), cfg()); });

describe("write tools + scope", () => {
  it("ro caller sees propose/list/journal but NOT confirm/reject/undo; rw sees all", async () => {
    const app = createApp(cfg()); const server = app.listen(0); const port = (server.address() as any).port;
    const ro = await mcp(port, cfg().roToken, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    const rw = await mcp(port, cfg().rwToken, { jsonrpc: "2.0", id: 2, method: "tools/list" });
    server.close();
    const roNames = ro.result.tools.map((t: any) => t.name);
    const rwNames = rw.result.tools.map((t: any) => t.name);
    expect(roNames).toContain("propose_edit");
    expect(roNames).not.toContain("confirm_edit");
    expect(rwNames).toContain("confirm_edit");
    expect(rwNames).toContain("undo_edit");
  });
  it("propose_edit validates, snapshots, and stages; list_pending shows it", async () => {
    const app = createApp(cfg()); const server = app.listen(0); const port = (server.address() as any).port;
    const p = await mcp(port, cfg().roToken, { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "propose_edit", arguments: { kind: "delete_workout", payload: { deviceId: "my-whoop", startTs: RUN_TS, sport: "running" }, rationale: "test dup" } } });
    const out = p.result.structuredContent;
    expect(out.status).toBe("pending");
    expect(out.diff).toContain("running");
    const l = await mcp(port, cfg().roToken, { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "list_pending", arguments: {} } });
    server.close();
    expect(l.result.structuredContent.pending.map((x: any) => x.id)).toContain(out.id);
  });
  it("propose_edit on a missing target returns a structured error", async () => {
    const app = createApp(cfg()); const server = app.listen(0); const port = (server.address() as any).port;
    const p = await mcp(port, cfg().roToken, { jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "propose_edit", arguments: { kind: "delete_workout", payload: { deviceId: "my-whoop", startTs: 1, sport: "ghost" }, rationale: "x" } } });
    server.close();
    expect(p.result.structuredContent.error).toBe("target_not_found");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- tools-writes` — Expected: FAIL.

- [ ] **Step 3: `src/auth.ts` — add tokenScope (keep everything else)**

```typescript
export function tokenScope(cfg: Config, authHeader: string | undefined): "rw" | "ro" | null {
  const m = /^Bearer (.+)$/.exec(authHeader ?? "");
  if (!m) return null;
  if (safeEqual(m[1], cfg.rwToken)) return "rw";
  if (safeEqual(m[1], cfg.roToken)) return "ro";
  return null;
}
```

- [ ] **Step 4: `src/mcp.ts` — thread scope**

Change signature to `export function buildMcpServer(cfg: Config, scope: "ro" | "rw"): McpServer` and the registry call to `registerTools(server, cfg, scope);`. Prompts unchanged.

- [ ] **Step 5: `src/server.ts` — detect scope in the /mcp route**

```typescript
// inside createApp, replace the /mcp POST handler's first line:
app.post("/mcp", requireScope(cfg, "ro"), express.json({ limit: "4mb" }), async (req, res) => {
  const scope = tokenScope(cfg, req.header("authorization")) ?? "ro"; // requireScope already vetted it
  const server = buildMcpServer(cfg, scope);
  // ... rest unchanged
```
(add `tokenScope` to the auth import)

- [ ] **Step 6: `src/tools/index.ts` — signature + write tools**

```typescript
import { registerWriteTools } from "./writes.js";
export function registerTools(server: McpServer, cfg: Config, scope: "ro" | "rw"): void {
  registerCoreTools(server, cfg);
  registerQueryTools(server, cfg);
  registerCompareSources(server, cfg);
  registerSearchFetch(server, cfg);
  registerWriteTools(server, cfg, scope);
}
```

- [ ] **Step 7: Implement `src/tools/writes.ts` (propose/list/journal; Task 5 adds the rest)**

```typescript
import crypto from "node:crypto";
import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { Config } from "../config.js";
import { EDIT_KINDS, EditKind, payloadSchema } from "../edits/kinds.js";
import { captureBefore, renderDiff, EditTargetError } from "../edits/diff.js";
import { createProposal, listPending, journalSince } from "../staging.js";

const asTool = (obj: unknown) => ({ content: [{ type: "text" as const, text: JSON.stringify(obj, null, 2) }], structuredContent: obj as Record<string, unknown> });

export function registerWriteTools(server: McpServer, cfg: Config, scope: "ro" | "rw"): void {
  server.registerTool("propose_edit", {
    title: "Propose a data edit",
    description: "Stage a correction (nothing is applied until a human confirms with the read-write credential). Kinds: " + EDIT_KINDS.join(", ") + ". Returns a human-readable diff and the proposal id.",
    inputSchema: {
      kind: z.enum(EDIT_KINDS),
      payload: z.record(z.unknown()).describe("Kind-specific payload; see the kind's schema."),
      rationale: z.string().min(3).max(500).describe("Why this edit is correct — recorded in the audit journal."),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, async (a) => {
    const parsed = payloadSchema(a.kind as EditKind).safeParse(a.payload);
    if (!parsed.success) return asTool({ error: "invalid_payload", detail: parsed.error.issues.map((i) => i.message).join("; ") });
    let before: object | null;
    try { before = captureBefore(cfg, a.kind as EditKind, parsed.data); }
    catch (e) { return asTool({ error: e instanceof EditTargetError ? e.code : "capture_failed" }); }
    const id = "edit_" + crypto.randomBytes(5).toString("hex");
    const diff = renderDiff(a.kind as EditKind, parsed.data, before);
    createProposal(cfg, { id, kind: a.kind, payloadJSON: JSON.stringify(parsed.data), rationale: a.rationale, beforeJSON: before ? JSON.stringify(before) : null, diffText: diff });
    return asTool({ id, kind: a.kind, diff, rationale: a.rationale, status: "pending", hint: "confirm_edit requires the read-write credential" });
  });

  server.registerTool("list_pending", {
    title: "List pending proposals",
    description: "Staged edits awaiting confirm/reject.",
    inputSchema: {},
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async () => asTool({ pending: listPending(cfg).map((p) => ({ id: p.id, kind: p.kind, diff: p.diffText, rationale: p.rationale, createdAt: p.createdAt })) }));

  server.registerTool("edit_journal", {
    title: "Edit journal",
    description: "Append-only audit log of every confirmed edit (and undos). since = last seq you have.",
    inputSchema: { since: z.number().int().min(0).optional() },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async (a) => {
    const edits = journalSince(cfg, a.since ?? 0);
    return asTool({ edits, latestSeq: edits.length ? edits[edits.length - 1].seq : (a.since ?? 0) });
  });

  if (scope === "rw") {
    registerResolutionTools(server, cfg); // Task 5
  }
}

// Task 5 implements: confirm_edit, reject_edit, undo_edit
export function registerResolutionTools(_server: McpServer, _cfg: Config): void {}
```

- [ ] **Step 8: Fix existing test callers of buildMcpServer** — `test/mcp.test.ts` calls go through `createApp` (no direct buildMcpServer callers), so no change expected; if any test imports `buildMcpServer` directly, pass `"ro"`.

- [ ] **Step 9: Run to verify pass**

Run: `npm test` — Expected: 54 passing (51 + 3 new). Build clean.

- [ ] **Step 10: Commit**

```bash
git add -A && git commit -m "feat: scope-threaded MCP + propose_edit/list_pending/edit_journal"
```

---

### Task 5: `confirm_edit` / `reject_edit` / `undo_edit` (rw-only)

**Files:**
- Modify: `noop-cloud/src/tools/writes.ts` (implement `registerResolutionTools`)
- Test: `noop-cloud/test/tools-resolve.test.ts`

**Interfaces:**
- Consumes: `resolveProposal`, `getProposal`, `appendJournal`, `journalSince`, `markUndone` (Task 1).
- Produces tools (rw-registered only):
  - `confirm_edit({ id })`: proposal must be pending → `resolveProposal(confirmed)` → `appendJournal({ editId: id, kind, payloadJSON, beforeJSON, rationale })` → `{ id, seq, applied: true, diff }`. Absent/already-resolved → `{ error: "not_pending" }`. If `appendJournal` throws UNIQUE (editId already journaled) → `{ id, applied: true, note: "already applied" }` (idempotent).
  - `reject_edit({ id })`: pending → rejected → `{ id, rejected: true }`; else `{ error: "not_pending" }`.
  - `undo_edit({ seq })`: journal row must exist, `kind != 'undo'`, `undoneBySeq IS NULL` → append `{ editId: "undo_" + <hex>, kind: "undo", payloadJSON: {targetSeq} }` → `markUndone` → `{ undoneSeq: seq, bySeq }`. Else `{ error: "not_undoable" }`.
  - Annotations: confirm + undo `{ readOnlyHint: false, destructiveHint: true }`; reject `{ readOnlyHint: false, destructiveHint: false }`.

- [ ] **Step 1: Write the failing test**

`test/tools-resolve.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from "vitest";
import fs from "node:fs"; import path from "node:path"; import http from "node:http";
import { buildNoopbak } from "./fixtures/make-fixture.js";
import { ingestNoopbak } from "../src/ingest.js";
import { createApp } from "../src/server.js";

const dataDir = path.join(process.cwd(), "test/.tmp/resolve");
function cfg() { return { dataDir, mirrorPath: path.join(dataDir, "mirror.sqlite"), serverDbPath: path.join(dataDir, "server.sqlite"), maxIngestBytes: 262_144_000, roToken: "ro".padEnd(40, "x"), rwToken: "rw".padEnd(40, "y"), port: 0 } as any; }
const RUN_TS = Math.floor(new Date("2026-06-12T18:00:00Z").getTime() / 1000);

function mcp(port: number, token: string, id: number, name: string, args: object): Promise<any> {
  return new Promise((resolve) => {
    const payload = JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } });
    const r = http.request({ port, path: "/mcp", method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json", accept: "application/json, text/event-stream" } }, (res) => {
      let d = ""; res.on("data", (c) => (d += c)); res.on("end", () => {
        const line = d.split("\n").find((l) => l.startsWith("data:")) ?? d;
        resolve(JSON.parse(line.replace(/^data:\s*/, "")).result.structuredContent);
      });
    });
    r.end(payload);
  });
}

let port = 0; let server: any;
beforeAll(() => {
  fs.rmSync(dataDir, { recursive: true, force: true }); fs.mkdirSync(dataDir, { recursive: true });
  const z = path.join(dataDir, "b.noopbak"); buildNoopbak(z); ingestNoopbak(fs.readFileSync(z), cfg());
  const app = createApp(cfg()); server = app.listen(0); port = (server.address() as any).port;
});

describe("confirm/reject/undo", () => {
  it("full lifecycle: propose → confirm → journal → undo → journal grows, overlay empties", async () => {
    const p = await mcp(port, cfg().roToken, 1, "propose_edit", { kind: "delete_workout", payload: { deviceId: "my-whoop", startTs: RUN_TS, sport: "running" }, rationale: "dup" });
    const c = await mcp(port, cfg().rwToken, 2, "confirm_edit", { id: p.id });
    expect(c.applied).toBe(true); expect(c.seq).toBeGreaterThan(0);
    const c2 = await mcp(port, cfg().rwToken, 3, "confirm_edit", { id: p.id });
    expect(c2.error).toBe("not_pending"); // single-shot resolution
    const j1 = await mcp(port, cfg().rwToken, 4, "edit_journal", {});
    expect(j1.edits.length).toBe(1);
    const u = await mcp(port, cfg().rwToken, 5, "undo_edit", { seq: c.seq });
    expect(u.undoneSeq).toBe(c.seq);
    const j2 = await mcp(port, cfg().rwToken, 6, "edit_journal", {});
    expect(j2.edits.length).toBe(2); // append-only: undo is a new entry
    const u2 = await mcp(port, cfg().rwToken, 7, "undo_edit", { seq: c.seq });
    expect(u2.error).toBe("not_undoable");
  });
  it("reject leaves no journal entry", async () => {
    const p = await mcp(port, cfg().roToken, 8, "propose_edit", { kind: "set_baseline_note", payload: { note: "oura reads low" }, rationale: "baseline" });
    const r = await mcp(port, cfg().rwToken, 9, "reject_edit", { id: p.id });
    expect(r.rejected).toBe(true);
    const j = await mcp(port, cfg().rwToken, 10, "edit_journal", {});
    expect(j.edits.filter((e: any) => e.editId === p.id).length).toBe(0);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- tools-resolve` — Expected: FAIL (confirm_edit not implemented/registered).

- [ ] **Step 3: Implement `registerResolutionTools` in `src/tools/writes.ts`**

```typescript
import { getProposal, resolveProposal, appendJournal, markUndone, journalSince } from "../staging.js"; // extend the existing import

export function registerResolutionTools(server: McpServer, cfg: Config): void {
  server.registerTool("confirm_edit", {
    title: "Confirm a proposed edit",
    description: "Apply a pending proposal to the edit journal + overlay. Requires the read-write credential. The mirror itself is never modified; corrections reach the phone in Phase 3.",
    inputSchema: { id: z.string().min(1) },
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
  }, async (a) => {
    const resolved = resolveProposal(cfg, a.id, "confirmed");
    if (!resolved) {
      const existing = getProposal(cfg, a.id);
      if (existing?.status === "confirmed") return asTool({ id: a.id, applied: true, note: "already applied" });
      return asTool({ error: "not_pending" });
    }
    try {
      const seq = appendJournal(cfg, { editId: resolved.id, kind: resolved.kind, payloadJSON: resolved.payloadJSON, beforeJSON: resolved.beforeJSON, rationale: resolved.rationale });
      return asTool({ id: resolved.id, seq, applied: true, diff: resolved.diffText });
    } catch {
      return asTool({ id: resolved.id, applied: true, note: "already applied" }); // UNIQUE(editId) — idempotent
    }
  });

  server.registerTool("reject_edit", {
    title: "Reject a proposed edit",
    description: "Discard a pending proposal (no journal entry, no data change).",
    inputSchema: { id: z.string().min(1) },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, async (a) => {
    const r = resolveProposal(cfg, a.id, "rejected");
    return asTool(r ? { id: a.id, rejected: true } : { error: "not_pending" });
  });

  server.registerTool("undo_edit", {
    title: "Undo a confirmed edit",
    description: "Reverse a journal entry by appending an undo record (history is never deleted).",
    inputSchema: { seq: z.number().int().min(1) },
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
  }, async (a) => {
    const target = journalSince(cfg, a.seq - 1).find((e) => e.seq === a.seq);
    if (!target || target.kind === "undo" || target.undoneBySeq !== null) return asTool({ error: "not_undoable" });
    const bySeq = appendJournal(cfg, { editId: "undo_" + crypto.randomBytes(5).toString("hex"), kind: "undo", payloadJSON: JSON.stringify({ targetSeq: a.seq }), beforeJSON: null, rationale: null });
    markUndone(cfg, a.seq, bySeq);
    return asTool({ undoneSeq: a.seq, bySeq });
  });
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npm test` — Expected: 56 passing. Build clean.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: confirm/reject/undo — rw-only resolution over the append-only journal"
```

---

### Task 6: Overlay-aware read tools

**Files:**
- Modify: `noop-cloud/src/tools/query.ts` (sleep_summary bounds; workout_summary delete/patch/add; metric_series point deletes)
- Modify: `noop-cloud/src/tools/core.ts` (data_freshness gains `pendingEdits`, `journalSeq`, `baselineNotes`)
- Test: `noop-cloud/test/tools-overlay-reads.test.ts`

**Interfaces:**
- Consumes: `computeOverlay`, key helpers (Task 3), `listPending`, `journalSince` (Task 1).
- Produces (behavioral contract):
  - `sleep_summary`: a session with an overlay bound adjustment returns adjusted `startTs`/`endTs`, recomputed `durationMin`, plus `edited: true, editId`. Unedited sessions unchanged (no `edited` key).
  - `workout_summary`: deleted workouts absent; patched workouts carry patch fields + `edited: true, editId`; added workouts appear with `deviceId: "noop-cloud"`, `family: "cloud"`... **No** — keep `sourceFamily` untouched (Phase-1 contract): added rows get `family: "whoop"`? Wrong either way — added rows carry `deviceId: "noop-cloud"` and `family` computed by `sourceFamily("noop-cloud")` which yields "whoop" today. To avoid misclassification, `workout_summary` sets `family: "cloud" as any` for added rows explicitly and marks `added: true, editId`. (Phase 3 will register the namespace properly; the tool-level label is honest today.)
  - `metric_series`: deleted points absent.
  - `data_freshness`: adds `pendingEdits: number`, `journalSeq: number` (latest seq, 0 if none), `baselineNotes: [{note, deviceId, at}]`.
  - Tool descriptions for sleep_summary/workout_summary/metric_series append: "Reflects confirmed server-side edits; dailyMetric-derived numbers (health_snapshot/compare_sources) update only after the phone applies edits (Phase 3) and re-uploads."

- [ ] **Step 1: Write the failing test**

`test/tools-overlay-reads.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from "vitest";
import fs from "node:fs"; import path from "node:path";
import { buildNoopbak } from "./fixtures/make-fixture.js";
import { ingestNoopbak } from "../src/ingest.js";
import { appendJournal } from "../src/staging.js";
import { sleepSummary, workoutSummary, metricSeries } from "../src/tools/query.js";
import { dataFreshness } from "../src/tools/core.js";

const dataDir = path.join(process.cwd(), "test/.tmp/overlay-reads");
const cfg = { dataDir, mirrorPath: path.join(dataDir, "mirror.sqlite"), serverDbPath: path.join(dataDir, "server.sqlite"), maxIngestBytes: 262_144_000 } as any;
const SLEEP_TS = Math.floor(new Date("2026-06-13T03:00:00Z").getTime() / 1000);
const RUN_TS = Math.floor(new Date("2026-06-12T18:00:00Z").getTime() / 1000);
const NEW_END = Math.floor(new Date("2026-06-13T06:00:00Z").getTime() / 1000);

beforeAll(() => {
  fs.rmSync(dataDir, { recursive: true, force: true }); fs.mkdirSync(dataDir, { recursive: true });
  const z = path.join(dataDir, "b.noopbak"); buildNoopbak(z); ingestNoopbak(fs.readFileSync(z), cfg);
  appendJournal(cfg, { editId: "e_sleep", kind: "adjust_sleep_bounds", payloadJSON: JSON.stringify({ deviceId: "my-whoop", startTs: SLEEP_TS, newEndTs: NEW_END }), beforeJSON: null, rationale: null });
  appendJournal(cfg, { editId: "e_del", kind: "delete_workout", payloadJSON: JSON.stringify({ deviceId: "my-whoop", startTs: RUN_TS, sport: "running" }), beforeJSON: null, rationale: null });
  appendJournal(cfg, { editId: "e_add", kind: "add_workout", payloadJSON: JSON.stringify({ startTs: RUN_TS + 7200, endTs: RUN_TS + 9000, sport: "yoga" }), beforeJSON: null, rationale: null });
  appendJournal(cfg, { editId: "e_pt", kind: "delete_metric_point", payloadJSON: JSON.stringify({ deviceId: "oura-api", day: "2026-06-13", key: "oura_readiness" }), beforeJSON: null, rationale: null });
  appendJournal(cfg, { editId: "e_note", kind: "set_baseline_note", payloadJSON: JSON.stringify({ note: "oura RHR reads ~2bpm high", deviceId: "oura-api" }), beforeJSON: null, rationale: null });
});

describe("overlay-aware reads", () => {
  it("sleep_summary reflects adjusted end + recomputed duration + provenance", () => {
    const s = sleepSummary(cfg, { from: "2026-06-13", to: "2026-06-13" }).sessions.find((x: any) => x.deviceId === "my-whoop");
    expect(s.endTs).toBe(NEW_END);
    expect(s.durationMin).toBe(Math.round((NEW_END - SLEEP_TS) / 60));
    expect(s.edited).toBe(true);
  });
  it("workout_summary hides deleted, shows added with provenance", () => {
    const w = workoutSummary(cfg, { from: "2026-06-11", to: "2026-06-13" });
    expect(w.workouts.find((x: any) => x.sport === "running")).toBeUndefined();
    const added = w.workouts.find((x: any) => x.sport === "yoga");
    expect(added.deviceId).toBe("noop-cloud");
    expect(added.added).toBe(true);
  });
  it("metric_series drops deleted points", () => {
    const r = metricSeries(cfg, { deviceId: "oura-api", key: "oura_readiness", from: "2026-06-10", to: "2026-06-13" });
    expect(r.points.length).toBe(3); // fixture had 4 days
  });
  it("data_freshness reports journal state + notes", () => {
    const f = dataFreshness(cfg) as any;
    expect(f.journalSeq).toBeGreaterThanOrEqual(5);
    expect(f.baselineNotes[0].note).toContain("RHR");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- overlay-reads` — Expected: FAIL (endTs unadjusted, running present, 4 points, no journalSeq).

- [ ] **Step 3: Apply overlay in `src/tools/query.ts`**

```typescript
import { computeOverlay, workoutKeyOf, sleepKeyOf, pointKeyOf } from "../edits/overlay.js";

export function sleepSummary(cfg: Config, args: { from: string; to: string }) {
  if (!fs.existsSync(cfg.mirrorPath)) return { sessions: [], notIngested: true };
  const overlay = computeOverlay(cfg);
  const m = new Mirror(cfg.mirrorPath);
  try {
    const sessions = m.sleepSummary(args).map((s) => {
      const adj = overlay.sleepBounds.get(sleepKeyOf(s.deviceId, s.startTs));
      const startTs = adj?.newStartTs ?? s.startTs;
      const endTs = adj?.newEndTs ?? s.endTs;
      return { ...s, startTs, endTs, startIso: new Date(startTs * 1000).toISOString(), durationMin: Math.round((endTs - startTs) / 60), ...(adj ? { edited: true, editId: adj.editId } : {}) };
    });
    return { sessions };
  } finally { m.close(); }
}

export function workoutSummary(cfg: Config, args: { from: string; to: string }) {
  if (!fs.existsSync(cfg.mirrorPath)) return { workouts: [], notIngested: true };
  const overlay = computeOverlay(cfg);
  const lo = Math.floor(new Date(`${args.from}T00:00:00Z`).getTime() / 1000);
  const hi = Math.floor(new Date(`${args.to}T23:59:59Z`).getTime() / 1000);
  const m = new Mirror(cfg.mirrorPath);
  try {
    const base = m.workoutSummary(args)
      .filter((w) => !overlay.deletedWorkouts.has(workoutKeyOf(w.deviceId, w.startTs, w.sport)))
      .map((w) => {
        const patch = overlay.patchedWorkouts.get(workoutKeyOf(w.deviceId, w.startTs, w.sport));
        const merged = patch ? { ...w, ...patch.patch, edited: true, editId: patch.editId } : w;
        const durationS = (merged as any).endTs && merged.startTs ? (merged as any).endTs - merged.startTs : merged.durationS;
        return { ...merged, startIso: new Date(merged.startTs * 1000).toISOString(), durationMin: durationS != null ? Math.round(durationS / 60) : null };
      });
    const added = overlay.addedWorkouts
      .filter((w) => w.startTs >= lo && w.startTs <= hi)
      .map((w) => ({ deviceId: w.deviceId, family: "cloud" as any, startTs: w.startTs, endTs: w.endTs, sport: w.sport, source: "noop-cloud", durationS: w.endTs - w.startTs, energyKcal: w.energyKcal, distanceM: w.distanceM, startIso: new Date(w.startTs * 1000).toISOString(), durationMin: Math.round((w.endTs - w.startTs) / 60), added: true, editId: w.editId }));
    return { workouts: [...base, ...added].sort((a, b) => a.startTs - b.startTs) };
  } finally { m.close(); }
}

export function metricSeries(cfg: Config, args: { from: string; to: string; deviceId?: string; key?: string }) {
  if (!fs.existsSync(cfg.mirrorPath)) return { points: [], notIngested: true };
  const overlay = computeOverlay(cfg);
  const m = new Mirror(cfg.mirrorPath);
  try { return { points: m.metricSeries(args).filter((p) => !overlay.deletedMetricPoints.has(pointKeyOf(p.deviceId, p.day, p.key))) }; }
  finally { m.close(); }
}
```
Append to the three registered tool descriptions: `" Reflects confirmed server-side edits; dailyMetric-derived numbers update only after Phase-3 phone sync."`

- [ ] **Step 4: `src/tools/core.ts` — data_freshness additions**

```typescript
import { listPending, journalSince } from "../staging.js";
import { computeOverlay } from "../edits/overlay.js";
// inside dataFreshness's returned object (both the notIngested early-return and the normal path):
//   pendingEdits: listPending(cfg).length,
//   journalSeq: (() => { const j = journalSince(cfg, 0); return j.length ? j[j.length - 1].seq : 0; })(),
//   baselineNotes: computeOverlay(cfg).baselineNotes,
```
(server.sqlite exists independently of the mirror, so these fields are correct in both paths.)

- [ ] **Step 5: Run to verify pass**

Run: `npm test` — Expected: 60 passing. Build clean.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: overlay-aware reads — edits reflected with provenance markers"
```

---

### Task 7: `GET /edits?since=<seq>` (Phase-3 pull endpoint)

**Files:**
- Modify: `noop-cloud/src/server.ts` (new route, ro scope, before the error middleware)
- Test: `noop-cloud/test/edits-endpoint.test.ts`

**Interfaces:**
- Produces: `GET /edits?since=<int>` (ro): `{ edits: JournalRow[], latestSeq: number }` — the FULL journal including `undo` rows (the phone replays reversals too). `since` optional/default 0; non-numeric → 400 `{ error: "bad_since" }`.

- [ ] **Step 1: Write the failing test**

`test/edits-endpoint.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from "vitest";
import fs from "node:fs"; import path from "node:path"; import http from "node:http";
import { appendJournal } from "../src/staging.js";
import { createApp } from "../src/server.js";

const dataDir = path.join(process.cwd(), "test/.tmp/edits-ep");
function cfg() { return { dataDir, mirrorPath: path.join(dataDir, "mirror.sqlite"), serverDbPath: path.join(dataDir, "server.sqlite"), maxIngestBytes: 262_144_000, roToken: "ro".padEnd(40, "x"), rwToken: "rw".padEnd(40, "y"), port: 0 } as any; }

function get(port: number, pathq: string, token?: string): Promise<{ status: number; json: any }> {
  return new Promise((resolve) => {
    http.get({ port, path: pathq, headers: token ? { authorization: `Bearer ${token}` } : {} }, (res) => {
      let d = ""; res.on("data", (c) => (d += c)); res.on("end", () => resolve({ status: res.statusCode!, json: d ? JSON.parse(d) : null }));
    });
  });
}

beforeAll(() => {
  fs.rmSync(dataDir, { recursive: true, force: true }); fs.mkdirSync(dataDir, { recursive: true });
  appendJournal(cfg(), { editId: "a", kind: "set_baseline_note", payloadJSON: "{}", beforeJSON: null, rationale: null });
  appendJournal(cfg(), { editId: "b", kind: "undo", payloadJSON: JSON.stringify({ targetSeq: 1 }), beforeJSON: null, rationale: null });
});

describe("GET /edits", () => {
  it("requires auth", async () => {
    const app = createApp(cfg()); const s = app.listen(0); const port = (s.address() as any).port;
    expect((await get(port, "/edits")).status).toBe(401); s.close();
  });
  it("returns the sequenced journal including undo rows, filtered by since", async () => {
    const app = createApp(cfg()); const s = app.listen(0); const port = (s.address() as any).port;
    const all = await get(port, "/edits", cfg().roToken);
    expect(all.json.edits.length).toBe(2);
    expect(all.json.latestSeq).toBe(2);
    const tail = await get(port, "/edits?since=1", cfg().roToken);
    expect(tail.json.edits.map((e: any) => e.editId)).toEqual(["b"]);
    const bad = await get(port, "/edits?since=zzz", cfg().roToken);
    expect(bad.status).toBe(400); s.close();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- edits-endpoint` — Expected: 404s / FAIL.

- [ ] **Step 3: Add the route in `src/server.ts`** (after `/mcp`, before the error middleware)

```typescript
import { journalSince } from "./staging.js";

app.get("/edits", requireScope(cfg, "ro"), (req, res) => {
  const raw = req.query.since;
  const since = raw === undefined ? 0 : Number(raw);
  if (!Number.isInteger(since) || since < 0) return res.status(400).json({ error: "bad_since" });
  const edits = journalSince(cfg, since);
  res.json({ edits, latestSeq: edits.length ? edits[edits.length - 1].seq : since });
});
```

- [ ] **Step 4: Run to verify pass**

Run: `npm test` — Expected: 62 passing. Build clean.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: GET /edits — sequenced journal pull for Phase-3 phone sync"
```

---

### Task 8: README, deploy, live smoke

**Files:**
- Modify: `noop-cloud/README.md` (add "Editing your data (Phase 2)" section)
- Deploy: `fly deploy --ha=false`

- [ ] **Step 1: README section** (append after Tools)

````markdown
## Editing your data (Phase 2)

The AI can *propose* corrections; nothing changes until you confirm with the read-write credential.
The mirror (your uploaded data) is never modified — confirmed edits live in an append-only journal
and an overlay that read tools reflect (marked `edited: true` / `added: true`). Every proposal
records the original row (`before`) and your rationale; `undo_edit` reverses by appending, so the
audit trail is complete forever.

- Read-only callers (routines, cron, shared agents) can `propose_edit`, `list_pending`, `edit_journal`.
- `confirm_edit` / `reject_edit` / `undo_edit` exist **only** for read-write callers — invisible otherwise.
- `GET /edits?since=<seq>` (read token) streams the journal for downstream sync.
- Honesty note: `health_snapshot` / `compare_sources` aggregate the phone's own daily rollups; those
  numbers update after the phone applies your edits (Phase 3) and re-uploads.
````

- [ ] **Step 2: Full suite + build one last time**

Run: `npm test && npm run build` — Expected: 62 passing, clean.

- [ ] **Step 3: Commit + deploy**

```bash
git add -A && git commit -m "docs: Phase-2 gated-writes README section"
fly deploy --ha=false --yes
```
Expected: image builds on Fly's remote builder; machine updates; `https://vk-noop-cloud.fly.dev/healthz` → `{ok:true}`.

- [ ] **Step 4: Live smoke (curl, using .env tokens)**

```bash
source .env; BASE=https://vk-noop-cloud.fly.dev
# ro sees propose but not confirm
curl -s -X POST "$BASE/mcp" -H "Authorization: Bearer $RO_TOKEN" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | grep -c confirm_edit   # expect 0
curl -s -X POST "$BASE/mcp" -H "Authorization: Bearer $RW_TOKEN" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | grep -c confirm_edit   # expect >=1
# journal endpoint
curl -s "$BASE/edits" -H "Authorization: Bearer $RO_TOKEN"
```

- [ ] **Step 5: Ledger the deploy** in `/Users/vk/VKDEV/NOOP/noop/.superpowers/sdd/progress.md`.

---

## Self-Review

**Spec coverage (spec §5 Phase 2 + §6):** staging tables ✅ (T1); propose→diff→confirm/reject ✅ (T2/T4/T5); list_pending/edit_journal/undo ✅ (T4/T5); six edit kinds ✅ (T2); ro-can-stage/rw-applies with tool *invisibility* ✅ (T4/T5 via scope threading); destructive/readOnly annotations ✅; overlay consulted by read tools, mirror pristine ✅ (T6); journal append-only + idempotent + sequenced for Phase 3 ✅ (T1/T5/T7); `/edits?since=` ✅ (T7); deploy ✅ (T8). Honesty constraint (dailyMetric-derived numbers) documented in tool descriptions + README ✅ (T6/T8).

**Placeholder scan:** none — every code step carries complete code. Task 4's `registerResolutionTools` no-op is an explicit, named Task-5 seam, implemented in Task 5 with full code.

**Type consistency:** `ProposalRow`/`JournalRow` (T1) used by T4/T5/T7; overlay keys + `computeOverlay` (T3) consumed in T6 with the same helpers; `buildMcpServer(cfg, scope)` signature change is propagated (mcp.ts, server.ts, tools/index.ts) in one task (T4); `asTool` shape matches Phase 1's envelope.

**Known deltas from Phase 1 the implementers must respect:** suite count grows 41→45→48→51→54→56→60→62; `openServerDb` moves to serverdb.ts with a compatibility re-export from ingest.ts.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-11-noop-cloud-2-gated-writes.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks.

**2. Inline Execution** — executing-plans in this session with checkpoints.
