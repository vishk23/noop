# noop-cloud Phase 2b — Granular Reads + Granular Edit Kinds

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Extends the Phase-2 plan (2026-07-11-noop-cloud-2-gated-writes.md); execute AFTER its Task 7. Phase 2's Task 8 (README/deploy) is SUPERSEDED by this plan's Task 4 — one deploy covers both.

**Goal:** The AI can read the raw evidence (per-second heart rate, stage-by-stage hypnogram, movement) and edit at the same granularity (rewrite a night's stages, delete artifact HR ranges) — so "you were actually asleep until 6am" is provable from data and fixable end-to-end.

**Architecture:** Two new read tools over existing mirror tables (`hrSample`, `sleepSession.stagesJSON`), downsample-windowed to keep responses LLM-sized. Two new edit kinds flowing through the existing propose→confirm→journal→overlay rail; `hr_series` and `sleep_detail` are overlay-aware from day one.

**Tech Stack:** unchanged (SDK 1.29.0, better-sqlite3 12.11.1). Repo `/Users/vk/VKDEV/NOOP/noop-cloud`.

## Global Constraints

- Mirror read-only always; all edit state in server.sqlite; journal append-only (unchanged from Phase 2).
- `hr_series`: max span **7 days** per call (reject wider with `{ error: "span_too_wide" }`); optional `bucketSeconds` (60..3600) returns per-bucket `{ts, avg, min, max, n}`; raw mode caps at **5000 samples** (`truncated: true` + hint to bucket when hit). Multi-source: optional `deviceId`, else all sources, each sample carries `deviceId`/`family`.
- `sleep_detail`: one session by `(deviceId, startTs)`; returns bounds (overlay-adjusted, `edited` marker), `stages` parsed from stagesJSON (`[{start,end,stage}]`, overlay-replaced when an `edit_sleep_stages` edit is active), plus `hrDuringSleep` (bucketed 5-min from hrSample within bounds, same deviceId's family fallback: exact deviceId first, else any source overlapping the window — labeled per sample).
- New edit kinds (total becomes **eight**): `edit_sleep_stages` payload `{ deviceId, startTs, stages: [{start,end,stage}] (1..96 segments, contiguous non-overlapping ascending, stage ∈ awake|light|deep|rem) }`; `delete_hr_range` payload `{ deviceId, fromTs, toTs (toTs>fromTs, span ≤ 6h) }`. Both `.strict()`, both captureBefore (sleep row must exist / count of HR samples in range must be > 0 → else `target_not_found`), human diffs show old→new (stage minutes summary; sample count dropped).
- Overlay: `stageEdits: Map<sleepKey, {stages, editId}>`; `deletedHrRanges: {deviceId, fromTs, toTs, editId}[]`. `hr_series` excludes samples inside deleted ranges (matching deviceId); `sleep_detail` reflects both stage edits and HR deletions; `metric_series`/others unchanged.
- Tool annotations `readOnlyHint: true` for both reads; guard pattern (`notIngested`) on both.
- Fixture additions must keep every existing test green (fixtures gain stagesJSON on one session + denser HR; adjust existing counts ONLY by appending new data that no existing assertion pins — existing hrSample rows are 5/day under oura-api and `hrCoverageDays` asserts 4 days: keep additions inside the same 4 days).

---

### Task 1: Fixture enrichment + `hr_series` / `sleep_detail` read tools

**Files:**
- Modify: `noop-cloud/test/fixtures/make-fixture.ts` (one WHOOP sleep session gets a real stagesJSON; add my-whoop HR samples across the 2026-06-13 night, 5-min cadence 03:00–10:00)
- Create: `noop-cloud/src/tools/granular.ts`
- Modify: `noop-cloud/src/tools/index.ts` (register)
- Test: `noop-cloud/test/tools-granular.test.ts`

**Interfaces:**
- Produces: `hrSeries(cfg, args: { from: string(ISO datetime or YYYY-MM-DD), to: string, deviceId?: string, bucketSeconds?: number })` → `{ samples: [{ts, bpm, deviceId, family}] , truncated?: true }` or `{ buckets: [{ts, avg, min, max, n, deviceId, family}] }`; `{ error: "span_too_wide" }` past 7d; notIngested guard.
- Produces: `sleepDetail(cfg, args: { deviceId: string, startTs: number })` → `{ session: {deviceId, family, startTs, endTs, durationMin, efficiency, restingHr, avgHrv, edited?}, stages: [{start,end,stage}] | null, stagesEdited?: true, hrDuringSleep: [{ts,bpm,deviceId}], notFound?: true }`.
- Produces: `registerGranularTools(server, cfg)` (both `readOnlyHint: true`).
- Mirror gains two methods (Modify `src/mirror.ts`): `hrSamplesRange(opts: {fromTs: number, toTs: number, deviceId?: string, limit: number}): {deviceId: string, ts: number, bpm: number}[]` and `sleepSessionAt(deviceId: string, startTs: number): (SleepRow & { stagesJSON: string | null }) | null`.

- [ ] **Step 1: Failing test** — `test/tools-granular.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from "vitest";
import fs from "node:fs"; import path from "node:path";
import { buildNoopbak } from "./fixtures/make-fixture.js";
import { ingestNoopbak } from "../src/ingest.js";
import { hrSeries, sleepDetail } from "../src/tools/granular.js";

const dataDir = path.join(process.cwd(), "test/.tmp/granular");
const cfg = { dataDir, mirrorPath: path.join(dataDir, "mirror.sqlite"), serverDbPath: path.join(dataDir, "server.sqlite"), maxIngestBytes: 262_144_000 } as any;
const SLEEP_TS = Math.floor(new Date("2026-06-13T03:00:00Z").getTime() / 1000);

beforeAll(() => { fs.rmSync(dataDir, { recursive: true, force: true }); fs.mkdirSync(dataDir, { recursive: true }); const z = path.join(dataDir, "b.noopbak"); buildNoopbak(z); ingestNoopbak(fs.readFileSync(z), cfg); });

describe("granular reads", () => {
  it("hr_series raw returns my-whoop night samples with family", () => {
    const r = hrSeries(cfg, { from: "2026-06-13T03:00:00Z", to: "2026-06-13T10:00:00Z", deviceId: "my-whoop" }) as any;
    expect(r.samples.length).toBeGreaterThanOrEqual(80); // 5-min cadence over 7h
    expect(r.samples[0].family).toBe("whoop");
  });
  it("hr_series buckets aggregate", () => {
    const r = hrSeries(cfg, { from: "2026-06-13T03:00:00Z", to: "2026-06-13T10:00:00Z", deviceId: "my-whoop", bucketSeconds: 3600 }) as any;
    expect(r.buckets.length).toBeGreaterThanOrEqual(6);
    expect(r.buckets[0]).toHaveProperty("avg");
  });
  it("hr_series rejects >7d span", () => {
    expect((hrSeries(cfg, { from: "2026-06-01", to: "2026-06-13" }) as any).error).toBe("span_too_wide");
  });
  it("sleep_detail returns stages + in-sleep HR", () => {
    const r = sleepDetail(cfg, { deviceId: "my-whoop", startTs: SLEEP_TS }) as any;
    expect(r.session.durationMin).toBeGreaterThan(0);
    expect(r.stages.length).toBeGreaterThanOrEqual(3);
    expect(r.hrDuringSleep.length).toBeGreaterThanOrEqual(80);
  });
  it("sleep_detail notFound for a ghost session", () => {
    expect((sleepDetail(cfg, { deviceId: "my-whoop", startTs: 1 }) as any).notFound).toBe(true);
  });
});
```

- [ ] **Step 2: Run to verify FAIL** (`npm test -- tools-granular`).

- [ ] **Step 3: Fixture additions** — in `buildMirrorSqlite` after the existing hr inserts:

```typescript
// Granular night data (2026-06-13, my-whoop): stages on the sleep row + 5-min HR across the night.
const night = tsOf("2026-06-13", 3);
const stages = JSON.stringify([
  { start: night, end: night + 3600, stage: "light" },
  { start: night + 3600, end: night + 10800, stage: "deep" },
  { start: night + 10800, end: night + 18000, stage: "rem" },
  { start: night + 18000, end: night + 25200, stage: "light" },
]);
db.prepare("UPDATE sleepSession SET stagesJSON = ? WHERE deviceId = 'my-whoop' AND startTs = ?").run(stages, night);
for (let t = night; t <= night + 25200; t += 300) hr.run("my-whoop", t, 46 + Math.round(8 * Math.abs(Math.sin(t / 3000))));
```

- [ ] **Step 4: Mirror methods** — append to `src/mirror.ts` class:

```typescript
hrSamplesRange(opts: { fromTs: number; toTs: number; deviceId?: string; limit: number }): { deviceId: string; ts: number; bpm: number }[] {
  const where = ["ts >= ? AND ts <= ?"]; const args: any[] = [opts.fromTs, opts.toTs];
  if (opts.deviceId) { where.push("deviceId = ?"); args.push(opts.deviceId); }
  args.push(opts.limit);
  return this.db.prepare(`SELECT deviceId, ts, bpm FROM hrSample WHERE ${where.join(" AND ")} ORDER BY ts LIMIT ?`).all(...args) as any[];
}
sleepSessionAt(deviceId: string, startTs: number) {
  return (this.db.prepare("SELECT deviceId, startTs, endTs, efficiency, restingHr, avgHrv, userEdited, stagesJSON FROM sleepSession WHERE deviceId = ? AND startTs = ?").get(deviceId, startTs) as any) ?? null;
}
```

- [ ] **Step 5: Implement `src/tools/granular.ts`**

```typescript
import fs from "node:fs";
import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { Config } from "../config.js";
import { Mirror, sourceFamily } from "../mirror.js";
import { computeOverlay, sleepKeyOf } from "../edits/overlay.js";

const asTool = (obj: unknown) => ({ content: [{ type: "text" as const, text: JSON.stringify(obj, null, 2) }], structuredContent: obj as Record<string, unknown> });
const toTs = (s: string, endOfDay = false) => /^\d{4}-\d{2}-\d{2}$/.test(s)
  ? Math.floor(new Date(`${s}T${endOfDay ? "23:59:59" : "00:00:00"}Z`).getTime() / 1000)
  : Math.floor(new Date(s).getTime() / 1000);
const MAX_SPAN_S = 7 * 86_400, RAW_CAP = 5000;

function dropDeleted(samples: { deviceId: string; ts: number; bpm: number }[], ranges: { deviceId: string; fromTs: number; toTs: number }[]) {
  if (!ranges.length) return samples;
  return samples.filter((s) => !ranges.some((r) => r.deviceId === s.deviceId && s.ts >= r.fromTs && s.ts <= r.toTs));
}

export function hrSeries(cfg: Config, args: { from: string; to: string; deviceId?: string; bucketSeconds?: number }) {
  if (!fs.existsSync(cfg.mirrorPath)) return { samples: [], notIngested: true };
  const fromTs = toTs(args.from), toT = toTs(args.to, true);
  if (!Number.isFinite(fromTs) || !Number.isFinite(toT)) return { error: "bad_range" };
  if (toT - fromTs > MAX_SPAN_S) return { error: "span_too_wide", maxDays: 7 };
  const ranges = computeOverlay(cfg).deletedHrRanges;
  const m = new Mirror(cfg.mirrorPath);
  try {
    const raw = dropDeleted(m.hrSamplesRange({ fromTs, toTs: toT, deviceId: args.deviceId, limit: 200_000 }), ranges);
    if (args.bucketSeconds) {
      const b = Math.min(3600, Math.max(60, args.bucketSeconds));
      const byBucket = new Map<string, { ts: number; deviceId: string; sum: number; min: number; max: number; n: number }>();
      for (const s of raw) {
        const key = `${s.deviceId}|${Math.floor(s.ts / b) * b}`;
        const cur = byBucket.get(key) ?? { ts: Math.floor(s.ts / b) * b, deviceId: s.deviceId, sum: 0, min: s.bpm, max: s.bpm, n: 0 };
        cur.sum += s.bpm; cur.min = Math.min(cur.min, s.bpm); cur.max = Math.max(cur.max, s.bpm); cur.n += 1;
        byBucket.set(key, cur);
      }
      const buckets = [...byBucket.values()].sort((a, b2) => a.ts - b2.ts)
        .map((x) => ({ ts: x.ts, avg: Math.round((x.sum / x.n) * 10) / 10, min: x.min, max: x.max, n: x.n, deviceId: x.deviceId, family: sourceFamily(x.deviceId) }));
      return { buckets };
    }
    const capped = raw.slice(0, RAW_CAP);
    return { samples: capped.map((s) => ({ ...s, family: sourceFamily(s.deviceId) })), ...(raw.length > RAW_CAP ? { truncated: true, hint: "pass bucketSeconds to aggregate" } : {}) };
  } finally { m.close(); }
}

export function sleepDetail(cfg: Config, args: { deviceId: string; startTs: number }) {
  if (!fs.existsSync(cfg.mirrorPath)) return { notIngested: true };
  const overlay = computeOverlay(cfg);
  const m = new Mirror(cfg.mirrorPath);
  try {
    const row = m.sleepSessionAt(args.deviceId, args.startTs);
    if (!row) return { notFound: true };
    const adj = overlay.sleepBounds.get(sleepKeyOf(args.deviceId, args.startTs));
    const startTs = adj?.newStartTs ?? row.startTs, endTs = adj?.newEndTs ?? row.endTs;
    const stageEdit = overlay.stageEdits.get(sleepKeyOf(args.deviceId, args.startTs));
    const stages = stageEdit ? stageEdit.stages : (row.stagesJSON ? JSON.parse(row.stagesJSON) : null);
    const hr = dropDeleted(m.hrSamplesRange({ fromTs: startTs, toTs: endTs, deviceId: args.deviceId, limit: RAW_CAP }), overlay.deletedHrRanges);
    const hrAny = hr.length ? hr : dropDeleted(m.hrSamplesRange({ fromTs: startTs, toTs: endTs, limit: RAW_CAP }), overlay.deletedHrRanges);
    return {
      session: { deviceId: row.deviceId, family: sourceFamily(row.deviceId), startTs, endTs, durationMin: Math.round((endTs - startTs) / 60), efficiency: row.efficiency, restingHr: row.restingHr, avgHrv: row.avgHrv, ...(adj ? { edited: true, editId: adj.editId } : {}) },
      stages, ...(stageEdit ? { stagesEdited: true, editId: stageEdit.editId } : {}),
      hrDuringSleep: hrAny.map((s) => ({ ts: s.ts, bpm: s.bpm, deviceId: s.deviceId })),
    };
  } finally { m.close(); }
}

export function registerGranularTools(server: McpServer, cfg: Config): void {
  server.registerTool("hr_series", {
    title: "Heart-rate series",
    description: "Raw or bucketed heart-rate samples for a time range (max 7 days). Use to inspect what actually happened (e.g. verify sleep/wake from HR). Reflects confirmed HR deletions.",
    inputSchema: { from: z.string(), to: z.string(), deviceId: z.string().optional(), bucketSeconds: z.number().int().min(60).max(3600).optional() },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async (a) => asTool(hrSeries(cfg, a)));

  server.registerTool("sleep_detail", {
    title: "Sleep night detail",
    description: "One night's full evidence: bounds, stage-by-stage hypnogram, and in-sleep heart-rate. Reflects confirmed stage edits, bound adjustments, and HR deletions.",
    inputSchema: { deviceId: z.string(), startTs: z.number().int() },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async (a) => asTool(sleepDetail(cfg, a)));
}
```
NOTE: this imports `overlay.deletedHrRanges` / `overlay.stageEdits`, which exist only after Task 2. For THIS task, add both fields to the `Overlay` interface + `computeOverlay` as empty structures (`stageEdits: new Map(), deletedHrRanges: []`) with a `// filled by edit kinds in 2b Task 2` comment — keeps this task self-contained and green.

- [ ] **Step 6: register in `src/tools/index.ts`** (`registerGranularTools(server, cfg);`).

- [ ] **Step 7: Full suite** — existing tests must stay green (fixture additions are within pinned bounds: my-whoop hrSamples are new rows; `hrCoverageDays("oura-api")` untouched). Expected: prior count + 5.

- [ ] **Step 8: Commit** — `feat: granular reads — hr_series + sleep_detail (overlay-aware)`

---

### Task 2: Edit kinds `edit_sleep_stages` + `delete_hr_range`

**Files:**
- Modify: `noop-cloud/src/edits/kinds.ts` (two new kinds; EDIT_KINDS becomes 8)
- Modify: `noop-cloud/src/edits/diff.ts` (captureBefore + renderDiff for both)
- Modify: `noop-cloud/src/edits/overlay.ts` (fill `stageEdits` + `deletedHrRanges`)
- Test: `noop-cloud/test/edits-granular.test.ts`

**Interfaces:**
- `edit_sleep_stages` schema: `{ deviceId: min1, startTs: int, stages: array(1..96 of {start:int,end:int,stage:enum(awake|light|deep|rem)}) }` `.strict()` + refine: ascending, contiguous (`stages[i].end === stages[i+1].start`), every `end > start`.
- `delete_hr_range` schema: `{ deviceId: min1, fromTs: int, toTs: int }` `.strict()` + refine `toTs > fromTs && toTs - fromTs <= 21_600`.
- captureBefore: `edit_sleep_stages` → the sleepSession row (target_not_found if absent); `delete_hr_range` → `{ count }` from `SELECT COUNT(*) FROM hrSample WHERE deviceId=? AND ts BETWEEN ? AND ?` (target_not_found if 0).
- renderDiff: stages → `RESTAGE sleep @ <iso>: light 60m/deep 120m/rem 120m/light 120m ⇒ <new summary>` (compute per-stage minutes from old stagesJSON if present, else "no stages"); hr → `DELETE ${count} HR samples ${iso(fromTs)} → ${iso(toTs)} (${deviceId})`.
- overlay: `edit_sleep_stages` → `stageEdits.set(sleepKeyOf(deviceId,startTs), {stages, editId})` (later wins); `delete_hr_range` → push `{deviceId, fromTs, toTs, editId}`.

- [ ] **Step 1: Failing test** — `test/edits-granular.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from "vitest";
import fs from "node:fs"; import path from "node:path";
import { buildNoopbak } from "./fixtures/make-fixture.js";
import { ingestNoopbak } from "../src/ingest.js";
import { appendJournal } from "../src/staging.js";
import { payloadSchema, EDIT_KINDS } from "../src/edits/kinds.js";
import { captureBefore, renderDiff } from "../src/edits/diff.js";
import { computeOverlay, sleepKeyOf } from "../src/edits/overlay.js";
import { hrSeries, sleepDetail } from "../src/tools/granular.js";

const dataDir = path.join(process.cwd(), "test/.tmp/edits-granular");
const cfg = { dataDir, mirrorPath: path.join(dataDir, "mirror.sqlite"), serverDbPath: path.join(dataDir, "server.sqlite"), maxIngestBytes: 262_144_000 } as any;
const NIGHT = Math.floor(new Date("2026-06-13T03:00:00Z").getTime() / 1000);
const NEW_STAGES = [{ start: NIGHT, end: NIGHT + 10800, stage: "deep" }, { start: NIGHT + 10800, end: NIGHT + 25200, stage: "light" }];

beforeAll(() => { fs.rmSync(dataDir, { recursive: true, force: true }); fs.mkdirSync(dataDir, { recursive: true }); const z = path.join(dataDir, "b.noopbak"); buildNoopbak(z); ingestNoopbak(fs.readFileSync(z), cfg); });

describe("granular edit kinds", () => {
  it("EDIT_KINDS is 8 and schemas validate", () => {
    expect(EDIT_KINDS.length).toBe(8);
    expect(payloadSchema("edit_sleep_stages").safeParse({ deviceId: "my-whoop", startTs: NIGHT, stages: NEW_STAGES }).success).toBe(true);
    expect(payloadSchema("edit_sleep_stages").safeParse({ deviceId: "d", startTs: 1, stages: [{ start: 5, end: 4, stage: "deep" }] }).success).toBe(false);
    expect(payloadSchema("delete_hr_range").safeParse({ deviceId: "my-whoop", fromTs: NIGHT, toTs: NIGHT + 30000 }).success).toBe(false); // >6h
  });
  it("captureBefore + renderDiff for both kinds", () => {
    const b1 = captureBefore(cfg, "edit_sleep_stages", { deviceId: "my-whoop", startTs: NIGHT, stages: NEW_STAGES }) as any;
    expect(b1.stagesJSON).toBeTruthy();
    expect(renderDiff("edit_sleep_stages", { deviceId: "my-whoop", startTs: NIGHT, stages: NEW_STAGES }, b1)).toContain("deep");
    const b2 = captureBefore(cfg, "delete_hr_range", { deviceId: "my-whoop", fromTs: NIGHT, toTs: NIGHT + 3600 }) as any;
    expect(b2.count).toBeGreaterThan(0);
    expect(renderDiff("delete_hr_range", { deviceId: "my-whoop", fromTs: NIGHT, toTs: NIGHT + 3600 }, b2)).toMatch(/DELETE \d+ HR/);
  });
  it("journal entries flow into overlay and granular reads", () => {
    appendJournal(cfg, { editId: "g1", kind: "edit_sleep_stages", payloadJSON: JSON.stringify({ deviceId: "my-whoop", startTs: NIGHT, stages: NEW_STAGES }), beforeJSON: null, rationale: null });
    appendJournal(cfg, { editId: "g2", kind: "delete_hr_range", payloadJSON: JSON.stringify({ deviceId: "my-whoop", fromTs: NIGHT, toTs: NIGHT + 3599 }), beforeJSON: null, rationale: null });
    const o = computeOverlay(cfg);
    expect(o.stageEdits.get(sleepKeyOf("my-whoop", NIGHT))?.stages.length).toBe(2);
    expect(o.deletedHrRanges.length).toBe(1);
    const d = sleepDetail(cfg, { deviceId: "my-whoop", startTs: NIGHT }) as any;
    expect(d.stagesEdited).toBe(true);
    expect(d.stages.length).toBe(2);
    const hr = hrSeries(cfg, { from: "2026-06-13T03:00:00Z", to: "2026-06-13T10:00:00Z", deviceId: "my-whoop" }) as any;
    const inRange = hr.samples.filter((s: any) => s.ts >= NIGHT && s.ts <= NIGHT + 3599);
    expect(inRange.length).toBe(0); // deleted range excluded
  });
});
```

- [ ] **Step 2: FAIL run.**
- [ ] **Step 3: kinds.ts** — extend `EDIT_KINDS`, add both schemas with the refines above (stage enum via `z.enum(["awake","light","deep","rem"])`; contiguity refine loops pairs).
- [ ] **Step 4: diff.ts** — `captureBefore` cases (`edit_sleep_stages` → sleepSession row; `delete_hr_range` → `{count}` via COUNT query, throw target_not_found on 0); `renderDiff` cases with stage-minute summaries: helper `stageSummary(stages)` → `"light 60m/deep 120m/…"` (merge repeated stages by summing).
- [ ] **Step 5: overlay.ts** — fill the two structures in the switch (replacing the Task-1 placeholders' comment).
- [ ] **Step 6: Full suite green (prior + 3); build clean.**
- [ ] **Step 7: Commit** — `feat: granular edit kinds — edit_sleep_stages + delete_hr_range`

---

### Task 3: End-to-end lifecycle test through the live MCP surface

**Files:**
- Test: `noop-cloud/test/tools-granular-e2e.test.ts`

**Interfaces:** none new — this pins the full loop the feature exists for.

- [ ] **Step 1: Write the test** (propose edit_sleep_stages via ro → confirm via rw → sleep_detail reflects → undo via rw → sleep_detail reverts; same HTTP harness as test/tools-resolve.test.ts — copy its `mcp()` helper verbatim):

```typescript
import { describe, it, expect, beforeAll } from "vitest";
import fs from "node:fs"; import path from "node:path"; import http from "node:http";
import { buildNoopbak } from "./fixtures/make-fixture.js";
import { ingestNoopbak } from "../src/ingest.js";
import { createApp } from "../src/server.js";

const dataDir = path.join(process.cwd(), "test/.tmp/granular-e2e");
function cfg() { return { dataDir, mirrorPath: path.join(dataDir, "mirror.sqlite"), serverDbPath: path.join(dataDir, "server.sqlite"), maxIngestBytes: 262_144_000, roToken: "ro".padEnd(40, "x"), rwToken: "rw".padEnd(40, "y"), port: 0 } as any; }
const NIGHT = Math.floor(new Date("2026-06-13T03:00:00Z").getTime() / 1000);

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

describe("granular edit full loop over MCP", () => {
  it("propose(ro) → confirm(rw) → sleep_detail reflects → undo(rw) → reverts", async () => {
    const stages = [{ start: NIGHT, end: NIGHT + 12600, stage: "deep" }, { start: NIGHT + 12600, end: NIGHT + 25200, stage: "light" }];
    const p = await mcp(port, cfg().roToken, 1, "propose_edit", { kind: "edit_sleep_stages", payload: { deviceId: "my-whoop", startTs: NIGHT, stages }, rationale: "HR shows deep sleep until 6:30, band misread movement" });
    expect(p.status).toBe("pending");
    expect(p.diff).toContain("deep");
    const c = await mcp(port, cfg().rwToken, 2, "confirm_edit", { id: p.id });
    expect(c.applied).toBe(true);
    const d1 = await mcp(port, cfg().roToken, 3, "sleep_detail", { deviceId: "my-whoop", startTs: NIGHT });
    expect(d1.stagesEdited).toBe(true);
    expect(d1.stages.length).toBe(2);
    const u = await mcp(port, cfg().rwToken, 4, "undo_edit", { seq: c.seq });
    expect(u.undoneSeq).toBe(c.seq);
    const d2 = await mcp(port, cfg().roToken, 5, "sleep_detail", { deviceId: "my-whoop", startTs: NIGHT });
    expect(d2.stagesEdited).toBeUndefined();
    expect(d2.stages.length).toBe(4); // fixture's original hypnogram
  });
});
```

- [ ] **Step 2: Run (expect PASS if Tasks 1-2 are correct — this is an integration pin, not TDD-new-code). Full suite green.**
- [ ] **Step 3: Commit** — `test: granular edit full loop (propose→confirm→read→undo) over live MCP`

---

### Task 4: README + deploy + live smoke (supersedes Phase-2 Task 8)

- [ ] **Step 1:** README: add Phase-2 "Editing your data" section from the Phase-2 plan's Task 8 text, PLUS a "Granular evidence & edits" paragraph naming hr_series / sleep_detail / edit_sleep_stages / delete_hr_range and the 3am-vs-6am example.
- [ ] **Step 2:** `npm test && npm run build` — all green.
- [ ] **Step 3:** Commit `docs: Phase-2 + granular editing README`; then `fly deploy --ha=false --yes`.
- [ ] **Step 4: Live smoke** (`.env` tokens): ro tools/list contains hr_series+sleep_detail+propose_edit, NOT confirm_edit; rw contains confirm_edit; `GET /edits` 200; propose+confirm+undo one edit_sleep_stages round-trip against the fixture data currently on the server; `data_freshness` shows journalSeq ≥ 2.
- [ ] **Step 5:** Ledger the deploy in `/Users/vk/VKDEV/NOOP/noop/.superpowers/sdd/progress.md`.

---

## Self-Review

**Coverage vs the user's ask:** read any day at sensor granularity (hr_series 7d-windowed, sleep_detail full night) ✅; reason from evidence (both tools' descriptions steer that use) ✅; edit duration/stages/HR — adjust_sleep_bounds (P2) + edit_sleep_stages + delete_hr_range ✅; full audit loop (same propose/confirm/journal/undo rail) ✅; write-back seam (journal entries carry kind+payload+before for Phase-3 apply; stages align with the app's userEdited protection) ✅.
**Placeholder scan:** Task 1 Step 5's overlay placeholder is explicit and filled by Task 2 (named seam, same pattern as P2 T4→T5). No TBDs.
**Type consistency:** `Overlay.stageEdits`/`deletedHrRanges` names consistent across Tasks 1/2; `hrSamplesRange`/`sleepSessionAt` signatures match call sites; sleepKeyOf reused; EDIT_KINDS length assertions updated (6→8) — NOTE for implementers: `test/edits-diff.test.ts` asserts `EDIT_KINDS.length).toBe(6)` from Phase 2 Task 2 — Task 2 of THIS plan must update that assertion to 8 in the same commit.
