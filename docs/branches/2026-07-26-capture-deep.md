# `capture-deep` — branch state, 2026-07-26

A handoff note for the session that merges this branch back. It records what `capture-deep`
contributes, what is parked uncommitted in its worktree, and which of that must never be committed.
This is a snapshot of one branch at one moment, not a design document — delete it once the branch
lands.

## Why the ahead/behind count misleads

`git status` reports `capture-deep` as **ahead 26, behind 4** of `origin/main`. Only **four** of
those 26 commits are the branch's own work; the merge base is `aed47820`.

The other 22 arrived wholesale through `8176ff20`
(`Merge remote-tracking branch 'upstream/main' into capture-deep`). They are upstream `ryanbr/noop`
commits — the 9.0.1 release prep and PRs #486–#514 — that already exist in `upstream/main`. The
reliable way to separate them:

```bash
git log --oneline origin/main..capture-deep --not upstream/main
```

That returns the branch's own four entries and nothing else.

The underlying cause is fork divergence: 240 commits exist only in `upstream/main`, 146 only in
`origin/main`. `capture-deep` merged upstream in; `origin/main` never did. The branch is therefore a
hybrid, and merging it into `origin/main` imports that upstream slab **along with** the three fixes
below. That is an integration decision, not a formality.

## What the branch actually contributes

| Commit | Area | Verification recorded in the commit |
|---|---|---|
| `24eb06cf` | `fix(liquid-today): carry SpO2 + skin-temp per-field like classic` — app-target Swift; adds the pure `LiquidTodayView.perFieldVital` and `StrandTests/LiquidVitalsCarryTests.swift` | Built the `Strand` (macOS) and `NOOPiOS` schemes and ran `StrandTests` locally — 1038 tests, 0 failures. App-target Swift is not covered by default CI. |
| `9c70cd4c` | `WhoopProtocol: fix v20 (2140 B) historical decoder sample count 50 -> 25` — `Packages/WhoopProtocol` | `swift test`, 286 passing. Census over 29,203 captured buffers; instrumentation-only, zero production consumers. |
| `196a3121` | `docs(bug-sweep)`: merges the duplicated A5 "REFUTED, do not re-derive" block in `docs/bugs/2026-07-15-strap-battery-backfill-observability.md` into one | Docs-only. |
| `a1c7d1fd` | `fix(liquid-today): surface the "N of 4 nights" calibration count` — app-target Swift; adds `ChargeDisplay.calibrationDetail` and two tests. Was uncommitted in the worktree until 2026-07-26 | Built the `Strand` (macOS) scheme — `** BUILD SUCCEEDED **`. Duplicates `origin/main`'s `7770324a`; see below. |

No code commit here needs a Kotlin twin, and each says why: Android already carries
`lastSpo2`/`lastSkinTempRow` (so `24eb06cf` is UI wiring, no analytics change); Android has no v20
historical decoder at all — `decodeWhoop5Historical` returns `null` for `version != 18`, so
`9c70cd4c` has no counterpart to keep in step; and `a1c7d1fd` is UI wiring over an existing state,
with no analytics or stored value.

## What was uncommitted — the code landed, the private config did not

The worktree's pending work split cleanly along a publishable / not-publishable line, and each half
was handled on its own terms.

Everything in both halves is also frozen in the local branch
**`snapshot/capture-deep-worktree-2026-07-26`** (`714df93f`), taken on top of `48d6ea12` as a
recovery point before this session ended. It is not proposed work; do not merge it. Recover a single
path from it without disturbing anything else:

```bash
git show snapshot/capture-deep-worktree-2026-07-26:project.yml > project.yml
```

### 1. Local signing configuration — never commit

`project.yml`, `NOOPWatch/Info.plist`, `NOOPWatch/NOOPWatch.entitlements`,
`StrandiOS/Resources/Info.plist`, `StrandiOS/Resources/NOOP.entitlements`.

These rewrite `DEVELOPMENT_TEAM` from empty to a personal Apple Developer team, repoint every
`PRODUCT_BUNDLE_IDENTIFIER`, `APP_GROUP_ID`, `WKCompanionAppBundleIdentifier` and
`BGTaskSchedulerPermittedIdentifiers` entry from the project prefix to a personal one, drop
`com.apple.developer.healthkit.access` from both entitlement blocks, and remove the `NOOPWatch`
target from `NOOPiOS`'s dependencies.

That is a free-Apple-ID sideload configuration for one developer's own device. Committing it breaks
every other contributor's build, and `vishk23/noop` is a **public** repository — pushing it would
put a personal Apple Developer identity into permanent git history, which a later edit cannot undo,
in a project whose stated scope is to stay anonymous. Keep these paths out of every pushed commit —
stage explicit paths, and never `git commit -a`.

These five paths are the only thing this session left unpushed, and they remain deliberately dirty
in the worktree so an in-progress device build still works as-is.

### 2. The calibration count — committed as `a1c7d1fd`, pushed

`Strand/Liquid/LiquidTodayView.swift` (+19/−1) and `StrandTests/LiquidChargeCarryTests.swift` (+25)
carried the `ChargeDisplay.calibrationDetail` work — the "N of 4 nights" count Liquid Today dropped
while the baseline formed. It holds no personal data, so it landed on the branch normally.

It is the same change `origin/main` already carries as `7770324a` (merged via PR #3, `e5a03661`),
and `capture-deep` had no copy — `HEAD` before this commit had zero `calibrationDetail` occurrences.
After it, both branches have four, and `StrandTests/LiquidChargeCarryTests.swift` is byte-identical
across the two. The merge back should therefore be a no-op on these files rather than a conflict.

Verified by building the `Strand` (macOS) scheme — `** BUILD SUCCEEDED **`, no errors. That check is
not optional here: `swift-packages.yml` does not compile app targets and `app-build.yml` is disabled,
so nothing in default CI would have caught a break in `Strand/Liquid/`.

## What the merge session has to decide

1. **Upstream slab or cherry-pick.** Merging `capture-deep` into `origin/main` takes 22 upstream
   commits with it. Cherry-picking `24eb06cf`, `9c70cd4c`, `196a3121` onto a branch cut from
   `origin/main` lands the fixes without that import. Do **not** cherry-pick `a1c7d1fd` — `origin/main`
   already has that change as `7770324a`.
2. **The A5 dedup is not everywhere.** `196a3121` fixed the duplicated block on `capture-deep` only.
   `origin/main` and `origin/ble-link-recovery-port` still carry the block twice. Whichever branch
   lands the fix first, the other needs a rebase or its own dedup. The file is fork-local and does
   not exist in `upstream/main`.
3. **The local signing config must stay uncommitted and stay present.** A stray `git checkout` or
   `git stash drop` on those five paths costs a working device build.

## Re-verify any claim here

```bash
git log --oneline origin/main..capture-deep --not upstream/main   # the branch's own commits
git rev-list --left-right --count upstream/main...origin/main     # fork divergence
git branch -r --contains 196a3121                                 # where the A5 dedup exists
git diff --stat                                                   # the uncommitted worktree
```

Other branches are checked out in sibling worktrees (`ble-link-recovery-port`,
`build/macos-aapt2-pin`, `coarse-workout-classifier`), so this worktree's uncommitted state is not
the whole picture of in-flight work.
