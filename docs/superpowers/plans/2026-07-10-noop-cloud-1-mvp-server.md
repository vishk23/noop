# noop-cloud Phase-1 MVP Server — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A self-hostable remote MCP server that mirrors the NOOP phone database (uploaded as a `.noopbak`) and exposes read-only biometrics tools to Claude/ChatGPT/agents over Streamable HTTP, deployed on a single Fly.io machine, with a scheduled morning report.

**Architecture:** One Node/TypeScript process behind Fly's HTTPS proxy. `POST /ingest` (rw bearer) accepts a `.noopbak` ZIP, validates it, and atomically swaps it into `/data/mirror.sqlite`. `POST /mcp` (ro bearer) is a **stateless** Streamable HTTP MCP endpoint whose tools open `mirror.sqlite` read-only. `/data/server.sqlite` holds only an ingest log in Phase 1. A GitHub Actions cron calls the Anthropic Messages API (MCP connector, ro token) and pushes the report to ntfy. No writes, no OAuth, no sync-back in this phase.

**Tech Stack:** TypeScript 5.6, Node 20, Express 4, `@modelcontextprotocol/sdk` **pinned 1.29.0**, `better-sqlite3` (native, pinned), `adm-zip`, `zod`, `vitest`. Fly.io (1 machine + 1 volume, WAL SQLite, autostop). Docker deploy.

## Global Constraints

- **MCP SDK pinned to exactly `1.29.0`** (`"@modelcontextprotocol/sdk": "1.29.0"`, no `^`). Do NOT use the 2.0.0-beta line. Rationale: the 2026-07-28 stateless spec revision is still an RC; 1.29.x is the supported stable line.
- **`better-sqlite3` pinned exact** (`"better-sqlite3": "11.10.0"`, no `^`) — native binding; a floating range risks an ABI mismatch on the Fly builder. `npm rebuild better-sqlite3` is the fix if the prebuilt binding mismatches Node 20.
- **Stateless MCP transport**: every `/mcp` request constructs a fresh `McpServer` + `StreamableHTTPServerTransport({ sessionIdGenerator: undefined })`. No session store — a Fly autostop between requests must not break a session.
- **The mirror is opened READ-ONLY always** (`new Database(path, { readonly: true, fileMustExist: true })`). Server code never writes to `mirror.sqlite`. Server-owned state lives only in `server.sqlite`.
- **`deviceId` is a *source* discriminator, not a physical device.** The same calendar day legitimately has rows under multiple `deviceId`s. Source families for Phase 1: WHOOP = any id that is NOT `apple-health` and NOT `oura-api` (straps use ids like `my-whoop`, plus derived `<id>-noop`); Oura = `oura-api`; Apple = `apple-health`. Never assume one row per day.
- **Two static bearer tokens** from env: `RO_TOKEN` (read; `/mcp`) and `RW_TOKEN` (ingest; `/ingest`). Compare with `crypto.timingSafeEqual`. `rw` implies `ro`. Tokens are ≥32 bytes; never logged.
- **Ingest hard limit**: reject bodies over `MAX_INGEST_BYTES` (default 250 MB). Validate the inner SQLite by magic bytes (`SQLite format 3\0`) + `PRAGMA quick_check`. Reject a foreign DB (no `grdb_migrations` table).
- **No secrets in git.** `.env` is gitignored; `.env.example` documents keys. Fly secrets via `fly secrets set`.
- **License/voice:** new repo, MIT license, neutral third-person README. This is a standalone sibling repo at `/Users/vk/VKDEV/NOOP/noop-cloud` — NOT inside the NOOP tree, its own git.

---

### Task 1: Repo scaffold, config, and `/healthz`

**Files:**
- Create: `noop-cloud/package.json`
- Create: `noop-cloud/tsconfig.json`
- Create: `noop-cloud/vitest.config.ts`
- Create: `noop-cloud/.gitignore`
- Create: `noop-cloud/.env.example`
- Create: `noop-cloud/src/config.ts`
- Create: `noop-cloud/src/server.ts`
- Test: `noop-cloud/test/healthz.test.ts`

**Interfaces:**
- Produces: `loadConfig(): Config` where `Config = { port: number; dataDir: string; mirrorPath: string; serverDbPath: string; roToken: string; rwToken: string; maxIngestBytes: number }`.
- Produces: `createApp(cfg: Config): express.Express` — the Express app (routes added in later tasks), with `GET /healthz` returning `{ ok: true }`.

- [ ] **Step 1: Initialize the repo and pinned dependencies**

```bash
mkdir -p /Users/vk/VKDEV/NOOP/noop-cloud && cd /Users/vk/VKDEV/NOOP/noop-cloud
git init -q
```

Create `package.json`:

```json
{
  "name": "noop-cloud",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "license": "MIT",
  "engines": { "node": ">=20" },
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "start": "node dist/server.js",
    "dev": "tsx watch src/server.ts",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "1.29.0",
    "adm-zip": "0.5.16",
    "better-sqlite3": "11.10.0",
    "express": "^4.21.2",
    "zod": "^3.23.8"
  },
  "devDependencies": {
    "@types/adm-zip": "^0.5.5",
    "@types/better-sqlite3": "^7.6.11",
    "@types/express": "^4.17.21",
    "@types/node": "^20.14.0",
    "tsx": "^4.19.0",
    "typescript": "^5.6.0",
    "vitest": "^2.1.0"
  }
}
```

- [ ] **Step 2: Add tsconfig, vitest config, gitignore, env template**

`tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true,
    "declaration": false,
    "sourceMap": true
  },
  "include": ["src"]
}
```

`vitest.config.ts`:

```typescript
import { defineConfig } from "vitest/config";
export default defineConfig({ test: { include: ["test/**/*.test.ts"], testTimeout: 20000 } });
```

`.gitignore`:

```
node_modules/
dist/
.env
data/
*.sqlite
*.sqlite-wal
*.sqlite-shm
test/.tmp/
```

`.env.example`:

```
PORT=8080
DATA_DIR=./data
RO_TOKEN=replace-with-32+-byte-random-read-token
RW_TOKEN=replace-with-32+-byte-random-write-token
MAX_INGEST_BYTES=262144000
```

- [ ] **Step 3: Write the failing test for config + `/healthz`**

`test/healthz.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import request from "node:http";
import { loadConfig } from "../src/config.js";
import { createApp } from "../src/server.js";

describe("scaffold", () => {
  it("loadConfig throws when RO_TOKEN missing", () => {
    const prev = process.env.RO_TOKEN;
    delete process.env.RO_TOKEN;
    expect(() => loadConfig()).toThrow(/RO_TOKEN/);
    if (prev !== undefined) process.env.RO_TOKEN = prev;
  });

  it("GET /healthz returns ok", async () => {
    process.env.RO_TOKEN = "ro-token-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    process.env.RW_TOKEN = "rw-token-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const app = createApp(loadConfig());
    const server = app.listen(0);
    const port = (server.address() as any).port;
    const body = await new Promise<string>((resolve, reject) => {
      request.get(`http://127.0.0.1:${port}/healthz`, (res) => {
        let d = ""; res.on("data", (c) => (d += c)); res.on("end", () => resolve(d));
      }).on("error", reject);
    });
    server.close();
    expect(JSON.parse(body)).toEqual({ ok: true });
  });
});
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `npm install && npm test`
Expected: FAIL — `Cannot find module '../src/config.js'`.

- [ ] **Step 5: Implement `src/config.ts`**

```typescript
import path from "node:path";

export interface Config {
  port: number;
  dataDir: string;
  mirrorPath: string;
  serverDbPath: string;
  roToken: string;
  rwToken: string;
  maxIngestBytes: number;
}

function required(name: string): string {
  const v = process.env[name];
  if (!v || v.length < 16) throw new Error(`${name} must be set (>=16 chars)`);
  return v;
}

export function loadConfig(): Config {
  const dataDir = process.env.DATA_DIR ?? "./data";
  return {
    port: Number(process.env.PORT ?? 8080),
    dataDir,
    mirrorPath: path.join(dataDir, "mirror.sqlite"),
    serverDbPath: path.join(dataDir, "server.sqlite"),
    roToken: required("RO_TOKEN"),
    rwToken: required("RW_TOKEN"),
    maxIngestBytes: Number(process.env.MAX_INGEST_BYTES ?? 262_144_000),
  };
}
```

- [ ] **Step 6: Implement `src/server.ts`**

```typescript
import express from "express";
import fs from "node:fs";
import { Config, loadConfig } from "./config.js";

export function createApp(cfg: Config): express.Express {
  fs.mkdirSync(cfg.dataDir, { recursive: true });
  const app = express();
  app.get("/healthz", (_req, res) => res.json({ ok: true }));
  return app;
}

// Entry point (ignored by tests, which import createApp directly).
if (process.argv[1] && process.argv[1].endsWith("server.js")) {
  const cfg = loadConfig();
  createApp(cfg).listen(cfg.port, () => console.log(`noop-cloud on :${cfg.port}`));
}
```

- [ ] **Step 7: Run tests + build to verify pass**

Run: `npm test && npm run build`
Expected: PASS (2 tests); `dist/` compiles with no errors.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "chore: scaffold noop-cloud (config + /healthz + pinned deps)"
```

---

### Task 2: Bearer auth middleware (ro/rw scopes)

**Files:**
- Create: `noop-cloud/src/auth.ts`
- Test: `noop-cloud/test/auth.test.ts`

**Interfaces:**
- Consumes: `Config` (`roToken`, `rwToken`) from Task 1.
- Produces: `requireScope(cfg: Config, scope: "ro" | "rw"): express.RequestHandler`. `rw` token satisfies both scopes; `ro` token satisfies only `ro`. Missing/malformed/incorrect → 401 JSON `{ error: "unauthorized" }`. Uses `crypto.timingSafeEqual`.

- [ ] **Step 1: Write the failing test**

`test/auth.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import express from "express";
import http from "node:http";
import { requireScope } from "../src/auth.js";

const cfg = { roToken: "ro".padEnd(40, "x"), rwToken: "rw".padEnd(40, "y") } as any;

function call(handlerScope: "ro" | "rw", header?: string): Promise<number> {
  const app = express();
  app.get("/p", requireScope(cfg, handlerScope), (_r, res) => res.json({ ok: true }));
  const server = app.listen(0);
  const port = (server.address() as any).port;
  return new Promise((resolve) => {
    http.get({ port, path: "/p", headers: header ? { authorization: header } : {} }, (res) => {
      server.close(); resolve(res.statusCode!);
    });
  });
}

describe("requireScope", () => {
  it("401 with no header", async () => expect(await call("ro")).toBe(401));
  it("401 with wrong token", async () => expect(await call("ro", "Bearer nope")).toBe(401));
  it("ro token satisfies ro scope", async () => expect(await call("ro", `Bearer ${cfg.roToken}`)).toBe(200));
  it("rw token satisfies ro scope", async () => expect(await call("ro", `Bearer ${cfg.rwToken}`)).toBe(200));
  it("ro token does NOT satisfy rw scope", async () => expect(await call("rw", `Bearer ${cfg.roToken}`)).toBe(401));
  it("rw token satisfies rw scope", async () => expect(await call("rw", `Bearer ${cfg.rwToken}`)).toBe(200));
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- auth`
Expected: FAIL — `Cannot find module '../src/auth.js'`.

- [ ] **Step 3: Implement `src/auth.ts`**

```typescript
import crypto from "node:crypto";
import type { RequestHandler } from "express";
import type { Config } from "./config.js";

function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a), bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return crypto.timingSafeEqual(ab, bb);
}

export function requireScope(cfg: Config, scope: "ro" | "rw"): RequestHandler {
  return (req, res, next) => {
    const h = req.header("authorization") ?? "";
    const m = /^Bearer (.+)$/.exec(h);
    if (!m) return res.status(401).json({ error: "unauthorized" });
    const token = m[1];
    const isRw = safeEqual(token, cfg.rwToken);
    const isRo = safeEqual(token, cfg.roToken);
    const ok = scope === "rw" ? isRw : isRo || isRw;
    if (!ok) return res.status(401).json({ error: "unauthorized" });
    next();
  };
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npm test -- auth`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: bearer auth middleware with ro/rw scopes"
```

---

### Task 3: Test fixtures — a GRDB-shaped mirror + a `.noopbak`

**Files:**
- Create: `noop-cloud/test/fixtures/make-fixture.ts`
- Test: `noop-cloud/test/fixtures/make-fixture.test.ts`

**Interfaces:**
- Produces: `buildMirrorSqlite(path: string): void` — writes a SQLite file with the mirror schema and multi-source rows (WHOOP `my-whoop`, `oura-api`, `apple-health`) across days `2026-06-10..2026-06-13`, including a `grdb_migrations` table (origin marker).
- Produces: `buildNoopbak(path: string): void` — a ZIP with entry `noop-backup.sqlite` (the mirror bytes) first. Also `buildNoopbakFrom(sqlitePath, zipPath)`.
- Schema (subset sufficient for Phase-1 tools), tables + keys: `grdb_migrations(identifier TEXT)`, `hrSample(deviceId,ts,bpm)`, `dailyMetric(deviceId,day,totalSleepMin,efficiency,restingHr,avgHrv,recovery,strain,spo2Pct,skinTempDevC,respRateBpm,steps,activeKcalEst)`, `sleepSession(deviceId,startTs,endTs,efficiency,restingHr,avgHrv,stagesJSON,userEdited,startTsAdjusted)`, `workout(deviceId,startTs,sport,endTs,source,durationS,energyKcal,distanceM)`, `metricSeries(deviceId,day,key,value)`, `appleDaily(deviceId,day,steps,restingHr)`, `pairedDevice(id,brand,model,sourceKind)`.

- [ ] **Step 1: Write the failing test**

`test/fixtures/make-fixture.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from "vitest";
import fs from "node:fs";
import path from "node:path";
import Database from "better-sqlite3";
import AdmZip from "adm-zip";
import { buildMirrorSqlite, buildNoopbak } from "./make-fixture.js";

const tmp = path.join(process.cwd(), "test/.tmp");
beforeAll(() => fs.mkdirSync(tmp, { recursive: true }));

describe("fixtures", () => {
  it("mirror has multi-source dailyMetric rows and grdb_migrations", () => {
    const p = path.join(tmp, "m.sqlite");
    buildMirrorSqlite(p);
    const db = new Database(p, { readonly: true });
    const sources = db.prepare("SELECT DISTINCT deviceId FROM dailyMetric ORDER BY deviceId").all().map((r: any) => r.deviceId);
    expect(sources).toContain("oura-api");
    expect(sources).toContain("apple-health");
    expect(sources.some((s: string) => s !== "oura-api" && s !== "apple-health")).toBe(true);
    expect(db.prepare("SELECT count(*) c FROM grdb_migrations").get() as any).toHaveProperty("c");
    db.close();
  });

  it("noopbak is a zip whose FIRST entry is noop-backup.sqlite", () => {
    const p = path.join(tmp, "b.noopbak");
    buildNoopbak(p);
    const entries = new AdmZip(p).getEntries();
    expect(entries[0].entryName).toBe("noop-backup.sqlite");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- make-fixture`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `test/fixtures/make-fixture.ts`**

```typescript
import Database from "better-sqlite3";
import AdmZip from "adm-zip";
import fs from "node:fs";

const DAYS = ["2026-06-10", "2026-06-11", "2026-06-12", "2026-06-13"];
const tsOf = (day: string, h = 3) => Math.floor(new Date(`${day}T0${h}:00:00Z`).getTime() / 1000);

export function buildMirrorSqlite(target: string): void {
  if (fs.existsSync(target)) fs.rmSync(target);
  const db = new Database(target);
  db.pragma("journal_mode = WAL");
  db.exec(`
    CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY);
    CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, bpm INTEGER, PRIMARY KEY(deviceId, ts));
    CREATE TABLE dailyMetric (deviceId TEXT, day TEXT, totalSleepMin INTEGER, efficiency REAL,
      restingHr REAL, avgHrv REAL, recovery REAL, strain REAL, spo2Pct REAL, skinTempDevC REAL,
      respRateBpm REAL, steps INTEGER, activeKcalEst REAL, PRIMARY KEY(deviceId, day));
    CREATE TABLE sleepSession (deviceId TEXT, startTs INTEGER, endTs INTEGER, efficiency REAL,
      restingHr REAL, avgHrv REAL, stagesJSON TEXT, userEdited INTEGER DEFAULT 0,
      startTsAdjusted INTEGER, PRIMARY KEY(deviceId, startTs));
    CREATE TABLE workout (deviceId TEXT, startTs INTEGER, sport TEXT, endTs INTEGER, source TEXT,
      durationS REAL, energyKcal REAL, distanceM REAL, PRIMARY KEY(deviceId, startTs, sport));
    CREATE TABLE metricSeries (deviceId TEXT, day TEXT, key TEXT, value REAL, PRIMARY KEY(deviceId, day, key));
    CREATE TABLE appleDaily (deviceId TEXT, day TEXT, steps INTEGER, restingHr REAL, PRIMARY KEY(deviceId, day));
    CREATE TABLE pairedDevice (id TEXT PRIMARY KEY, brand TEXT, model TEXT, sourceKind TEXT);
  `);
  db.prepare("INSERT INTO grdb_migrations VALUES (?)").run("v25-oura-raw");
  const pd = db.prepare("INSERT INTO pairedDevice VALUES (?,?,?,?)");
  pd.run("my-whoop", "WHOOP", "5.0", "strap");
  pd.run("oura-api", "Oura", "Oura (cloud)", "cloudImport");
  pd.run("apple-health", "Apple", "Apple Health", "appleHealth");

  const dm = db.prepare(`INSERT INTO dailyMetric
    (deviceId,day,totalSleepMin,efficiency,restingHr,avgHrv,recovery,strain,spo2Pct,skinTempDevC,respRateBpm,steps,activeKcalEst)
    VALUES (@deviceId,@day,@totalSleepMin,@efficiency,@restingHr,@avgHrv,@recovery,@strain,@spo2Pct,@skinTempDevC,@respRateBpm,@steps,@activeKcalEst)`);
  const base = (deviceId: string, day: string, o: Partial<any>) => ({
    deviceId, day, totalSleepMin: 420, efficiency: 90, restingHr: 52, avgHrv: 65, recovery: null,
    strain: null, spo2Pct: 97, skinTempDevC: -0.1, respRateBpm: 14.5, steps: 8000, activeKcalEst: 500, ...o,
  });
  for (const day of DAYS) {
    // WHOOP is the scored source: recovery/strain present.
    dm.run(base("my-whoop", day, { restingHr: 51, avgHrv: 70, recovery: 66, strain: 12.5 }));
    // Oura cloud: honest data, recovery/strain null; slightly different RHR/HRV.
    dm.run(base("oura-api", day, { restingHr: 53, avgHrv: 62 }));
    // Apple: steps only-ish.
    dm.run(base("apple-health", day, { restingHr: 54, avgHrv: null, steps: 8200 }));
  }
  const ss = db.prepare(`INSERT INTO sleepSession
    (deviceId,startTs,endTs,efficiency,restingHr,avgHrv,stagesJSON,userEdited,startTsAdjusted)
    VALUES (?,?,?,?,?,?,?,?,?)`);
  for (const day of DAYS) {
    ss.run("my-whoop", tsOf(day, 3), tsOf(day, 3) + 25200, 90, 51, 70, null, 0, null);
    ss.run("oura-api", tsOf(day, 3) + 60, tsOf(day, 3) + 25000, 88, 53, 62, null, 0, null);
  }
  const wo = db.prepare(`INSERT INTO workout (deviceId,startTs,sport,endTs,source,durationS,energyKcal,distanceM)
    VALUES (?,?,?,?,?,?,?,?)`);
  wo.run("my-whoop", tsOf("2026-06-12", 18), "running", tsOf("2026-06-12", 18) + 1800, "whoop", 1800, 320, 5000);
  wo.run("oura-api", tsOf("2026-06-11", 17), "walking", tsOf("2026-06-11", 17) + 2400, "oura", 2400, 180, 3000);

  const ms = db.prepare("INSERT INTO metricSeries VALUES (?,?,?,?)");
  for (const day of DAYS) {
    ms.run("oura-api", day, "ref_sleep_score", 82);
    ms.run("oura-api", day, "oura_readiness", 78);
  }
  const hr = db.prepare("INSERT INTO hrSample VALUES (?,?,?)");
  for (const day of DAYS) for (let i = 0; i < 5; i++) hr.run("oura-api", tsOf(day, 3) + i * 300, 55 + i);
  db.close();
}

export function buildNoopbakFrom(sqlitePath: string, zipPath: string): void {
  if (fs.existsSync(zipPath)) fs.rmSync(zipPath);
  const zip = new AdmZip();
  zip.addFile("noop-backup.sqlite", fs.readFileSync(sqlitePath)); // DB entry FIRST
  zip.writeZip(zipPath);
}

export function buildNoopbak(zipPath: string): void {
  const tmpSqlite = zipPath + ".src.sqlite";
  buildMirrorSqlite(tmpSqlite);
  buildNoopbakFrom(tmpSqlite, zipPath);
  fs.rmSync(tmpSqlite);
  for (const ext of ["-wal", "-shm"]) if (fs.existsSync(tmpSqlite + ext)) fs.rmSync(tmpSqlite + ext);
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npm test -- make-fixture`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "test: fixture builders for mirror sqlite + .noopbak"
```

---

### Task 4: Mirror read layer

**Files:**
- Create: `noop-cloud/src/mirror.ts`
- Test: `noop-cloud/test/mirror.test.ts`

**Interfaces:**
- Consumes: fixtures from Task 3.
- Produces: `class Mirror` opened read-only, methods:
  - `sourceFamily(deviceId: string): "whoop" | "oura" | "apple"` (module fn `sourceFamily`).
  - `sources(): { deviceId: string; family: string; brand: string | null; latestDay: string | null }[]`
  - `dailyMetrics(opts: { deviceId?: string; from: string; to: string }): DailyMetricRow[]`
  - `sleepSummary(opts: { from: string; to: string }): SleepRow[]`
  - `workoutSummary(opts: { from: string; to: string }): WorkoutRow[]`
  - `metricSeries(opts: { deviceId?: string; key?: string; from: string; to: string }): MetricPointRow[]`
  - `latestDataDay(): string | null` (max day across `dailyMetric`)
  - `hrCoverageDays(deviceId: string): number`
  - `close(): void`
- Produces types `DailyMetricRow`, `SleepRow`, `WorkoutRow`, `MetricPointRow` (plain interfaces mirroring the columns; `deviceId` + `family` included on each).

- [ ] **Step 1: Write the failing test**

`test/mirror.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from "vitest";
import fs from "node:fs"; import path from "node:path";
import { buildMirrorSqlite } from "./fixtures/make-fixture.js";
import { Mirror, sourceFamily } from "../src/mirror.js";

const p = path.join(process.cwd(), "test/.tmp/mirror-read.sqlite");
beforeAll(() => { fs.mkdirSync(path.dirname(p), { recursive: true }); buildMirrorSqlite(p); });

describe("Mirror", () => {
  it("classifies source families", () => {
    expect(sourceFamily("oura-api")).toBe("oura");
    expect(sourceFamily("apple-health")).toBe("apple");
    expect(sourceFamily("my-whoop")).toBe("whoop");
  });
  it("lists sources with latest day", () => {
    const m = new Mirror(p);
    const s = m.sources();
    expect(s.find((x) => x.deviceId === "oura-api")?.latestDay).toBe("2026-06-13");
    m.close();
  });
  it("filters dailyMetrics by source and range", () => {
    const m = new Mirror(p);
    const rows = m.dailyMetrics({ deviceId: "oura-api", from: "2026-06-11", to: "2026-06-12" });
    expect(rows.length).toBe(2);
    expect(rows[0].family).toBe("oura");
    m.close();
  });
  it("reports latest data day across sources", () => {
    const m = new Mirror(p); expect(m.latestDataDay()).toBe("2026-06-13"); m.close();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- mirror`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `src/mirror.ts`**

```typescript
import Database from "better-sqlite3";

export type Family = "whoop" | "oura" | "apple";
export function sourceFamily(deviceId: string): Family {
  if (deviceId === "oura-api") return "oura";
  if (deviceId === "apple-health") return "apple";
  return "whoop";
}

export interface DailyMetricRow {
  deviceId: string; family: Family; day: string;
  totalSleepMin: number | null; efficiency: number | null; restingHr: number | null;
  avgHrv: number | null; recovery: number | null; strain: number | null; spo2Pct: number | null;
  skinTempDevC: number | null; respRateBpm: number | null; steps: number | null; activeKcalEst: number | null;
}
export interface SleepRow { deviceId: string; family: Family; startTs: number; endTs: number; efficiency: number | null; restingHr: number | null; avgHrv: number | null; userEdited: number; }
export interface WorkoutRow { deviceId: string; family: Family; startTs: number; endTs: number; sport: string; source: string | null; durationS: number | null; energyKcal: number | null; distanceM: number | null; }
export interface MetricPointRow { deviceId: string; family: Family; day: string; key: string; value: number; }

const withFamily = <T extends { deviceId: string }>(r: T) => ({ ...r, family: sourceFamily(r.deviceId) });

export class Mirror {
  private db: Database.Database;
  constructor(path: string) { this.db = new Database(path, { readonly: true, fileMustExist: true }); }
  close(): void { this.db.close(); }

  sources() {
    const rows = this.db.prepare(`
      SELECT d.deviceId, MAX(d.day) AS latestDay, p.brand AS brand
      FROM dailyMetric d LEFT JOIN pairedDevice p ON p.id = d.deviceId
      GROUP BY d.deviceId ORDER BY d.deviceId`).all() as any[];
    return rows.map((r) => ({ deviceId: r.deviceId, family: sourceFamily(r.deviceId), brand: r.brand ?? null, latestDay: r.latestDay ?? null }));
  }
  dailyMetrics(opts: { deviceId?: string; from: string; to: string }): DailyMetricRow[] {
    const where = ["day >= ? AND day <= ?"]; const args: any[] = [opts.from, opts.to];
    if (opts.deviceId) { where.push("deviceId = ?"); args.push(opts.deviceId); }
    return (this.db.prepare(`SELECT * FROM dailyMetric WHERE ${where.join(" AND ")} ORDER BY day, deviceId`).all(...args) as any[]).map(withFamily);
  }
  sleepSummary(opts: { from: string; to: string }): SleepRow[] {
    const lo = Math.floor(new Date(`${opts.from}T00:00:00Z`).getTime() / 1000);
    const hi = Math.floor(new Date(`${opts.to}T23:59:59Z`).getTime() / 1000);
    return (this.db.prepare(`SELECT deviceId,startTs,endTs,efficiency,restingHr,avgHrv,userEdited FROM sleepSession WHERE startTs >= ? AND startTs <= ? ORDER BY startTs`).all(lo, hi) as any[]).map(withFamily);
  }
  workoutSummary(opts: { from: string; to: string }): WorkoutRow[] {
    const lo = Math.floor(new Date(`${opts.from}T00:00:00Z`).getTime() / 1000);
    const hi = Math.floor(new Date(`${opts.to}T23:59:59Z`).getTime() / 1000);
    return (this.db.prepare(`SELECT deviceId,startTs,endTs,sport,source,durationS,energyKcal,distanceM FROM workout WHERE startTs >= ? AND startTs <= ? ORDER BY startTs`).all(lo, hi) as any[]).map(withFamily);
  }
  metricSeries(opts: { deviceId?: string; key?: string; from: string; to: string }): MetricPointRow[] {
    const where = ["day >= ? AND day <= ?"]; const args: any[] = [opts.from, opts.to];
    if (opts.deviceId) { where.push("deviceId = ?"); args.push(opts.deviceId); }
    if (opts.key) { where.push("key = ?"); args.push(opts.key); }
    return (this.db.prepare(`SELECT deviceId,day,key,value FROM metricSeries WHERE ${where.join(" AND ")} ORDER BY day, key`).all(...args) as any[]).map(withFamily);
  }
  latestDataDay(): string | null { return (this.db.prepare("SELECT MAX(day) AS d FROM dailyMetric").get() as any)?.d ?? null; }
  hrCoverageDays(deviceId: string): number { return (this.db.prepare("SELECT COUNT(DISTINCT date(ts,'unixepoch')) AS c FROM hrSample WHERE deviceId = ?").get(deviceId) as any).c; }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npm test -- mirror`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: read-only mirror query layer (multi-source aware)"
```

---

### Task 5: Ingest pipeline and `POST /ingest`

**Files:**
- Create: `noop-cloud/src/ingest.ts`
- Modify: `noop-cloud/src/server.ts` (add `/ingest` route + server.sqlite ingest log)
- Test: `noop-cloud/test/ingest.test.ts`

**Interfaces:**
- Consumes: `Config`, `requireScope` (rw), fixtures.
- Produces: `ingestNoopbak(buf: Buffer, cfg: Config): { ok: true; bytes: number; latestDay: string | null }` — validates and atomically swaps into `cfg.mirrorPath`. Throws `IngestError` (with `.code`) on: `too_large`, `bad_zip`, `no_sqlite_entry`, `bad_magic`, `quick_check_failed`, `foreign_db`.
- Produces: `openServerDb(cfg): Database` creating `ingestLog(id INTEGER PK, receivedAt INTEGER, bytes INTEGER, latestDay TEXT)`.
- Produces: `latestIngest(cfg): { receivedAt: number; bytes: number; latestDay: string | null } | null`.
- Route: `POST /ingest` (rw), `express.raw({ type: "*/*", limit })`, returns 200 `{ ok, bytes, latestDay }` or 4xx `{ error: code }`.

- [ ] **Step 1: Write the failing test**

`test/ingest.test.ts`:

```typescript
import { describe, it, expect, beforeEach } from "vitest";
import fs from "node:fs"; import path from "node:path"; import Database from "better-sqlite3"; import AdmZip from "adm-zip";
import { buildNoopbak } from "./fixtures/make-fixture.js";
import { ingestNoopbak, latestIngest, IngestError } from "../src/ingest.js";

const dataDir = path.join(process.cwd(), "test/.tmp/ingest");
const cfg = () => ({ dataDir, mirrorPath: path.join(dataDir, "mirror.sqlite"), serverDbPath: path.join(dataDir, "server.sqlite"), maxIngestBytes: 262_144_000 } as any);
beforeEach(() => { fs.rmSync(dataDir, { recursive: true, force: true }); fs.mkdirSync(dataDir, { recursive: true }); });

describe("ingest", () => {
  it("accepts a valid .noopbak and swaps the mirror", () => {
    const zip = path.join(dataDir, "in.noopbak"); buildNoopbak(zip);
    const r = ingestNoopbak(fs.readFileSync(zip), cfg());
    expect(r.ok).toBe(true); expect(r.latestDay).toBe("2026-06-13");
    const db = new Database(cfg().mirrorPath, { readonly: true });
    expect((db.prepare("SELECT COUNT(*) c FROM dailyMetric").get() as any).c).toBeGreaterThan(0); db.close();
    expect(latestIngest(cfg())?.latestDay).toBe("2026-06-13");
  });
  it("rejects oversized", () => {
    const c = cfg(); c.maxIngestBytes = 10;
    expect(() => ingestNoopbak(Buffer.alloc(100), c)).toThrow(IngestError);
  });
  it("rejects a zip with no sqlite entry", () => {
    const z = new AdmZip(); z.addFile("notes.txt", Buffer.from("hi"));
    try { ingestNoopbak(z.toBuffer(), cfg()); expect.fail("should throw"); }
    catch (e: any) { expect(e.code).toBe("no_sqlite_entry"); }
  });
  it("rejects a foreign sqlite (no grdb_migrations)", () => {
    const foreign = path.join(dataDir, "f.sqlite"); const db = new Database(foreign); db.exec("CREATE TABLE x(a)"); db.close();
    const z = new AdmZip(); z.addFile("noop-backup.sqlite", fs.readFileSync(foreign));
    try { ingestNoopbak(z.toBuffer(), cfg()); expect.fail("should throw"); }
    catch (e: any) { expect(e.code).toBe("foreign_db"); }
  });
  it("does not corrupt an existing mirror when the new upload is invalid", () => {
    const zip = path.join(dataDir, "ok.noopbak"); buildNoopbak(zip); ingestNoopbak(fs.readFileSync(zip), cfg());
    try { ingestNoopbak(Buffer.from("not a zip"), cfg()); } catch { /* expected */ }
    const db = new Database(cfg().mirrorPath, { readonly: true });
    expect((db.prepare("SELECT COUNT(*) c FROM dailyMetric").get() as any).c).toBeGreaterThan(0); db.close();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- ingest`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `src/ingest.ts`**

```typescript
import fs from "node:fs"; import path from "node:path"; import crypto from "node:crypto";
import Database from "better-sqlite3"; import AdmZip from "adm-zip";
import type { Config } from "./config.js";

export class IngestError extends Error { constructor(public code: string, msg?: string) { super(msg ?? code); } }
const SQLITE_MAGIC = Buffer.from("SQLite format 3 ", "binary");

export function openServerDb(cfg: Pick<Config, "serverDbPath">): Database.Database {
  const db = new Database(cfg.serverDbPath);
  db.pragma("journal_mode = WAL");
  db.exec("CREATE TABLE IF NOT EXISTS ingestLog (id INTEGER PRIMARY KEY AUTOINCREMENT, receivedAt INTEGER, bytes INTEGER, latestDay TEXT)");
  return db;
}
export function latestIngest(cfg: Pick<Config, "serverDbPath">) {
  const db = openServerDb(cfg);
  const r = db.prepare("SELECT receivedAt, bytes, latestDay FROM ingestLog ORDER BY id DESC LIMIT 1").get() as any;
  db.close();
  return r ?? null;
}

export function ingestNoopbak(buf: Buffer, cfg: Pick<Config, "dataDir" | "mirrorPath" | "serverDbPath" | "maxIngestBytes">): { ok: true; bytes: number; latestDay: string | null } {
  if (buf.length > cfg.maxIngestBytes) throw new IngestError("too_large", `body ${buf.length} > ${cfg.maxIngestBytes}`);
  let zip: AdmZip;
  try { zip = new AdmZip(buf); } catch { throw new IngestError("bad_zip"); }
  const entry = zip.getEntries().find((e) => e.entryName.endsWith(".sqlite"));
  if (!entry) throw new IngestError("no_sqlite_entry");
  const sqliteBytes = entry.getData();
  if (!sqliteBytes.subarray(0, SQLITE_MAGIC.length).equals(SQLITE_MAGIC)) throw new IngestError("bad_magic");

  // Stage to a temp file, validate, then atomically rename into place.
  fs.mkdirSync(cfg.dataDir, { recursive: true });
  const staged = path.join(cfg.dataDir, `.staged-${crypto.randomBytes(6).toString("hex")}.sqlite`);
  fs.writeFileSync(staged, sqliteBytes);
  try {
    const sdb = new Database(staged, { readonly: true });
    try {
      const qc = sdb.pragma("quick_check", { simple: true });
      if (qc !== "ok") throw new IngestError("quick_check_failed", String(qc));
      const hasGrdb = sdb.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='grdb_migrations'").get();
      if (!hasGrdb) throw new IngestError("foreign_db");
      var latestDay = (sdb.prepare("SELECT MAX(day) d FROM dailyMetric").get() as any)?.d ?? null;
    } finally { sdb.close(); }
    // Atomic swap: rename staged -> mirror (same filesystem). Remove stale WAL/SHM sidecars.
    for (const ext of ["-wal", "-shm"]) { const s = cfg.mirrorPath + ext; if (fs.existsSync(s)) fs.rmSync(s); }
    fs.renameSync(staged, cfg.mirrorPath);
  } catch (e) {
    if (fs.existsSync(staged)) fs.rmSync(staged);
    throw e;
  }
  const db = openServerDb(cfg);
  db.prepare("INSERT INTO ingestLog (receivedAt, bytes, latestDay) VALUES (?,?,?)").run(Math.floor(Date.now() / 1000), buf.length, latestDay);
  db.close();
  return { ok: true, bytes: buf.length, latestDay };
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npm test -- ingest`
Expected: PASS (5 tests).

- [ ] **Step 5: Wire the `/ingest` route in `src/server.ts`**

Replace `createApp` in `src/server.ts` with:

```typescript
import express from "express";
import fs from "node:fs";
import { Config, loadConfig } from "./config.js";
import { requireScope } from "./auth.js";
import { ingestNoopbak, IngestError } from "./ingest.js";

export function createApp(cfg: Config): express.Express {
  fs.mkdirSync(cfg.dataDir, { recursive: true });
  const app = express();
  app.get("/healthz", (_req, res) => res.json({ ok: true }));

  app.post("/ingest", requireScope(cfg, "rw"),
    express.raw({ type: "*/*", limit: cfg.maxIngestBytes }),
    (req, res) => {
      try {
        const out = ingestNoopbak(req.body as Buffer, cfg);
        res.json(out);
      } catch (e) {
        if (e instanceof IngestError) return res.status(400).json({ error: e.code });
        console.error("ingest error", e);
        res.status(500).json({ error: "ingest_failed" });
      }
    });

  return app;
}
```

(keep the `if (process.argv[1]...)` entry block from Task 1)

- [ ] **Step 6: Add an HTTP-level ingest test**

Append to `test/ingest.test.ts`:

```typescript
import http from "node:http"; import { createApp } from "../src/server.js";
it("POST /ingest requires rw and swaps the mirror", async () => {
  process.env.RO_TOKEN = "ro".padEnd(40, "x"); process.env.RW_TOKEN = "rw".padEnd(40, "y");
  const c = cfg(); c.roToken = process.env.RO_TOKEN; c.rwToken = process.env.RW_TOKEN; c.port = 0;
  const zip = path.join(dataDir, "http.noopbak"); buildNoopbak(zip); const body = fs.readFileSync(zip);
  const app = createApp(c); const server = app.listen(0); const port = (server.address() as any).port;
  const status = await new Promise<number>((resolve) => {
    const r = http.request({ port, path: "/ingest", method: "POST", headers: { authorization: `Bearer ${c.rwToken}`, "content-type": "application/octet-stream" } }, (res) => { res.resume(); res.on("end", () => resolve(res.statusCode!)); });
    r.end(body);
  });
  server.close(); expect(status).toBe(200);
});
```

- [ ] **Step 7: Run to verify pass**

Run: `npm test -- ingest && npm run build`
Expected: PASS (6 tests); build clean.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: /ingest — validate + atomic-swap .noopbak into mirror.sqlite"
```

---

### Task 6: MCP stateless transport, tool registry, and prompts

**Files:**
- Create: `noop-cloud/src/mcp.ts`
- Create: `noop-cloud/src/tools/index.ts`
- Modify: `noop-cloud/src/server.ts` (mount `/mcp`, ro scope)
- Test: `noop-cloud/test/mcp.test.ts`

**Interfaces:**
- Consumes: `Config`, `Mirror`, `requireScope`.
- Produces: `buildMcpServer(cfg: Config): McpServer` — a fresh server with all tools + prompts registered. Tools open a `Mirror` per call and `close()` it in a `finally`.
- Produces: `registerTools(server: McpServer, cfg: Config): void` (Task 7-10 add tool files, each exporting `register<Name>(server, cfg)`; `registerTools` calls them).
- Produces: prompts `morning_report`, `corroborate_sources`, `find_messy_data` (each returns a `messages` array seeding the agent).
- Route: `POST /mcp` (ro) constructs a fresh transport (`sessionIdGenerator: undefined`) + server per request; `DELETE`/`GET /mcp` → 405.
- **Note:** verify exact import paths against the installed `@modelcontextprotocol/sdk@1.29.0` (`node -e "console.log(require.resolve('@modelcontextprotocol/sdk/server/mcp.js'))"`). If a path differs, adjust — the API shape (`McpServer`, `registerTool`, `registerPrompt`, `StreamableHTTPServerTransport`, `server.connect`, `transport.handleRequest`) is stable in 1.29.x.

- [ ] **Step 1: Write the failing test (MCP list-tools over HTTP)**

`test/mcp.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import fs from "node:fs"; import path from "node:path"; import http from "node:http";
import { buildNoopbak } from "./fixtures/make-fixture.js";
import { ingestNoopbak } from "../src/ingest.js";
import { createApp } from "../src/server.js";

const dataDir = path.join(process.cwd(), "test/.tmp/mcp");
function cfg() { return { dataDir, mirrorPath: path.join(dataDir, "mirror.sqlite"), serverDbPath: path.join(dataDir, "server.sqlite"), maxIngestBytes: 262_144_000, roToken: "ro".padEnd(40, "x"), rwToken: "rw".padEnd(40, "y"), port: 0 } as any; }

function mcpCall(port: number, token: string, body: object): Promise<{ status: number; json: any }> {
  return new Promise((resolve) => {
    const payload = JSON.stringify(body);
    const r = http.request({ port, path: "/mcp", method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json", accept: "application/json, text/event-stream" } }, (res) => {
      let d = ""; res.on("data", (c) => (d += c)); res.on("end", () => {
        // Streamable HTTP may reply as SSE (`data: {json}`) or plain JSON.
        const line = d.split("\n").find((l) => l.startsWith("data:")) ?? d;
        const txt = line.replace(/^data:\s*/, "");
        resolve({ status: res.statusCode!, json: txt ? JSON.parse(txt) : null });
      });
    });
    r.end(payload);
  });
}

describe("/mcp", () => {
  it("401 without ro token", async () => {
    fs.rmSync(dataDir, { recursive: true, force: true }); fs.mkdirSync(dataDir, { recursive: true });
    const zip = path.join(dataDir, "b.noopbak"); buildNoopbak(zip); ingestNoopbak(fs.readFileSync(zip), cfg());
    const app = createApp(cfg()); const server = app.listen(0); const port = (server.address() as any).port;
    const { status } = await mcpCall(port, "wrong", { jsonrpc: "2.0", id: 1, method: "tools/list" });
    server.close(); expect(status).toBe(401);
  });
  it("lists registered tools", async () => {
    const app = createApp(cfg()); const server = app.listen(0); const port = (server.address() as any).port;
    const { json } = await mcpCall(port, cfg().roToken, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    server.close();
    const names = (json.result?.tools ?? []).map((t: any) => t.name);
    expect(names).toContain("data_freshness");
    expect(names).toContain("health_snapshot");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- mcp`
Expected: FAIL — `src/mcp.js` missing.

- [ ] **Step 3: Implement `src/tools/index.ts` (registry stub)**

```typescript
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { Config } from "../config.js";
import { registerCoreTools } from "./core.js";

export function registerTools(server: McpServer, cfg: Config): void {
  registerCoreTools(server, cfg); // health_snapshot + data_freshness (Task 7)
  // Task 8: registerQueryTools(server, cfg)
  // Task 9: registerCompareSources(server, cfg)
  // Task 10: registerSearchFetch(server, cfg)
}
```

- [ ] **Step 4: Implement `src/mcp.ts`**

```typescript
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { Config } from "./config.js";
import { registerTools } from "./tools/index.js";

export function buildMcpServer(cfg: Config): McpServer {
  const server = new McpServer({ name: "noop-cloud", version: "0.1.0" });

  server.registerPrompt("morning_report", {
    title: "Morning report",
    description: "Draft a plain-English morning briefing from the last few days of biometrics.",
  }, () => ({
    messages: [{ role: "user", content: { type: "text", text:
      "Using the noop-cloud tools, write my morning report. Call data_freshness first and state the mirror age. " +
      "Then summarize the last 3 days: recovery/strain (WHOOP), sleep (duration, efficiency), resting HR and HRV trend, " +
      "and any workouts. Use compare_sources to flag where WHOOP, Oura, and Apple disagree by more than ~10%. " +
      "Keep it under 200 words, concrete, no medical advice." } }],
  }));

  server.registerPrompt("corroborate_sources", {
    title: "Corroborate sources",
    description: "Cross-check WHOOP vs Oura vs Apple for a date range and surface disagreements.",
  }, () => ({
    messages: [{ role: "user", content: { type: "text", text:
      "Call compare_sources for the last 14 days. List days where resting HR, HRV, or sleep duration differ by more than 10% " +
      "across sources, and say which source looks like the outlier. Note any per-source baseline offsets." } }],
  }));

  server.registerPrompt("find_messy_data", {
    title: "Find messy data",
    description: "Scan recent data for likely-mislogged workouts or implausible values.",
  }, () => ({
    messages: [{ role: "user", content: { type: "text", text:
      "Call workout_summary and metric_series for the last 30 days. Flag workouts with implausible duration/distance/energy, " +
      "duplicate workouts across sources on the same day, and daily values that break trend. Do not change anything — just list findings." } }],
  }));

  registerTools(server, cfg);
  return server;
}
```

- [ ] **Step 5: Mount `/mcp` in `src/server.ts`**

Add to `createApp` (before `return app`):

```typescript
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { buildMcpServer } from "./mcp.js";

// ... inside createApp, after /ingest:
app.post("/mcp", requireScope(cfg, "ro"), express.json({ limit: "4mb" }), async (req, res) => {
  const server = buildMcpServer(cfg);
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on("close", () => { transport.close(); server.close(); });
  try {
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
  } catch (e) {
    console.error("mcp error", e);
    if (!res.headersSent) res.status(500).json({ jsonrpc: "2.0", error: { code: -32603, message: "internal error" }, id: null });
  }
});
app.all("/mcp", (_req, res) => res.status(405).json({ error: "method_not_allowed" }));
```

- [ ] **Step 6: Run to verify pass**

Run: `npm test -- mcp && npm run build`
Expected: PASS (2 tests) once Task 7's `core.ts` exists. If `core.js` is not yet created, temporarily stub `registerCoreTools` to a no-op that registers a `data_freshness` returning `{}`; Task 7 fills it in. (Prefer implementing Task 7 Step 3 before running this.)

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: stateless Streamable HTTP /mcp endpoint + prompts + tool registry"
```

---

### Task 7: Core tools — `health_snapshot` + `data_freshness`

**Files:**
- Create: `noop-cloud/src/tools/core.ts`
- Test: `noop-cloud/test/tools-core.test.ts`

**Interfaces:**
- Consumes: `Mirror`, `latestIngest`, `Config`.
- Produces: `registerCoreTools(server: McpServer, cfg: Config): void`.
  - `data_freshness` (no args) → `{ mirrorAgeSeconds, lastIngestAt, latestDataDay, sources: [{deviceId, family, latestDay}] }`.
  - `health_snapshot` (args `{ days?: number }`, default 3) → per-day, per-family roll-up of recovery/strain/sleep/restingHr/avgHrv for the most recent `days`.
- Each tool handler returns `{ content: [{ type: "text", text: <json string> }], structuredContent: <obj> }`.

- [ ] **Step 1: Write the failing test**

`test/tools-core.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from "vitest";
import fs from "node:fs"; import path from "node:path";
import { buildNoopbak } from "./fixtures/make-fixture.js";
import { ingestNoopbak } from "../src/ingest.js";
import { dataFreshness, healthSnapshot } from "../src/tools/core.js";

const dataDir = path.join(process.cwd(), "test/.tmp/tools-core");
const cfg = { dataDir, mirrorPath: path.join(dataDir, "mirror.sqlite"), serverDbPath: path.join(dataDir, "server.sqlite"), maxIngestBytes: 262_144_000 } as any;
beforeAll(() => { fs.rmSync(dataDir, { recursive: true, force: true }); fs.mkdirSync(dataDir, { recursive: true }); const z = path.join(dataDir, "b.noopbak"); buildNoopbak(z); ingestNoopbak(fs.readFileSync(z), cfg); });

describe("core tools", () => {
  it("data_freshness reports sources + latest day", () => {
    const r = dataFreshness(cfg);
    expect(r.latestDataDay).toBe("2026-06-13");
    expect(r.sources.map((s) => s.deviceId)).toContain("oura-api");
    expect(r.mirrorAgeSeconds).toBeGreaterThanOrEqual(0);
  });
  it("health_snapshot rolls up recent days by family", () => {
    const r = healthSnapshot(cfg, { days: 2 });
    expect(r.days.length).toBe(2);
    const last = r.days[r.days.length - 1];
    expect(last.day).toBe("2026-06-13");
    expect(last.whoop?.recovery).toBe(66);
    expect(last.oura?.restingHr).toBe(53);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- tools-core`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `src/tools/core.ts`**

```typescript
import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { Config } from "../config.js";
import { Mirror, Family } from "../mirror.js";
import { latestIngest } from "../ingest.js";

export function dataFreshness(cfg: Config) {
  const m = new Mirror(cfg.mirrorPath);
  try {
    const li = latestIngest(cfg);
    const now = Math.floor(Date.now() / 1000);
    return {
      mirrorAgeSeconds: li ? now - li.receivedAt : null,
      lastIngestAt: li ? new Date(li.receivedAt * 1000).toISOString() : null,
      latestDataDay: m.latestDataDay(),
      sources: m.sources().map((s) => ({ deviceId: s.deviceId, family: s.family, latestDay: s.latestDay })),
    };
  } finally { m.close(); }
}

export function healthSnapshot(cfg: Config, args: { days?: number }) {
  const days = Math.max(1, Math.min(args.days ?? 3, 31));
  const m = new Mirror(cfg.mirrorPath);
  try {
    const latest = m.latestDataDay();
    if (!latest) return { days: [] as any[] };
    const to = latest;
    const from = new Date(new Date(`${to}T00:00:00Z`).getTime() - (days - 1) * 86_400_000).toISOString().slice(0, 10);
    const rows = m.dailyMetrics({ from, to });
    const byDay = new Map<string, any>();
    for (const r of rows) {
      const d = byDay.get(r.day) ?? { day: r.day };
      const fam: Family = r.family;
      d[fam] = { restingHr: r.restingHr, avgHrv: r.avgHrv, totalSleepMin: r.totalSleepMin, efficiency: r.efficiency, recovery: r.recovery, strain: r.strain, steps: r.steps };
      byDay.set(r.day, d);
    }
    return { from, to, days: [...byDay.values()].sort((a, b) => a.day.localeCompare(b.day)) };
  } finally { m.close(); }
}

const asTool = (obj: unknown) => ({ content: [{ type: "text" as const, text: JSON.stringify(obj, null, 2) }], structuredContent: obj as Record<string, unknown> });

export function registerCoreTools(server: McpServer, cfg: Config): void {
  server.registerTool("data_freshness", {
    title: "Data freshness",
    description: "How stale the mirror is and which sources it holds. Call this first.",
    inputSchema: {},
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async () => asTool(dataFreshness(cfg)));

  server.registerTool("health_snapshot", {
    title: "Health snapshot",
    description: "Recent per-day roll-up (recovery, strain, sleep, resting HR, HRV) grouped by source family.",
    inputSchema: { days: z.number().int().min(1).max(31).optional().describe("How many recent days (default 3).") },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async (args) => asTool(healthSnapshot(cfg, args)));
}
```

- [ ] **Step 4: Run to verify pass (core + mcp)**

Run: `npm test -- tools-core && npm test -- mcp && npm run build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: core MCP tools health_snapshot + data_freshness"
```

---

### Task 8: Query tools — `metric_series`, `sleep_summary`, `workout_summary`

**Files:**
- Create: `noop-cloud/src/tools/query.ts`
- Modify: `noop-cloud/src/tools/index.ts` (call `registerQueryTools`)
- Test: `noop-cloud/test/tools-query.test.ts`

**Interfaces:**
- Produces: `registerQueryTools(server, cfg)` plus testable fns `metricSeries(cfg, args)`, `sleepSummary(cfg, args)`, `workoutSummary(cfg, args)`.
- `metric_series` args `{ from, to, deviceId?, key? }` → `{ points: MetricPointRow[] }` (accepts any source incl. `oura-api`; keys like `ref_sleep_score`, `oura_readiness`).
- `sleep_summary` args `{ from, to }` → sessions with computed `durationMin`, per family.
- `workout_summary` args `{ from, to }` → workouts with `startIso`, per family.
- Date args are `YYYY-MM-DD`; validate with a zod regex.

- [ ] **Step 1: Write the failing test**

`test/tools-query.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from "vitest";
import fs from "node:fs"; import path from "node:path";
import { buildNoopbak } from "./fixtures/make-fixture.js"; import { ingestNoopbak } from "../src/ingest.js";
import { metricSeries, sleepSummary, workoutSummary } from "../src/tools/query.js";

const dataDir = path.join(process.cwd(), "test/.tmp/tools-query");
const cfg = { dataDir, mirrorPath: path.join(dataDir, "mirror.sqlite"), serverDbPath: path.join(dataDir, "server.sqlite"), maxIngestBytes: 262_144_000 } as any;
beforeAll(() => { fs.rmSync(dataDir, { recursive: true, force: true }); fs.mkdirSync(dataDir, { recursive: true }); const z = path.join(dataDir, "b.noopbak"); buildNoopbak(z); ingestNoopbak(fs.readFileSync(z), cfg); });

describe("query tools", () => {
  it("metric_series returns Oura reference keys", () => {
    const r = metricSeries(cfg, { from: "2026-06-10", to: "2026-06-13", deviceId: "oura-api", key: "oura_readiness" });
    expect(r.points.length).toBe(4);
    expect(r.points[0].value).toBe(78);
  });
  it("sleep_summary computes durationMin per family", () => {
    const r = sleepSummary(cfg, { from: "2026-06-10", to: "2026-06-13" });
    expect(r.sessions.length).toBeGreaterThan(0);
    expect(r.sessions[0].durationMin).toBeGreaterThan(0);
  });
  it("workout_summary returns a running workout", () => {
    const r = workoutSummary(cfg, { from: "2026-06-10", to: "2026-06-13" });
    expect(r.workouts.some((w) => w.sport === "running")).toBe(true);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- tools-query`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `src/tools/query.ts`**

```typescript
import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { Config } from "../config.js";
import { Mirror } from "../mirror.js";

const DAY = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "YYYY-MM-DD");
const range = { from: DAY, to: DAY };
const asTool = (obj: unknown) => ({ content: [{ type: "text" as const, text: JSON.stringify(obj, null, 2) }], structuredContent: obj as Record<string, unknown> });

export function metricSeries(cfg: Config, args: { from: string; to: string; deviceId?: string; key?: string }) {
  const m = new Mirror(cfg.mirrorPath); try { return { points: m.metricSeries(args) }; } finally { m.close(); }
}
export function sleepSummary(cfg: Config, args: { from: string; to: string }) {
  const m = new Mirror(cfg.mirrorPath);
  try { return { sessions: m.sleepSummary(args).map((s) => ({ ...s, startIso: new Date(s.startTs * 1000).toISOString(), durationMin: Math.round((s.endTs - s.startTs) / 60) })) }; }
  finally { m.close(); }
}
export function workoutSummary(cfg: Config, args: { from: string; to: string }) {
  const m = new Mirror(cfg.mirrorPath);
  try { return { workouts: m.workoutSummary(args).map((w) => ({ ...w, startIso: new Date(w.startTs * 1000).toISOString(), durationMin: w.durationS ? Math.round(w.durationS / 60) : null })) }; }
  finally { m.close(); }
}

export function registerQueryTools(server: McpServer, cfg: Config): void {
  server.registerTool("metric_series", {
    title: "Metric series",
    description: "Long-format metric points for a date range. Any source (incl. oura-api) and key (e.g. ref_sleep_score, oura_readiness).",
    inputSchema: { ...range, deviceId: z.string().optional(), key: z.string().optional() },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async (a) => asTool(metricSeries(cfg, a)));

  server.registerTool("sleep_summary", {
    title: "Sleep summary",
    description: "Sleep sessions in a date range with duration and efficiency, per source family.",
    inputSchema: { ...range },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async (a) => asTool(sleepSummary(cfg, a)));

  server.registerTool("workout_summary", {
    title: "Workout summary",
    description: "Workouts in a date range (sport, duration, energy, distance), per source family.",
    inputSchema: { ...range },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async (a) => asTool(workoutSummary(cfg, a)));
}
```

- [ ] **Step 4: Wire into `src/tools/index.ts`**

Add `import { registerQueryTools } from "./query.js";` and call `registerQueryTools(server, cfg);` inside `registerTools`.

- [ ] **Step 5: Run to verify pass**

Run: `npm test -- tools-query && npm run build`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: query tools metric_series + sleep_summary + workout_summary"
```

---

### Task 9: `compare_sources` (cross-source corroboration — G4)

**Files:**
- Create: `noop-cloud/src/tools/compare.ts`
- Modify: `noop-cloud/src/tools/index.ts`
- Test: `noop-cloud/test/tools-compare.test.ts`

**Interfaces:**
- Produces: `compareSources(cfg, args)` + `registerCompareSources(server, cfg)`.
- Args `{ from, to, metrics?: string[] }` (default metrics `["restingHr","avgHrv","totalSleepMin"]`).
- Returns `{ from, to, days: [{ day, metrics: { [metric]: { whoop?, oura?, apple?, spreadPct } } }] }` where `spreadPct = (max-min)/mean*100` over present family values, rounded; `null` families omitted.

- [ ] **Step 1: Write the failing test**

`test/tools-compare.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from "vitest";
import fs from "node:fs"; import path from "node:path";
import { buildNoopbak } from "./fixtures/make-fixture.js"; import { ingestNoopbak } from "../src/ingest.js";
import { compareSources } from "../src/tools/compare.js";

const dataDir = path.join(process.cwd(), "test/.tmp/tools-compare");
const cfg = { dataDir, mirrorPath: path.join(dataDir, "mirror.sqlite"), serverDbPath: path.join(dataDir, "server.sqlite"), maxIngestBytes: 262_144_000 } as any;
beforeAll(() => { fs.rmSync(dataDir, { recursive: true, force: true }); fs.mkdirSync(dataDir, { recursive: true }); const z = path.join(dataDir, "b.noopbak"); buildNoopbak(z); ingestNoopbak(fs.readFileSync(z), cfg); });

describe("compare_sources", () => {
  it("puts WHOOP/Oura/Apple restingHr side by side with a spread", () => {
    const r = compareSources(cfg, { from: "2026-06-13", to: "2026-06-13", metrics: ["restingHr"] });
    const day = r.days[0];
    expect(day.metrics.restingHr.whoop).toBe(51);
    expect(day.metrics.restingHr.oura).toBe(53);
    expect(day.metrics.restingHr.apple).toBe(54);
    expect(day.metrics.restingHr.spreadPct).toBeGreaterThan(0);
  });
  it("omits families with a null value (Apple avgHrv)", () => {
    const r = compareSources(cfg, { from: "2026-06-13", to: "2026-06-13", metrics: ["avgHrv"] });
    expect(r.days[0].metrics.avgHrv.apple).toBeUndefined();
    expect(r.days[0].metrics.avgHrv.whoop).toBe(70);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- tools-compare`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `src/tools/compare.ts`**

```typescript
import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { Config } from "../config.js";
import { Mirror, DailyMetricRow } from "../mirror.js";

const DAY = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "YYYY-MM-DD");
const DEFAULT_METRICS = ["restingHr", "avgHrv", "totalSleepMin"] as const;
const asTool = (obj: unknown) => ({ content: [{ type: "text" as const, text: JSON.stringify(obj, null, 2) }], structuredContent: obj as Record<string, unknown> });

export function compareSources(cfg: Config, args: { from: string; to: string; metrics?: string[] }) {
  const metrics = (args.metrics && args.metrics.length ? args.metrics : [...DEFAULT_METRICS]);
  const m = new Mirror(cfg.mirrorPath);
  try {
    const rows = m.dailyMetrics({ from: args.from, to: args.to });
    const byDay = new Map<string, DailyMetricRow[]>();
    for (const r of rows) { const a = byDay.get(r.day) ?? []; a.push(r); byDay.set(r.day, a); }
    const days = [...byDay.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([day, drows]) => {
      const metricsOut: Record<string, any> = {};
      for (const metric of metrics) {
        const cell: Record<string, number> = {};
        for (const r of drows) { const v = (r as any)[metric]; if (v !== null && v !== undefined) cell[r.family] = v; }
        const vals = Object.values(cell);
        const spreadPct = vals.length >= 2 ? Math.round(((Math.max(...vals) - Math.min(...vals)) / (vals.reduce((s, x) => s + x, 0) / vals.length)) * 1000) / 10 : 0;
        metricsOut[metric] = { ...cell, spreadPct };
      }
      return { day, metrics: metricsOut };
    });
    return { from: args.from, to: args.to, days };
  } finally { m.close(); }
}

export function registerCompareSources(server: McpServer, cfg: Config): void {
  server.registerTool("compare_sources", {
    title: "Compare sources",
    description: "Per-day WHOOP vs Oura vs Apple side by side for chosen metrics, with a spread %. The corroboration workhorse.",
    inputSchema: { from: DAY, to: DAY, metrics: z.array(z.string()).optional().describe("dailyMetric columns, e.g. restingHr, avgHrv, totalSleepMin, steps.") },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async (a) => asTool(compareSources(cfg, a)));
}
```

- [ ] **Step 4: Wire into `src/tools/index.ts`** — import + call `registerCompareSources(server, cfg)`.

- [ ] **Step 5: Run to verify pass**

Run: `npm test -- tools-compare && npm run build`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: compare_sources — per-day WHOOP/Oura/Apple corroboration"
```

---

### Task 10: ChatGPT-shaped `search` + `fetch`

**Files:**
- Create: `noop-cloud/src/tools/search-fetch.ts`
- Modify: `noop-cloud/src/tools/index.ts`
- Test: `noop-cloud/test/tools-search.test.ts`

**Interfaces:**
- Produces: `search(cfg, { query })` → `{ results: [{ id, title, url }] }` and `fetch(cfg, { id })` → `{ id, title, text, url, metadata }`, plus `registerSearchFetch(server, cfg)`.
- **Contract (ChatGPT Deep Research):** these two names + shapes are fixed. `id` format = `day:YYYY-MM-DD`. `search` matches a `YYYY-MM-DD` substring in the query, else returns the most recent days. `fetch` returns a text digest of that day across sources. `url` is a stable `noop-cloud://day/<day>` placeholder (no external fetch).

- [ ] **Step 1: Write the failing test**

`test/tools-search.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from "vitest";
import fs from "node:fs"; import path from "node:path";
import { buildNoopbak } from "./fixtures/make-fixture.js"; import { ingestNoopbak } from "../src/ingest.js";
import { search, fetch as fetchDay } from "../src/tools/search-fetch.js";

const dataDir = path.join(process.cwd(), "test/.tmp/tools-search");
const cfg = { dataDir, mirrorPath: path.join(dataDir, "mirror.sqlite"), serverDbPath: path.join(dataDir, "server.sqlite"), maxIngestBytes: 262_144_000 } as any;
beforeAll(() => { fs.rmSync(dataDir, { recursive: true, force: true }); fs.mkdirSync(dataDir, { recursive: true }); const z = path.join(dataDir, "b.noopbak"); buildNoopbak(z); ingestNoopbak(fs.readFileSync(z), cfg); });

describe("search/fetch", () => {
  it("search returns day results with id/title/url", () => {
    const r = search(cfg, { query: "2026-06-12" });
    expect(r.results[0].id).toBe("day:2026-06-12");
    expect(r.results[0]).toHaveProperty("title");
    expect(r.results[0]).toHaveProperty("url");
  });
  it("fetch returns a text digest for a day", () => {
    const r = fetchDay(cfg, { id: "day:2026-06-13" });
    expect(r.id).toBe("day:2026-06-13");
    expect(r.text).toMatch(/resting/i);
    expect(r.text.length).toBeGreaterThan(20);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- tools-search`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `src/tools/search-fetch.ts`**

```typescript
import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { Config } from "../config.js";
import { Mirror } from "../mirror.js";

const urlFor = (day: string) => `noop-cloud://day/${day}`;

export function search(cfg: Config, args: { query: string }) {
  const m = new Mirror(cfg.mirrorPath);
  try {
    const to = m.latestDataDay(); if (!to) return { results: [] };
    const from = new Date(new Date(`${to}T00:00:00Z`).getTime() - 30 * 86_400_000).toISOString().slice(0, 10);
    const daysSet = new Set(m.dailyMetrics({ from, to }).map((r) => r.day));
    let days = [...daysSet].sort().reverse();
    const m2 = /\d{4}-\d{2}-\d{2}/.exec(args.query);
    if (m2) days = days.filter((d) => d === m2[0]);
    return { results: days.slice(0, 20).map((d) => ({ id: `day:${d}`, title: `Biometrics for ${d}`, url: urlFor(d) })) };
  } finally { m.close(); }
}

export function fetch(cfg: Config, args: { id: string }) {
  const day = args.id.replace(/^day:/, "");
  const m = new Mirror(cfg.mirrorPath);
  try {
    const rows = m.dailyMetrics({ from: day, to: day });
    const lines = rows.map((r) => `${r.family}: resting HR ${r.restingHr ?? "—"}, HRV ${r.avgHrv ?? "—"}, sleep ${r.totalSleepMin ?? "—"} min, recovery ${r.recovery ?? "—"}, strain ${r.strain ?? "—"}, steps ${r.steps ?? "—"}`);
    const text = rows.length ? `Biometrics for ${day}\n${lines.join("\n")}` : `No data for ${day}.`;
    return { id: args.id, title: `Biometrics for ${day}`, text, url: urlFor(day), metadata: { day, sources: rows.map((r) => r.family) } };
  } finally { m.close(); }
}

export function registerSearchFetch(server: McpServer, cfg: Config): void {
  server.registerTool("search", {
    title: "Search",
    description: "ChatGPT Deep Research search: find day-records. Returns {id,title,url}. Use a YYYY-MM-DD in the query to target a day.",
    inputSchema: { query: z.string() },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async (a) => { const r = search(cfg, a); return { content: [{ type: "text", text: JSON.stringify(r) }], structuredContent: r }; });

  server.registerTool("fetch", {
    title: "Fetch",
    description: "ChatGPT Deep Research fetch: full text of a record by id (e.g. day:2026-06-13).",
    inputSchema: { id: z.string() },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async (a) => { const r = fetch(cfg, a); return { content: [{ type: "text", text: JSON.stringify(r) }], structuredContent: r }; });
}
```

- [ ] **Step 4: Wire into `src/tools/index.ts`** — import + call `registerSearchFetch(server, cfg)`.

- [ ] **Step 5: Run all tests + build**

Run: `npm test && npm run build`
Expected: PASS (all suites).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: ChatGPT-shaped search + fetch tools"
```

---

### Task 11: Fly.io deploy config + README

**Files:**
- Create: `noop-cloud/Dockerfile`
- Create: `noop-cloud/.dockerignore`
- Create: `noop-cloud/fly.toml`
- Create: `noop-cloud/README.md`

**Interfaces:** none (deploy artifacts). Deliverable: `docker build` succeeds locally; `fly.toml` declares one machine + one volume at `/data` + autostop.

- [ ] **Step 1: Write the `Dockerfile`**

```dockerfile
FROM node:20-slim AS build
WORKDIR /app
RUN apt-get update && apt-get install -y python3 build-essential && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json* ./
RUN npm install
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:20-slim
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json* ./
RUN apt-get update && apt-get install -y python3 build-essential && npm install --omit=dev && apt-get purge -y python3 build-essential && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/dist ./dist
ENV DATA_DIR=/data
EXPOSE 8080
CMD ["node", "dist/server.js"]
```

- [ ] **Step 2: Write `.dockerignore`**

```
node_modules
dist
.env
data
test
.git
```

- [ ] **Step 3: Write `fly.toml`** (replace `<app-name>` at deploy time)

```toml
app = "noop-cloud"
primary_region = "iad"

[build]

[env]
  DATA_DIR = "/data"
  PORT = "8080"

[[mounts]]
  source = "noop_data"
  destination = "/data"

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 0

[[vm]]
  size = "shared-cpu-1x"
  memory = "512mb"

[checks.health]
  type = "http"
  port = 8080
  method = "get"
  path = "/healthz"
  interval = "30s"
  timeout = "5s"
```

- [ ] **Step 4: Write `README.md`** (self-host guide)

````markdown
# noop-cloud

A self-hostable remote MCP server that mirrors a NOOP health database and exposes
read-only biometrics tools to Claude, ChatGPT, and agents over Streamable HTTP.

## Deploy (Fly.io)

```bash
fly launch --no-deploy --name <your-app>       # edit fly.toml app name
fly volumes create noop_data --size 1 --region iad
fly secrets set RO_TOKEN=$(openssl rand -hex 32) RW_TOKEN=$(openssl rand -hex 32)
fly deploy
```

Save the two tokens. `RW_TOKEN` uploads data; `RO_TOKEN` is for read clients (Claude Code, cron).

## Upload data (iOS Shortcut, no app changes)

In NOOP: **Settings → Backup & Sync → Back up now** to write a `.noopbak`. Then an iOS Shortcut:
"Get File → Get Contents of URL": `POST https://<app>.fly.dev/ingest`, header
`Authorization: Bearer <RW_TOKEN>`, request body = the file.

## Connect Claude Code

```bash
claude mcp add --transport http noop-cloud https://<app>.fly.dev/mcp \
  --header "Authorization: Bearer <RO_TOKEN>"
```

Then ask: "call data_freshness, then health_snapshot for the last 7 days."

## Tools

`data_freshness`, `health_snapshot`, `metric_series`, `sleep_summary`, `workout_summary`,
`compare_sources`, plus ChatGPT Deep Research `search`/`fetch`. Prompts: `morning_report`,
`corroborate_sources`, `find_messy_data`. All read-only in this phase.
````

- [ ] **Step 5: Verify the image builds**

Run: `cd /Users/vk/VKDEV/NOOP/noop-cloud && docker build -t noop-cloud .`
Expected: build succeeds (better-sqlite3 compiles under python3/build-essential).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "chore: Fly.io deploy config (Dockerfile, fly.toml) + README"
```

---

### Task 12: Morning report — GitHub Actions cron + local dry-run

**Files:**
- Create: `noop-cloud/scripts/report.mjs`
- Create: `noop-cloud/.github/workflows/morning-report.yml`
- Modify: `noop-cloud/README.md` (report section)

**Interfaces:**
- Produces: `scripts/report.mjs` — reads env `ANTHROPIC_API_KEY`, `NOOP_CLOUD_URL`, `NOOP_RO_TOKEN`, `NTFY_TOPIC`; calls the Anthropic Messages API with the MCP connector (ro token, tool-allowlist), extracts the text, POSTs it to `https://ntfy.sh/<topic>`. Exits non-zero on API error. `--dry-run` prints instead of pushing.
- Cron workflow runs it daily and on manual dispatch.

- [ ] **Step 1: Write `scripts/report.mjs`**

```javascript
// Node 20+. Generates the morning report via the Anthropic Messages API MCP connector, pushes to ntfy.
const { ANTHROPIC_API_KEY, NOOP_CLOUD_URL, NOOP_RO_TOKEN, NTFY_TOPIC } = process.env;
const dryRun = process.argv.includes("--dry-run");
if (!ANTHROPIC_API_KEY || !NOOP_CLOUD_URL || !NOOP_RO_TOKEN) { console.error("missing env"); process.exit(2); }

const res = await fetch("https://api.anthropic.com/v1/messages", {
  method: "POST",
  headers: {
    "x-api-key": ANTHROPIC_API_KEY,
    "anthropic-version": "2023-06-01",
    "anthropic-beta": "mcp-client-2025-11-20",
    "content-type": "application/json",
  },
  body: JSON.stringify({
    model: "claude-sonnet-5",
    max_tokens: 1024,
    messages: [{ role: "user", content: "Write my morning health report. Call data_freshness first and state the mirror age; if it is older than 36 hours, say so plainly. Then summarize the last 3 days (recovery/strain, sleep, resting HR + HRV trend, workouts) and flag any source disagreements via compare_sources. Under 200 words. No medical advice." }],
    mcp_servers: [{
      type: "url", url: `${NOOP_CLOUD_URL.replace(/\/$/, "")}/mcp`, name: "noop-cloud",
      authorization_token: NOOP_RO_TOKEN,
      tool_configuration: { enabled: true, allowed_tools: ["data_freshness", "health_snapshot", "sleep_summary", "workout_summary", "compare_sources", "metric_series"] },
    }],
  }),
});
if (!res.ok) { console.error("anthropic error", res.status, await res.text()); process.exit(1); }
const data = await res.json();
const text = (data.content ?? []).filter((b) => b.type === "text").map((b) => b.text).join("\n").trim() || "(empty report)";

if (dryRun || !NTFY_TOPIC) { console.log(text); process.exit(0); }
const push = await fetch(`https://ntfy.sh/${NTFY_TOPIC}`, { method: "POST", headers: { Title: "NOOP morning report", Priority: "default" }, body: text });
if (!push.ok) { console.error("ntfy error", push.status); process.exit(1); }
console.log("pushed report to ntfy");
```

- [ ] **Step 2: Write `.github/workflows/morning-report.yml`**

```yaml
name: morning-report
on:
  schedule:
    - cron: "0 13 * * *"   # 13:00 UTC daily — adjust to your morning; also wakes the Fly machine
  workflow_dispatch: {}
jobs:
  report:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "20" }
      - run: node scripts/report.mjs
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          NOOP_CLOUD_URL: ${{ secrets.NOOP_CLOUD_URL }}
          NOOP_RO_TOKEN: ${{ secrets.NOOP_RO_TOKEN }}
          NTFY_TOPIC: ${{ secrets.NTFY_TOPIC }}
```

- [ ] **Step 3: Document + local dry-run test**

Add to `README.md`:

````markdown
## Morning report

A GitHub Actions cron (`.github/workflows/morning-report.yml`) calls the Anthropic Messages API
with this server as an MCP connector (read-only token, tool-allowlisted) and pushes the result to
[ntfy](https://ntfy.sh). Set repo secrets `ANTHROPIC_API_KEY`, `NOOP_CLOUD_URL`, `NOOP_RO_TOKEN`,
`NTFY_TOPIC` and subscribe to the topic in the ntfy app.

Local dry-run (prints, no push):

```bash
ANTHROPIC_API_KEY=… NOOP_CLOUD_URL=https://<app>.fly.dev NOOP_RO_TOKEN=… node scripts/report.mjs --dry-run
```
````

Run the dry-run against the deployed server (or a local `npm run dev` with an ingested fixture) and confirm a coherent report prints.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: morning report via GitHub Actions cron + Anthropic MCP connector + ntfy"
```

---

## Self-Review

**Spec coverage (§5 Phase 1):**
- Fly app `/ingest` + `/mcp` + `/healthz` → Tasks 1, 5, 6. ✅
- Upload via iOS Shortcut (no app code) → Task 11 README documents the Shortcut against `/ingest`. ✅
- Read tools `health_snapshot`, `metric_series`, `sleep_summary`, `workout_summary`, `data_freshness`, `compare_sources` → Tasks 7–9. ✅
- ChatGPT `search`/`fetch` → Task 10. ✅
- Prompts `morning_report`, `corroborate_sources`, `find_messy_data` → Task 6. ✅
- Auth: two static bearer tokens ro/rw, server-side → Task 2; `/ingest` rw, `/mcp` ro → Tasks 5–6. ✅
- Morning report: GitHub Actions cron → Messages API MCP connector (ro, allowlisted) → ntfy → Task 12. ✅
- Fly single-machine + volume + WAL + autostop → Task 11 `fly.toml`. ✅
- Two SQLite files (`mirror.sqlite` RO, `server.sqlite` for ingest log) → Tasks 4, 5. ✅
- `/ingest` validation (size cap, magic bytes, quick_check, foreign-db reject, atomic swap, no-corruption-on-failure) → Task 5. ✅ (spec §6 security posture)
- Multi-source awareness (deviceId families incl. oura-api) → Task 4 `sourceFamily` + every tool. ✅

**Deferred to later phases (correctly absent):** OAuth 2.1 shim (Phase 1.5), in-app upload button (1.5), write/staging tools + `server.sqlite` staging tables (Phase 2), sync-back `/edits` (Phase 3). Token-hashing-in-DB is deferred (env tokens for MVP) — noted in Task 2 as a Phase-1.5 upgrade.

**Placeholder scan:** No `TBD`/`handle edge cases`/prose-only steps — every code step carries runnable code. The one explicit verification note (Task 6 Step: confirm SDK import paths) is a real check, not a placeholder.

**Type consistency:** `Config` (Task 1) is consumed unchanged everywhere. `Mirror` methods (Task 4) match tool call sites (Tasks 7–10). `sourceFamily`/`Family` used consistently. `ingestNoopbak`/`latestIngest`/`IngestError` (Task 5) match their test + `data_freshness` call sites. Tool handler return shape `{ content:[{type:"text",text}], structuredContent }` is uniform. Registry `register<X>(server, cfg)` naming is consistent across Tasks 7–10 and `tools/index.ts`.

**Known follow-ups to flag during execution:** (1) verify the exact `better-sqlite3` prebuilt binding matches the Fly Node-20 image (else `npm rebuild`); (2) confirm `@modelcontextprotocol/sdk@1.29.0` streamable-HTTP stateless option name (`sessionIdGenerator: undefined`) against the installed package before relying on the `/mcp` test; (3) `claude-sonnet-5` model id in `report.mjs` — confirm current id at build time.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-10-noop-cloud-1-mvp-server.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
