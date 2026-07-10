# noop-cloud — personal biometrics MCP server (Fly.io) — design

- **Date:** 2026-07-10
- **Status:** Draft for review
- **Scope:** A new, standalone, self-hostable server project (sibling repo `noop-cloud/`, its own git) + minimal opt-in app-side hooks in this fork. Phased: read mirror → gated writes → sync-back.
- **Relation to upstream:** `CLAUDE.md` marks "no server / no cloud sync" a hard upstream constraint — this is deliberately a **personal-fork + sidecar** project, never a PR to `ryanbr/noop`. The server ships as an agnostic container anyone can self-host; nothing phones home by default.

---

## 1. Summary

The user's NOOP data (WHOOP live + Oura cloud import + Apple Health) lives in the iPhone app's SQLite. He wants an **agentic layer over it**: ask Claude/ChatGPT deep questions, get a plain-English **morning report**, have AI **find and fix mislogged data** (dedupe workouts, correct sleep bounds), **corroborate sources** (WHOOP vs Oura vs Apple baselines), and let his **other agents** read/write workout context — all without a Mac dependency.

`noop-cloud` is a small remote **MCP server on Fly.io** holding a **mirror** of the phone's database. The phone ships its existing `.noopbak` backup to the server (Phase 1: an iOS Shortcut posts it — zero app code; Phase 1.5: an in-app "Sync to my server" button). Claude (web/iOS/Code/API), ChatGPT, and scheduled agents connect over Streamable HTTP. Writes are **staged server-side** (`propose_edit` → `confirm_edit`) because scheduled agents skip client approval UIs. Sync-back to the phone is Phase 3, under a dedicated source namespace so the app's recompute can never clobber (or be clobbered by) server edits.

## 2. Goals / non-goals

**Goals**
- **G1 — Mirror + query.** The full phone DB queryable via MCP tools from Claude + ChatGPT + agents, no Mac.
- **G2 — Morning report.** A scheduled agent produces a plain-English daily briefing from the mirror.
- **G3 — Gated cleanup writes.** AI proposes fixes (workouts, sleep bounds, bad points); nothing mutates without explicit confirmation; every mutation journaled + reversible.
- **G4 — Cross-source corroboration.** First-class tools to compare WHOOP/Oura/Apple per-day and surface discrepancies/baselines.
- **G5 — Self-hostable.** One container + one volume; secrets via env; no third-party data processors. Shareable with the community as "run your own."
- **G6 — Sync-back seam (Phase 3).** Server-side corrections eventually visible in the phone app without corruption.

**Non-goals**
- No multi-user/hosted service. No upstream PR. No replacement of NOOP's scoring. No live BLE anything (phone stays the collector). No LiteFS/replication (single writer by design).

## 3. Verified constraints the design is built on (2026-07-10)

**MCP / clients**
- Current spec **2025-11-25**: remote transport = **Streamable HTTP** (SSE transport deprecated). A **stateless 2026-07-28 revision** is locked (removes `Mcp-Session-Id`/initialize); official guidance: existing servers keep working. → Build on **TypeScript SDK 1.29.x pinned** (Tier-1, ships `StreamableHTTPServerTransport` + OAuth plumbing); migrate post-7/28 deliberately.
- **Auth matrix:** ChatGPT developer-mode connectors = **OAuth 2.1 + PKCE (CIMD/DCR) only — static keys rejected**. claude.ai web custom connectors (individual) = OAuth or no-auth in practice. **Claude Code** = static bearer via `--header` works today; also auto-OAuth. **Messages API MCP connector** (beta `mcp-client-2025-11-20`) = any `https://` URL + static `authorization_token`, per-tool allowlists, tools-only.
- **Claude Code Routines** (cloud, cron ≥1h) include the user's connectors and **execute write tools without permission prompts** → server-side write gating is mandatory, client approval UI is not a defense.
- ChatGPT Deep Research requires exactly-shaped **`search`/`fetch`** tools; general connectors don't.

**Fly.io**
- One `shared-cpu-1x` machine + one volume (`/data`), SQLite **WAL**, `auto_stop_machines="stop"` + `auto_start_machines=true` (wake on request). Cost ≈ $0.20–$2.20/mo. Native scheduled machines lack time-of-day precision → morning cron runs **outside** (GitHub Actions cron or a Claude Routine) and doubles as the wake-up. **No LiteFS** (unmaintained ~15 mo; Fly warns against autostop combos).

**App-side facts (from code study)**
- **`.noopbak`** = ZIP{`noop-backup.sqlite` (+optional `settings.json`)}; export **checkpoints WAL** + `PRAGMA quick_check` first; restore is a **whole-DB destructive swap** with origin/integrity gates and rollback; fully available on iOS (share sheet / Files).
- **BackupSync** = one-way timestamped snapshots into a user folder (iCloud Drive capable) + on-launch daily catch-up. No merge logic exists anywhere.
- **No change tracking**: no `updatedAt` columns; the v5 `synced` flags are documented dead scaffolding from a removed upload feature (which failed once on ts-highwater ordering — lesson recorded). Delta sync = new columns; whole-DB ship is the honest Phase-1 transport.
- **Edit provenance is thin**: only `sleepSession.userEdited` (+`startTsAdjusted`) survives recompute, and only for bounds/stages — `efficiency/restingHr/avgHrv` are overwritten regardless. `dailyMetric`/`workout`/`metricSeries` have **zero** protection and `analyzeRecent` blindly re-upserts the trailing ~21 days every ~15 foreground minutes. **Sleep-delete tombstones live in UserDefaults, not the DB** — backups don't carry deletion state.
- Multi-source reconciliation already exists (per-source `deviceId` namespaces + `Repository.resolvedSeries`/`dayOwnership`) — the correct integration point for server-origin data (mirror the `"oura-api"` pattern; never mutate another source's rows in place).

## 4. Architecture

```
iPhone (collector)                      Fly.io app "noop-cloud" (1 machine, 1 volume)
┌───────────────────────┐   HTTPS      ┌──────────────────────────────────────────────┐
│ NOOP app              │  POST        │ /ingest   ← bearer(rw). .noopbak → verify →   │
│  ├ BackupSync writes  │  .noopbak    │            unzip → quick_check → atomic swap  │
│  │  .noopbak snapshot ├─────────────▶│            /data/mirror.sqlite (RO for tools) │
│  └ (P1: iOS Shortcut  │              │ /mcp      ← Streamable HTTP MCP               │
│     posts it; P1.5:   │              │   read tools · corroborate · search/fetch     │
│     in-app button)    │              │   write tools → staging (propose/confirm)     │
└───────────▲───────────┘              │ /data/server.sqlite: edits journal, staging,  │
            │ Phase 3: pull server     │   tokens, ingest log                          │
            │ edits (userEdited rules) │ auth: OAuth2.1 shim (PKCE+CIMD/DCR) + 2 static │
            └──────────────────────────│   bearer tokens (ro / rw)                     │
                                       └──────▲───────────────▲───────────────────────┘
                          Claude web/iOS/Code/API │           │ ChatGPT (OAuth)
                          Routines/cron (ro token)┘           │ other agents (MCP)
```

Two SQLite files on the volume: **`mirror.sqlite`** (verbatim phone DB, replaced atomically per ingest, opened read-only by tools) and **`server.sqlite`** (server-owned: staged edits, confirmed-edit journal, ingest history, token hashes). Server edits are **never** written into the mirror — the journal is the source of truth for Phase-3 sync-back, and survives every mirror swap.

## 5. Phases

**Phase 1 — Mirror + read tools + morning report (MVP; no app code changes)**
- Fly app (TS SDK 1.29.x, Express, better-sqlite3): `/ingest` + `/mcp` + `/healthz`.
- Upload path: the app's existing **BackupSync** snapshot + an **iOS Shortcut** ("Send NOOP to cloud": share/automation → POST file with `Authorization: Bearer <rw>`), so Phase 1 requires zero app-side code. Manual cadence is fine (data freshness tool reports staleness honestly).
- Read tools (schema from the repo study; multi-source aware): `health_snapshot`, `metric_series` (any `deviceId` source incl. `oura-api`), `sleep_summary`, `workout_summary`, `data_freshness` (incl. mirror age), **`compare_sources`** (per-day WHOOP/Oura/Apple side-by-side with deltas — G4's workhorse), plus ChatGPT-shaped `search`/`fetch`. Prompts: `morning_report`, `corroborate_sources`, `find_messy_data`.
- Auth v1: two static bearer tokens (ro/rw) → Claude Code + Messages API + cron work day 1.
- Morning report: **GitHub Actions cron** (free, exact-time) → Messages API with the MCP connector (ro token, tool-allowlisted) → delivers via ntfy/email push; a Claude Routine is the zero-infra alternative (ro token only — routines skip write approvals).
- **Exit criteria:** user asks Claude (phone or desktop) "how's my week?" against live-ish data with no Mac involved; morning report arrives on schedule.

**Phase 1.5 — Chat-UI auth + in-app upload**
- OAuth 2.1 shim (SDK `mcpAuthRouter` + proxy provider; GitHub/Google as the single-user login; PKCE + CIMD, DCR fallback) so **claude.ai web/iOS and ChatGPT** connect properly. Static tokens remain for headless.
- Optional in-app **"Sync to my server"** (Settings; URL+token fields; POSTs the checkpointed `.noopbak` via the `OuraAPIClient` URLSession pattern; manual button first, on-launch catch-up like BackupSync later). Off by default, personal-fork only.

**Phase 2 — Gated writes + corroboration cleanup**
- `server.sqlite` staging: `propose_edit(kind, payload, rationale)` → human-readable diff → `confirm_edit(id)` / `reject_edit(id)`; `list_pending`, `edit_journal`, `undo_edit`. Kinds: `fix_workout`, `delete_workout`, `add_workout`, `adjust_sleep_bounds`, `delete_metric_point`, `set_baseline_note`.
- Tool annotations (`readOnlyHint`/`destructiveHint`) so both chat UIs render approval framing; **enforcement stays server-side**: the ro token cannot call write tools at all; `confirm_edit` requires the rw credential and is never auto-invoked by prompts we ship.
- Confirmed edits apply to a **server overlay** consulted by read tools (mirror stays pristine) — the overlay + journal are exactly what Phase 3 ships to the phone.

**Phase 3 — Sync-back to the phone (design constraints locked now, detail then)**
- Transport: app pulls `GET /edits?since=<seq>` (journal is append-only + idempotent by edit id).
- Apply rules (from the code study): sleep-bound edits → `applySleepEdit`-equivalent with `userEdited=1` (only path that survives recompute); workout/daily/metric corrections → written under a **new source namespace `"noop-cloud"`** + registered in the source resolver (mirror the `oura-api` integration), never in-place mutations of another source's rows; deletions → require a DB-backed tombstone mechanism (the UserDefaults one doesn't sync) — designed in the Phase-3 plan; every applied edit ack'd back so the journal tracks phone-applied state.

## 6. Auth & security

- HTTPS only (Fly-terminated). Tokens: ≥32-byte random, stored hashed in `server.sqlite`, `ro` + `rw` scopes; rotation = insert new/revoke old. OAuth shim auto-approves exactly one upstream identity (the user's GitHub/Google), everything else 403.
- PHI posture: single-tenant container, no analytics/telemetry, no third-party processors; Fly volume snapshots (default retention) are the backup; `/ingest` size-capped + zip-validated (`quick_check`, magic bytes, origin gate — mirroring `DataBackup.restore`'s own checks); rate-limited.
- Threat notes: a leaked **ro** token exposes read access (rotate; consider IP allowlist later); a leaked **rw** token is the crown jewel — it's entered exactly twice (Shortcut + Claude Code config). Routines/cron get **ro only**, always.

## 7. Testing

- Server: vitest — ingest pipeline (fixture `.noopbak` incl. corrupt/oversized/foreign-origin rejects), every tool against a fixture mirror (multi-source days), staging state machine (propose→confirm/reject/undo), auth middleware (scope enforcement, token hashing), `search`/`fetch` shape conformance.
- Contract smoke: MCP Inspector against local server; Claude Code `claude mcp add --transport http` end-to-end.
- Phase 3 app-side: XCTest against `WhoopStore.inMemory()` proving recompute-survival of applied edits (the `userEdited` + namespace rules).

## 8. Open questions (answers assumed → flag if wrong)

- **Q1 Report delivery:** assumed **ntfy.sh push** (free, no account, self-hostable) with email as fallback. OK?
- **Q2 Upload cadence P1:** manual Shortcut tap (or iOS automation e.g. daily at 6am while charging). OK to start manual?
- **Q3 Server repo home:** new sibling repo `/Users/vk/VKDEV/NOOP/noop-cloud` (own git, MIT/PolyForm — pick at creation). OK?
- **Q4 OAuth upstream identity:** GitHub login assumed (user has GH). OK?

## 9. Out of scope

Multi-user hosting, HIPAA formalities, WHOOP/Oura credential proxying (Oura import keeps running on-phone), replacing NOOP scoring, Android app changes, upstreaming any of this.
