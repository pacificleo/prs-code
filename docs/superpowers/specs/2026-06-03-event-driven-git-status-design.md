# Event-Driven Git Status & PR Refresh — Design

**Date:** 2026-06-03
**Branch:** `pwason/gitstatusd`
**Status:** Approved design, pending implementation plan

## Problem

The sidebar/top-bar git indicators are driven by **blind fixed-interval polling**, which
runs git/`gh` work whether or not anything changed. At idle this dominates the app's
local resource cost on a laptop (CPU, SSD writes, battery/radio wakeups).

Indicators today:

| Indicator | Where | Source | File |
|---|---|---|---|
| `+X -Y` dirty pill | right of worktree name | `git diff HEAD --shortstat` | `GitClient.swift:425`, `WorktreeRow.swift:191` |
| Branch name | worktree row | reads `.git/HEAD` directly | `GitClient.swift:397` |
| PR summary (#, OPEN/MERGED, merge-readiness) | below worktree name | `gh api graphql` (batched) | `GithubCLIClient.swift`, `WorktreeRow.swift:128` |
| PR status + checks ring + title | top toolbar | same `gh` data, cached | `ToolbarStatusView.swift:30`, `PullRequestStatusButton.swift` |

### Current scheduling (verified in code)

`WorktreeInfoWatcherManager` (`Features/Repositories/BusinessLogic/`):

- **Line-change polling** (`updateLineChangeSchedule:400`, `updateRepeatingTask:439`): one
  repeating task **per worktree**, 30 s focused / 60 s unfocused. Each tick →
  `git diff HEAD --shortstat`. No "skip if unchanged" guard — the subprocess runs every
  cycle regardless.
- **PR polling** (`updatePullRequestSchedule:343`): one task **per repo**, 30 s / 60 s →
  batched `gh api graphql`.
- **HEAD watcher** (`startWatcher:180`): a `DispatchSource` vnode watcher on `.git/HEAD`
  only (catches branch/commit, **not** working-tree edits — which is *why* the blind poll
  exists).
- Separately, the AppFeature scenePhase timer runs `wt ls --json` per repo every 30 s
  (PERF.md S6) — see Out of Scope.

### Why this is the cost

A single `git diff HEAD --shortstat` pays: process spawn + config reparse + index parse +
**O(N) working-tree lstat scan** + diff of changed files + **`.git/index` writeback (disk
write)**. Multiplied by worktree count, every 30/60 s, at idle. The `gh` poll additionally
spawns a process **and** makes an HTTPS round trip (radio wake, API quota) per repo on the
same cadence.

## Goals

- Local git work runs **only when something actually changed** (event-driven), with no
  blind timer.
- Must stay cheap on **both** tiny repos and huge monorepos ("mixed/unpredictable" scale).
- **Keep the exact `+/-` line-count pill** (no semantic change).
- Cut redundant `gh` network calls.
- No new native dependencies (git CLI retained).

## Non-Goals

- No libgit2 / gitstatusd / in-process git engine (explicitly declined — keep git CLI).
- No switch to URLSession/ETag for PRs (declined — keep `gh`).
- No change to PR data shape or the views that render it.
- `wt ls --json` timer fix (separate follow-up, see Out of Scope).

## Chosen Approach

**Git CLI + `core.fsmonitor`, fully event-driven, `gh` kept with event-triggers + dedupe.**
Selected via brainstorming over the alternatives (libgit2 in-process; gitstatusd daemon;
URLSession+ETag). Rationale: lowest risk, no native deps, preserves the `+/-` pill, and the
biggest whole-laptop win (eliminating redundant work) comes from event-gating rather than a
faster engine.

## Architecture

### A. Local status — `WorktreeChangeWatcher` (new)

Replaces the `.git/HEAD`-only `DispatchSource` logic. One per worktree, built on the
high-level **`FSEventStream`** tree-watching API (not single-fd vnode watching).

**Debounce (two layers):**
1. **OS coalescing** — `FSEventStream` `latency` ~0.5–1.0 s; the kernel batches a burst
   (e.g. a build writing 1,000 files) into one callback.
2. **App deadline debounce** — a coalescing window collapses multiple callbacks into **one**
   `git diff` run. Worst case ≈ one cheap git run per window per worktree under heavy churn.

**`.gitignore` filtering (layered, cheapest-first):**
1. **Always drop the `.git/` subtree** from this stream (git's internal churn is huge and
   irrelevant; HEAD/index/refs handled by the targeted ref watcher in B).
2. **Top-level ignore prefilter** — parse the repo's top-level `.gitignore` +
   `.git/info/exclude` once (re-parse when those files change) into a set of ignored
   directory prefixes (`node_modules/`, `build/`, `.build/`, `DerivedData/`, …). Drop
   FSEvent paths under those prefixes before scheduling a git run. Covers ~90% of noise.
3. **git is the source of truth** — full nested/negated `.gitignore` semantics are *not*
   replicated. If a noisy event slips past the prefilter, the resulting `git diff` (fsmonitor
   -backed, fast) reports "no change" and the pill doesn't move. Perfect filtering is an
   **optimization, not a correctness requirement**.

Note: the `+/-` pill is `git diff HEAD --shortstat`, which reflects **only modifications to
tracked files** — untracked and ignored churn never move it. So debounce + top-level
prefilter + "git is truth" is more than sufficient; no per-file ignore matching is needed.

**Cheap git call:** `lineChanges` invokes git with
`env GIT_OPTIONAL_LOCKS=0` (prevents `.git/index` writeback) and
`-c core.fsmonitor=true` (skips the O(N) lstat scan on large repos). git version detected
once; `core.fsmonitor` flag omitted on git < 2.37 or unsupported filesystems (git also
auto-falls-back safely).

**Two complementary watchers:**
- *Our* `FSEventStream` decides **when to run**.
- *git's* `core.fsmonitor` makes **the run cheap**.
- Future optimization (out of scope): unify into one watcher by having CherryLily act as
  git's custom fsmonitor hook provider.

### B. PR refresh — keep `gh`, three narrow triggers + dedupe

Keep `gh api graphql` and the existing chunked batching. Replace the per-repo 30/60 s blind
loop with:

1. **Ref-change trigger.** A targeted watcher on the `.git` ref area — `.git/HEAD`,
   `.git/refs/heads/`, `.git/refs/remotes/<remote>/`, `.git/packed-refs`, `.git/logs/HEAD`.
   A commit, branch switch, or **successful push** (git updates the remote-tracking ref on
   push) → schedule a PR refresh. Distinct from the A stream (different paths/debounce).
2. **SHA dedupe.** Track `lastFetchedHeadSHA` per worktree. On a ref event, compute the
   current head SHA and **only fire `gh` if it moved** since the last *successful* fetch. On
   fetch failure, don't update the stored SHA (so it retries).
3. **Slow discovery cadence — focused repo only.** Catches changes with no local signal
   (approvals, CI completion, PRs created on the web): one slow poll (~2–3 min) **only for
   the repo containing the focused worktree**. Background repos do not poll periodically;
   they refresh on ref events and on becoming focused (existing 5 s selection cooldown
   stays).

Net: pushes reflect near-instantly; remote-side changes within a few minutes while the user
is looking; background repos go quiet.

## Data Flow

```
[worktree content FSEventStream] →(OS latency coalesce)→ callback
   → drop .git/ + top-level-ignored prefixes → deadline debounce
   → .filesChanged(worktreeID) → RepositoriesFeature reducer
   → gitClient.lineChanges(url)  [env GIT_OPTIONAL_LOCKS=0, -c core.fsmonitor=true]
   → .worktreeLineChangesLoaded → worktreeInfoByID → +/- pill re-renders

[.git ref watcher] → debounce → re-read HEAD (branch label)
   → head SHA moved vs lastFetchedHeadSHA? → .repositoryPullRequestRefresh(changedWorktreeIDs)
   → githubCLI.batchPullRequests → pullRequestsByWorktreeID

[focus change] → immediate PR refresh (cooldown-gated)
[slow timer, focused repo only ~2–3 min] → PR discovery refresh
```

## Error Handling

- **`FSEventStream` fails to start** (fd exhaustion, path gone) → log via `SupaLogger`.
  **No fallback poll** (per decision) — that worktree's pill won't update until restart or a
  later successful (re)start. Accepted tradeoff.
- **Worktree dir deleted/renamed** → tear down stream + tasks (existing teardown pattern).
- **`git diff` fails / `index.lock` present** → **keep last known pill value** (no flicker to
  nil); retry on next event.
- **git < 2.37 / unsupported FS** → omit `-c core.fsmonitor=true`; git auto-falls-back too.
- **`gh` missing / unauthed / network down** → keep existing GitHub-availability handling,
  but change its fixed 15 s retry to **exponential backoff** to avoid a spin.

## Testing

Per CLAUDE.md: cover reducer changes; use `TestClock`/injected clock, never `Task.sleep`
(the manager already accepts a `Clock`).

- **Watcher:** abstract the FSEvent source behind a protocol so tests feed synthetic
  path-change batches. Assert: `.git/` + ignored-prefix events dropped; a burst within the
  window → **one** emit (driven by `TestClock`).
- **Ignore-prefix parser:** unit-test top-level `.gitignore` / `info/exclude` → prefix set.
- **Reducer:** `.filesChanged` → `lineChanges` effect; **SHA dedupe** (no `gh` effect when
  SHA unchanged); focus-change refresh respects the cooldown.
- **`GitClient.lineChanges`:** asserts `GIT_OPTIONAL_LOCKS=0` and `-c core.fsmonitor` are
  passed; existing shortstat-parse tests stay.

## Resource Estimate (3 repos × 10 worktrees = 30, 1 focused)

**At idle (nothing changing):**

| Resource (per min) | Before | After |
|---|---|---|
| `git diff` spawns | ~31 | **0** |
| `gh graphql` round-trips | ~4 | **~0.4** (focused-repo discovery only) |
| `wt ls --json` spawns* | ~6 | ~6 (*out of scope) |
| `.git/index` rewrites (disk writes) | up to ~31 | **0** (`GIT_OPTIONAL_LOCKS=0`) |
| Timer/radio wakeups | 30 wt + 3 repo timers, radio 4× | ~0 CPU idle, radio ~0.4× |

**During active editing (focused worktree):**

| | Before | After |
|---|---|---|
| `git diff` for edited worktree | every 30 s regardless | ~1 per debounce window *with real edits*, fsmonitor-cheap |
| `git diff` for the other 29 | ~29/min | **0** (only their own file events trigger them) |

Headline: idle drops from ~41 spawns + 4 network/min to ~0 spawns + ~0.4 network/min; work
now scales with **actual edits to the worktree being touched**, not with total worktree
count.

## Out of Scope / Follow-ups

- **`wt ls --json` 30 s rediscovery** (PERF.md S6, AppFeature scenePhase timer). Natural fix:
  refresh the worktree list on the app's own create/remove actions plus a `.git/worktrees`
  event, instead of on a timer. Not implemented here.
- **Unify watchers** via git custom fsmonitor hook provider.
- **PERF.md ranks 1–5** (whole-tree `store.state` reads, deep `@ObservableState` diffs,
  per-keystroke `NSEvent` monitors, tab-bar rebuilds, accessibility scrollback) — these are
  where *visible UI lag* lives and are unaffected by this change.

## Affected Files (anticipated)

- `Features/Repositories/BusinessLogic/WorktreeInfoWatcherManager.swift` — replace HEAD-only
  `DispatchSource` with `WorktreeChangeWatcher` (FSEventStream) + `.git` ref watcher; remove
  blind line-change/PR polling loops; add SHA dedupe + focused-only discovery.
- New: `WorktreeChangeWatcher` + an FSEvent-source protocol + ignore-prefix parser.
- `Clients/Git/GitClient.swift` — `lineChanges` passes `GIT_OPTIONAL_LOCKS=0` and
  `-c core.fsmonitor=true`; add git-version detection.
- `Features/Repositories/Reducer/RepositoriesFeature.swift` — SHA dedupe state, trigger
  wiring, exponential backoff for GitHub availability.
- Tests alongside the above.
