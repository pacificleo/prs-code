# CherryLily Performance Review

Consolidated output of a 5-agent parallel code review (TCA reducers, SwiftUI views, memory/leaks, concurrency, Ghostty hot path) over ~30k lines of Swift. Targeted at the reported symptom: **"app keeps slowing down and has visible lag"**, worse over time and with more tabs/worktrees.

Findings cite `file:line`. Multi-agent corroborations are marked with **★** (high confidence).

---

## Diagnosis in one sentence

The app has two overlapping vicious cycles:

1. **Write amplification** — views read whole-tree `store.state` and the entire per-surface `@Observable` state, so any mutation re-invalidates large subtrees.
2. **Per-event O(N) walks** that scale with worktree/tab/surface count — every keystroke, focus change, progress tick, and FS event runs work proportional to total surfaces and to the entire repository/worktree tree.

Each is tolerable alone; combined they explain "gets slower the longer I use it / the more tabs I open."

---

## Top suspects ranked

| Rank | Finding | File:line | Confidence |
|---|---|---|---|
| 1 | `store.state` whole-tree reads in views force every mutation to invalidate everything | `WorktreeDetailView.swift:11-108` and 4 sibling views | ★★★ |
| 2 | `@ObservableState` deep state — TCA Equatable walks the whole tree on every action | `RepositoriesFeature.swift:2729-2750`, `AppFeature.swift:128-135` | ★★★ |
| 3 | Per-surface `NSEvent.addLocalMonitorForEvents` — every keystroke fires N closures | `GhosttySurfaceView.swift:195-198` | ★★★ |
| 4 | `applySurfaceActivity` + `updateRunningState` rebuild whole tab bar on every progress tick | `WorktreeTerminalState.swift:389-415, 898-908, 1102-1110` | ★★★ |
| 5 | Accessibility reads entire scrollback (up to 1M lines) every 500ms, invalidated by every `cd` | `GhosttySurfaceView.swift:14-46, 437-487, 516-537`, `GhosttySurfaceBridge.swift:190` | ★★★ |
| 6 | Periodic 30s `refreshWorktrees` + watcher timers double-fire and shell out per worktree | `AppFeature.swift:128-135`, `WorktreeInfoWatcherManager.swift:362-378, 439-453` | ★★ |
| 7 | ShellClient pipeline burns 3 tasks + 2 pipe queues + unbounded AsyncStream per call; new `GitClient()` per call | `ShellClient.swift:170-235`, `GitClientDependency.swift:44-87` | ★★ |
| 8 | CommandPalette items recomputed and fuzzy-scored while palette is closed | `ContentView.swift:91-99`, `CommandPaletteOverlayView.swift:70-93` | ★★ |
| 9 | Settings binding persists + fans out 7 effects on every keystroke | `SettingsFeature.swift:186-190`, `RepositorySettingsFeature.swift:112-125` | ★★ |
| 10 | `toolbarNotificationGroups` walks O(repos × worktrees) per body recompute | `WorktreeDetailView.swift:36-39`, `ToolbarNotificationGroup.swift:28-66` | ★★ |

---

## Detailed findings (Tier S = top, C = polish)

### TIER S — Almost certainly the cause of visible lag

**S1 ★★★ `store.state` whole-tree reads.** Found by SwiftUI (C1, H4, H10, H16), Reducer (H7), Ghostty (C2/C3).
- `WorktreeDetailView.swift:11-108` `var body { detailBody(state: store.state) }` registers observation on every property of `AppFeature.State` (transitively `RepositoriesFeature.State` + `worktreeInfoByID` + nav history + commandPalette + …).
- Same pattern: `SidebarListView.swift:11-85`, `WorktreeRowsView.swift`, `RepositorySectionView.swift:18-19`, `SidebarFooterView.swift:13-17`.
- `GhosttySurfaceState.swift:6-51` — single `@Observable` with 40+ tracked fields all sharing one registrar.

**S2 ★★★ `@ObservableState` deep state diff cost.** Found by Reducer (C3, C5, C6, H5), Concurrency (H7), SwiftUI (C1).
- `RepositoriesFeature.swift:2729-2750` `applyRepositories` always runs full pipeline; `IdentifiedArrayOf<Repository>` deep-compared on every 30s tick; `Worktree.createdAt: Date` re-read from FS per refresh causes false diffs.
- `repositoriesChanged(state.repositories)` sent from 8+ sites; AppFeature consumer re-runs `worktreesForInfoWatcher()` + `recencyRetentionIDs(from:)` (full traversals).
- `state.repositories[index] = …` reallocates whole `Repository` struct to change one `Worktree.branchName` (Reducer H5).

**S3 ★★★ Per-keystroke O(N-surfaces) work.** Found by Memory (C2), Ghostty (M8), Concurrency (H9).
- `GhosttySurfaceView.swift:195-198` — every `GhosttySurfaceView` registers its own app-wide `NSEvent.addLocalMonitorForEvents` for `.keyUp` and `.leftMouseDown`. 120 surfaces → 120 closures per keystroke.

**S4 ★★★ Per-progress-tick fan-out re-renders the entire tab bar.** Found by Ghostty (C6, H1), SwiftUI (C4).
- `WorktreeTerminalState.swift:389-415` `applySurfaceActivity()` walks every leaf in every tab on every focus change AND every progress tick.
- `WorktreeTerminalState.swift:898-908, 1102-1110` `updateRunningState(for:)` writes `tabIsRunningById[tabId]` and calls `tabManager.updateDirty()` on **every** progress report — mutates `@Observable tabs` array → tab bar rebuilds.
- `WorktreeTerminalTabsView.swift:35-40` reads whole `state.tabManager.tabs`.

**S5 ★★★ Accessibility hot path.** Found by Memory (H6), Ghostty (C5), SwiftUI (H12).
- `GhosttySurfaceView.swift:14-46, 437-487, 516-537` — every AX query hits `cachedScreenContents.get()` which calls `ghostty_surface_read_text` over the entire scrollback (cap 1,000,000 lines per `bootstrapSessionPersistence:319`). 500ms TTL re-spawns a `Task` per surface per refresh. `accessibilityLine` does O(n) `String.prefix(N).components(separatedBy: .newlines)` per call.
- `GhosttySurfaceBridge.swift:190` posts `NSAccessibility.post(.valueChanged)` on every `PWD` action → invalidates cache and triggers AppKit AX requeries.

**S6 ★★ Periodic timers double-fire and shell out per worktree.** Found by Reducer (C5, C6), Concurrency (C3, C4, H3, M10).
- `AppFeature.swift:128-135` scenePhase timer fires `refreshWorktrees` every 30s → `pruneWorktrees` serial per repo → `loadRepositoriesData` shells `wt ls --json` per repo → `applyRepositories` runs 4 prune passes.
- `WorktreeInfoWatcherManager.swift:362-378, 439-453` runs one `Task { while !cancelled { sleep; MainActor.run { emit } } }` **per worktree** for line-changes and **per repo** for PR refresh.
- Worst case: 10 worktrees × 3 repos → ~60 git/gh subprocesses every 30 seconds at idle.

**S7 ★★ ShellClient pipeline + per-call `GitClient()`.** Found by Concurrency (C1, C2, H1), Memory (M3).
- `ShellClient.swift:170-235` — per call: `Task.detached` blocks on `process.waitUntilExit()` while two more `Task.detached` line-stream consumers feed an **unbounded** AsyncStream. **No `continuation.onTermination`** — cancellation leaves zombie processes + leaked FDs.
- `GitClientDependency.swift:44-87` — every git op constructs a new `GitClient()`.
- `GitClient.swift:390, 437` — `branchName(for:)` and `isWorktreeIndexLocked` do `await MainActor.run { FileManager.default.… }`.

### TIER A — Strong contributors

**A1 ★★ CommandPalette items computed/fuzzy-scored while closed.** SwiftUI (H1, H2), Reducer (M5, M7).
- `ContentView.swift:91-99` — `CommandPaletteOverlayView` is unconditional `.overlay`.
- `CommandPaletteFeature.commandPaletteItems(...)` iterates repos × worktrees on every parent recompute.
- `CommandPaletteOverlayView.swift:70-93` — 4 `onChange` + 1 `.task` all call `refreshFilteredItems` (fuzzy scoring).
- `CommandPaletteFeature.swift:980-983` — fuzzy scorer allocates `Array(repeating: 0, count: Q×T)` per item, plus a redundant `var mutableScores = scores` clone.

**A2 ★★ Settings & RepositorySettings persist on every keystroke.** Reducer (M3, M4).
- `SettingsFeature.swift:186-190` `BindingReducer` + `persist(_:)` writes `$settingsFile.withLock` + emits `delegate(.settingsChanged)` per binding mutation; `AppFeature.swift:280-344` `.merge`s ~7 effects per change.
- `RepositorySettingsFeature.swift:112-125` — same.

**A3 ★★ `toolbarNotificationGroups` O(repos × worktrees) per body.** SwiftUI (C2), adjacent (M15).
- `WorktreeDetailView.swift:36-39` called unconditionally, twice per render.
- `ToolbarNotificationGroup.swift:28-66` allocates fresh dict + iterates everything.
- `WorktreeTerminalManager.swift:365-373` `emitNotificationIndicatorCountIfNeeded` walks all states × all notifications.

**A4 ★★ FS events fan out one Task per event, no queue-level coalescing.** Concurrency (C3).
- `WorktreeInfoWatcherManager.swift:180-218` — DispatchSource handler does `Task { @MainActor in self?.handleEvent(...) }` per event; `git fetch` floods MainActor with dozens of Tasks.

**A5 ★★ `worktreeInfoEvent(.filesChanged)` spawns non-cancellable git subprocess per worktree per debounce.** Reducer (C2), Concurrency (C4).
- `RepositoriesFeature.swift:1990-2019` — `.run` effect with **no `.cancellable(id:)`**; N worktrees being edited → N concurrent shells per cycle.

**A6 ★★ O(N) helper lookups + `IdentifiedArrayOf` reallocation.** Reducer (C4, H5).
- `RepositoriesFeature.swift:2973-2992, 3027-3036` — `worktree(for:)`, `repositoryID(containing:)` walk every repository × every worktree.
- `RepositoriesFeature.swift:3475-3507, 3286-3304, 3306-3324` — `updateWorktreeName`/`insertWorktree`/`removeWorktree` swap whole `Repository` struct.

**A7 ★ `WorktreeRow` non-Equatable + per-render allocations.** SwiftUI (H6, H7, H8, H9).
- `WorktreeRow.swift:27-39, 162-194` — 17 properties (none Equatable), closures always differ, `NSFont.preferredFont(...).ascender` per row, `summaryText` builds fresh `AttributedString` per render, `archiveShortcut` recomputed each render.
- `WorktreeRowsView.swift:30-32, 334-354` — dict-by-index per render, `URL(fileURLWithPath:).lastPathComponent` per row.

**A8 ★ Hover popovers spawn cancellable `Task` per mouse-over event.** SwiftUI (H11).
- `NotificationPopoverButton.swift:42-55`, `ToolbarNotificationsPopoverButton.swift:84-97`, `PullRequestChecksPopoverButton.swift:57-70`, `TerminalTabBarTrailingAccessories.swift:178-207`.

### TIER B — Real, lower amplification

| # | Finding | File:line |
|---|---|---|
| B1 | `WorktreeTerminalState.notifications` unbounded — bells from shells append forever; `insert(at: 0)` is O(n) | `WorktreeTerminalState.swift:39, 1057-1076` |
| B2 | `.terminalEvent(.notificationIndicatorChanged)` always returns no-op MainActor hop (sets already-nil `dockTile.badgeLabel`) | `AppFeature.swift:790-796` |
| B3 | `progressResetTask` cancels + reallocates 15s-sleep Task per progress report — bursts allocate hundreds of soon-cancelled tasks | `GhosttySurfaceBridge.swift:215-233` |
| B4 | `Task.detached { FileManager.removeItem }` per worktree deletion — unbounded fan-out | `GitClient.swift:511-513` |
| B5 | `TmuxClient` continuations have no `withTaskCancellationHandler` — leaves tmux processes running on quit | `TmuxClient.swift:82-94, 179-188` |
| B6 | Autosave `captureAll` fans out N tmux subprocesses simultaneously | `SessionPersistence` + `TmuxClient.swift:83` |
| B7 | Ghostty C-action → `DispatchQueue.main.async` carries C-string pointers across hop; risk of use-after-free + unbounded main-queue depth under mouse-motion/scrollbar storms | `GhosttyRuntime.swift:209-348` |
| B8 | `TerminalSplitTreeAXContainer.updateNSView` reassigns `rootView = AnyView(...)` per parent update | `TerminalSplitTreeView.swift:291-296` |
| B9 | `GeometryReader` overuse in `CommandPaletteOverlayView`, `SplitView`, `TerminalSplitTreeView.LeafView`, `TerminalTabsView`, `GhosttySurfaceProgressBar` | various |
| B10 | `bridge.state.bellCount = 0` written unconditionally on every keystroke | `GhosttySurfaceView.swift:544, 398` |
| B11 | `keyDown` calls `TISCopyCurrentKeyboardInputSource` (XPC hop) per keystroke | `GhosttySurfaceView.swift:1316-1332` |
| B12 | 6 NotificationCenter observers re-registered on every `viewDidMoveToWindow`; each handler wraps work in `Task { @MainActor }` despite being on `.main` queue already | `GhosttySurfaceView.swift:241-305, 1612-1677` |
| B13 | `OpenWorktreeActionMenuLabelView` resizes NSImage via `lockFocus/draw/unlockFocus` per body render | `OpenWorktreeActionMenuLabelView.swift:8-29` |
| B14 | PR refresh recovery loop hammers `gh` every 15s on permanent failure with no exponential backoff | `RepositoriesFeature.swift:2096-2122` |
| B15 | `worktreeInfoEvent(.repositoryPullRequestRefresh)` fires N concurrent `gh` calls on availability flip | `RepositoriesFeature.swift:2128-2142` |
| B16 | `pullRequestAction(.merge|.close|...)` does immediate **and** delayed PR refresh — duplicate network calls | `RepositoriesFeature.swift:2300/2332/2362/2497` |
| B17 | `withAnimation { … }` *inside* reducer wraps SwiftUI implicit transactions, defeating TCA batching | `RepositoriesFeature.swift:1345, 1403, 1623, 1699, 1973, 2731` |
| B18 | `WorktreeTerminalManager.pendingEvents` unbounded; AsyncStream default `.unbounded` buffering can balloon under progress storms | `WorktreeTerminalManager.swift:20, 357-363, 146-163` |
| B19 | `WorktreeInfoWatcherManager.scheduleBranchChanged/scheduleFilesChanged` recreates Task per FS event | `WorktreeInfoWatcherManager.swift:220-251` |
| B20 | `GhosttyRuntime.surfaceRefs` rescans on every register/unregister | `GhosttyRuntime.swift:23, 135-148` |
| B21 | `worktreesForInfoWatcher()` + `recencyRetentionIDs(from:)` recompute on every `.repositoriesChanged` (8+ trigger sites) | `AppFeature.swift:215-216` |
| B22 | `tabId(containing:)` is O(tabs × leaves) per focus event | `WorktreeTerminalState.swift:1088-1093` |
| B23 | `WorktreeRowsView` / `SidebarFooterView` rebuild on every `commandKeyObserver.isPressed` toggle | several |
| B24 | `.id(node.structuralIdentity)` re-hashes whole tree per body | `TerminalSplitTreeView.swift:25-26` |
| B25 | `applyRepositories` re-reads `URL.resourceValues(.creationDateKey)` per worktree per refresh | `GitClient.swift:87-92` |

### TIER C — Polish

- Many `Task { @MainActor in foo() }` from closures already on MainActor — drop the hop (Concurrency H8, L1, L2; SwiftUI M3, M6, M9; Memory H1).
- `ForEach(Array(x.enumerated()), id: \.element)` allocations (SwiftUI L1, L2).
- `KeyboardShortcut(...).display` computed per row per render (SwiftUI L4, H8).
- `JSONDecoder()` allocated inline per `gh` call (Concurrency L4).

### Verified-not-a-problem (so you don't hunt here)

- OSC 9 / 777 strip runs only at autosave/quit (`ScrollbackStore.sanitize`), not on per-byte read path. ✅
- Tmux disk-full check lives in `SessionPersistence.captureAll`. ✅
- `Unmanaged.passUnretained` on Ghostty C bridge — owner outlives C handle. ✅
- C-string lifecycle in `GhosttySurfaceView` correctly `strdup`/`free`. ✅
- `NavigationHistory` capped at 50. ✅
- `loadRepositoriesData` `withTaskGroup` is properly cancellable. ✅
- Toast auto-dismiss uses `.cancellable(cancelInFlight: true)`. ✅
- `WorktreeInfoWatcherManager` cancels per-worktree refresh tasks on worktree removal. ✅

---

# Fix sections (highest → lowest expected improvement)

## Guiding rules (apply to every fix)

- **No functional regressions.** A user must not notice any behavior difference except "faster."
- Behavior-preserving by default. Anywhere a change would alter an observable behavior (refresh cadence, accessibility output, notification cap, etc.), it is called out explicitly so you can decide.
- Add tests for any reducer change that's more than a one-line guard.
- After each section: `make build-app && make test`, then live smoke-test the listed scenarios.
- Each item lists: **What**, **Why**, **Risk**, **Smoke test**.

---

## Section 1 — Highest impact (kill the worst hot loops)

> **Status: ✅ Landed** (commit `d494ad3`, single squashed commit). All of 1.1–1.5
> shipped. One deviation: the `GitClient` caching + `MainActor.run` removal originally
> grouped under 1.5/S7 was deferred out of Section 1 (lint blocker) and later landed in
> Section 2 as 2.10. Build + full test suite green.

Targets the largest per-keystroke / per-tick costs and the cheapest quick-wins. Expect a clearly perceptible improvement after this section, especially during active use with several tabs.

### 1.1 — Quick-win guards (≈30 lines total, near-zero risk)

- **[B10] Guard `bellCount = 0` write**
  - **What:** In `GhosttySurfaceView.swift:544` and `:398` change `bridge.state.bellCount = 0` to `if bridge.state.bellCount != 0 { bridge.state.bellCount = 0 }`.
  - **Why:** Stops every keystroke from invalidating `GhosttySurfaceState` observers.
  - **Risk:** None — same effective state.
  - **Smoke:** Type in a terminal; bell still increments and resets after focus.

- **[B2] Delete no-op MainActor hop**
  - **What:** In `AppFeature.swift:790-796`, return `.none` from `.terminalEvent(.notificationIndicatorChanged)` after updating state (the `dockTile.badgeLabel = nil` line is dead — it's always nil and the same assignment runs on `.appLaunched`). Verify the badge currently shows nothing for notifications; if there's ever a path that sets it non-nil, replace the body with `if state.notificationIndicatorCount != count { state.notificationIndicatorCount = count }; return .none`.
  - **Why:** Eliminates a per-bell MainActor hop.
  - **Risk:** Low — but confirm dock badge isn't expected to render notification counts elsewhere.
  - **Smoke:** Trigger a bell; notification indicator updates; dock icon unchanged.

- **[B1] Cap `WorktreeTerminalState.notifications`**
  - **What:** In `WorktreeTerminalState.swift:1057-1076` `appendNotification`, after `insert(..., at: 0)`, drop tail beyond e.g. 200 entries.
  - **Why:** Bells from interactive shells append forever; `insert(at: 0)` is O(n) and invalidates `@Observable` consumers every time.
  - **Risk:** Behavior change — older notifications drop. If you want to keep "all notifications since launch," skip this and just append-tail + reverse iteration in views. Default proposal caps at 200.
  - **Smoke:** Run a noisy shell loop ringing the bell; notification list updates without UI hitch; oldest entries drop after 200.

- **[A5] Add `.cancellable(id:)` to `lineChanges` effect**
  - **What:** In `RepositoriesFeature.swift:1990-2019` wrap the `.run` effect in `.cancellable(id: CancelID.lineChanges(worktreeID), cancelInFlight: true)`. Add the case to the `CancelID` enum at the top.
  - **Why:** Stops N concurrent git shells per FS event burst per worktree.
  - **Risk:** None — newer request supersedes older.
  - **Smoke:** Make rapid edits in a worktree; line-changes count still updates.

- **[Concurrency M3] Add `continuation.onTermination` to `runProcessStream`**
  - **What:** In `ShellClient.swift:170-235` add `continuation.onTermination = { _ in process.terminate(); outputHandle.readabilityHandler = nil; errorHandle.readabilityHandler = nil }` to the AsyncThrowingStream closure.
  - **Why:** Cancelled shell calls currently leak FDs, accumulator actor, and zombie processes.
  - **Risk:** Low — `process.terminate()` is a SIGTERM, same as the system would send.
  - **Smoke:** Trigger a long-running git op then cancel (e.g. window close mid-PR-fetch); no zombie `git`/`gh` in `ps`.

### 1.2 — Per-keystroke / per-event O(N) → O(1)

- **[S3] Replace per-surface `NSEvent.addLocalMonitorForEvents` with one app-level monitor**
  - **What:** In `GhosttyRuntime.swift` add a single static `NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown])` that routes to the currently-focused `GhosttySurfaceView` via a weak registry. Remove `eventMonitor` and `localEventHandler` from `GhosttySurfaceView.swift:195-198, 207, 1300+`. The registry keys by `SurfaceReference`; the focused surface is already tracked.
  - **Why:** Today, every keystroke fires N closures (one per surface). 120-surface session → 120× keystroke cost.
  - **Risk:** Medium — must preserve "leftMouseDown anywhere routes to whichever surface was hit" and "keyUp fires once for the focused surface." Need to test middle-click / drag / window switching.
  - **Smoke:** Open 5+ tabs with splits; type, click, middle-click, drag-paste; verify all key/mouse behaviors work; verify zero behavior change in `SecureInput` password mode.

### 1.3 — Progress-tick / focus-change fan-out

- **[S4 / B22] Stop rebuilding the whole tab bar on every progress tick**
  - **What:** Two changes, both in `WorktreeTerminalState.swift`:
    1. In `updateRunningState(for:)` (`:898-908, 1102-1110`): compute `isRunningNow` only from leaves whose `progressState` actually transitioned; bail early if `tabIsRunningById[tabId] == isRunningNow`. Only call `tabManager.updateDirty` on a true transition.
    2. In `applySurfaceActivity()` (`:389-415`): only walk the currently-selected tab's tree on focus events; mark off-screen tabs occluded once when their tab is deselected and cache that state. Add `surfaceIdToTabId: [UUID: TerminalTabID]` reverse index for `tabId(containing:)` (`:1088-1093`).
  - **Why:** Long builds (npm, cargo) emit dozens of progress events per second, each currently rebuilding the entire tab bar via the `@Observable tabs` array.
  - **Risk:** Medium — must not miss transitions. Keep a unit test for `updateRunningState` covering: start, repeated mid-run progress, end, multi-leaf running, leaf focus change.
  - **Smoke:** Run `npm install` in tab 1, switch to tab 2; activity dot on tab 1 updates correctly but tab 2 doesn't re-render constantly (verify with `Self._printChanges()` in dev builds).

### 1.4 — Accessibility hot path

- **[S5] Gate accessibility on VoiceOver + debounce `.valueChanged` post**
  - **What:** Three changes:
    1. In `GhosttySurfaceView.swift:437-487, 516-537` short-circuit AX methods with `guard NSWorkspace.shared.isVoiceOverEnabled else { return "" / 0 / NSRange() }` (or `NSAccessibility.isVoiceOverRunning` equivalent).
    2. In `GhosttySurfaceView.swift:14-46` replace the `Task`-based 500ms TTL with a `ContinuousClock.Instant` timestamp check (`get()` checks `now - lastFetched > 0.5` and re-reads; no Task).
    3. In `GhosttySurfaceBridge.swift:190` debounce `NSAccessibility.post(.valueChanged)` to fire at most once per 500ms (use `progressResetTask`-style stored deadline, not a per-call Task).
  - **Why:** AX reads scroll back up to 1M lines; today they run constantly because `.valueChanged` is posted on every `PWD` and the cache is invalidated repeatedly.
  - **Risk:** Behavior change for VoiceOver users (none for everyone else). If you want full VoiceOver compatibility preserved, drop the gate (#1) and keep only #2 and #3 — still a large win.
  - **Smoke:** Without VoiceOver running, type rapidly with shell-integration `cd` calls; CPU stays low. With VoiceOver on, navigate by character — output is still correct.

### 1.5 — Cooperative thread pool relief

- **[S7 partial] Cache `GitClient` + drop needless `MainActor.run`**
  - **What:**
    1. In `Clients/Repositories/GitClientDependency.swift:44-87`, hoist a single `let gitClient = GitClient()` at module load (`liveValue: { let client = GitClient(); return GitClientDependency( … capture client … ) }`).
    2. In `Clients/Git/GitClient.swift:390, 437`, mark `GitWorktreeHeadResolver.headURL` `nonisolated` (verify it only reads `FileManager.default`), and remove the `await MainActor.run { … }` wrappers from `branchName(for:)` and `isWorktreeIndexLocked(_:)`.
  - **Why:** Every git poll currently constructs a `GitClient` then hops to MainActor twice for FileManager calls. With S6 timers landing 60 calls per 30s, this is a sustained MainActor hop storm.
  - **Risk:** Low — `nonisolated` is correct iff the resolver only touches Foundation FS APIs (no `@MainActor` state). Verify with the compiler; Swift 6 strict concurrency will refuse if there's a hidden isolation.
  - **Smoke:** Worktree branches still update on `git checkout`; line-changes counts still appear; nothing logs an isolation violation.

- **[B4 / Concurrency H2] Serial cleanup actor for worktree deletion**
  - **What:** Replace the `Task.detached { try? FileManager.default.removeItem(at: relocatedURL) }` at `GitClient.swift:511-513` with a queued operation on a single dedicated serial actor (or `OperationQueue` with `maxConcurrentOperationCount = 2`).
  - **Why:** Bulk delete fans out unbounded I/O, starving the live terminal's writes.
  - **Risk:** None — cleanup is best-effort either way; serializing only delays cleanup of large worktrees.
  - **Smoke:** Delete several worktrees in succession; terminals stay responsive during cleanup.

- **[B3] `progressResetTask` deadline instead of task-per-report**
  - **What:** In `GhosttySurfaceBridge.swift:215-233` store a `progressResetDeadline: ContinuousClock.Instant`. Spawn one long-lived Task that loops `sleep(until: deadline)` and only mutates state when the deadline actually passes (or the producer extends it). Bursts only mutate the deadline, no allocation.
  - **Why:** Build tools emit thousands of progress reports/min; each currently cancels and reallocates a 15s sleep Task.
  - **Risk:** Low — observable behavior identical (progress resets 15s after last update).
  - **Smoke:** Run `npm install` (lots of progress); progress overlay clears 15s after final report; no Task churn in Instruments.

### Section 1 — testing checklist

After completing 1.1–1.5, run:
- `make check` (format + lint)
- `make test` (full suite)
- Live smoke:
  - [ ] Open 5+ worktrees, each with 2-3 tabs, some with splits. Type in each. No keystroke lag.
  - [ ] Run `npm install` (or `yarn install`) in one tab; switch tabs and type in another. Smooth.
  - [ ] Trigger bells via `printf '\a'`; notification list updates; no growth past 200.
  - [ ] Cancel a long PR fetch (close window mid-fetch); `ps aux | grep -E 'git|gh|tmux' | grep -v grep` shows no leftover processes.
  - [ ] Trigger `git checkout` in a watched worktree; sidebar branch updates within 1s; no UI hitch.
  - [ ] Switch between worktrees rapidly; no stall.
  - [ ] VoiceOver off: CPU during heavy `tail -f` of large log stays reasonable.

---

## Section 2 — Medium impact (architectural — view scoping & state hygiene)

> **Status: ✅ Implemented (7 of 10 sub-items landed; 1 reverted, 2 deferred).**
>
> A key refinement emerged during implementation: TCA `@ObservableState` observation is
> *fine-grained* (`let s = store.state; s.foo` tracks only `foo`), so the literal "rewrite
> views to ViewState structs" (2.1 below) delivers little — the real costs are the
> non-TCA `@Observable` terminal/`CommandKeyObserver` reads, O(N) walks, and per-render
> allocations. The effective work was therefore **scope re-renders to the smallest
> subtree + precompute + gate**, not ViewState projections. The implementation was tracked
> as sub-items 2.1–2.10 (see `~/.claude/plans/swift-strolling-kay.md`); mapping to commits:
>
> | Sub-item | Status | Commit | Notes |
> |---|---|---|---|
> | 2.1 Precompute row summary + hoist `NSFont`/shortcut constants out of `WorktreeRow.body` | ✅ Landed | `066d286` | |
> | 2.2 Scope `CommandKeyObserver` to leaf views (rows / footer / tabs) | ✅ Landed | `5b2d042` | ⌘ tap no longer rebuilds O(N) `worktreeRowSections` / N tab bodies |
> | 2.3 Compute sidebar `orderedWorktreeRows` once, pass into `SidebarListView` | ✅ Landed | `9d2f435` | `worktreeRowSections` left per-repo (hoisting it up would run it *more* often) |
> | 2.4 Gate the toolbar notifications walk on `hasActiveWorktree` | ✅ Landed | `bf267ae` | Deeper per-notification isolation needed an O(1) gate from 2.7; not pursued after 2.7 reverted |
> | 2.5 `@ObservationIgnored` on 36 non-view `GhosttySurfaceState` fields | ✅ Landed | `0ae6923` | Verified by grep: every ignored field is read only by the bridge (writer) + the NSView |
> | 2.6 Gate command-palette item build + fuzzy-scoring on `isPresented`; drop redundant scorer copy | ✅ Landed | `5c1e272` | |
> | 2.7 Explicit unread-notification counter | ❌ **Reverted** | — | Existing reduce already short-circuits (`hasUnseenNotification` uses `contains`) → O(worktrees), not O(N×M). Incremental `Set` counter hit a desync that tripped the DEBUG assert and crashed the test process. Reverted per the zero-regression rule. |
> | 2.8 Shared hover debounce | ⏸️ **Deferred** | — | Each popover's hover task already self-cancels (one short-lived task per transition); consolidating 4 UX-timing-sensitive sites is imperceptible gain for real risk. |
> | 2.9 Debounce settings persistence | ⏸️ **Deferred** | — | Settings window is a transient interaction, not the reported main-UI lag. A blanket `.binding` debounce would delay toggle/picker application; a text-field-only debounce needs fragile keypath matching. |
> | 2.10 Cache `GitClient` + drop `MainActor.run` hop in `branchName`/`isWorktreeIndexLocked` | ✅ Landed | `ef906f1` | The S7 items deferred from Section 1. |
>
> Also note: the deeper `RepositoriesFeature.State` hygiene from the original 2.2 below
> (digest short-circuit, cached `worktreesForInfoWatcher`/`recencyRetentionIDs`,
> `worktreeIndex` reverse map, moving `withAnimation` out of the reducer) was **deferred**
> — high regression risk for low confirmed value once fine-grained observation is accounted
> for. Build + full test suite green after every landed sub-item.

Targets the **write amplification** root cause (S1, S2) and the next tier of per-event walks. Larger changes; higher risk of regression; produces the second-biggest perceptible improvement and prevents the next worktree-count tier from re-introducing lag.

### 2.1 — Narrow view observation (S1)

- **[S1] Replace `store.state` whole reads with scoped view-state structs**
  - **What:** For each of the following views, introduce a small `Equatable` `ViewState` struct projecting only the fields the body actually reads, and use `store.scope(state: { ViewState(from: $0) }, action: \.self)` (or a derived computed property on the reducer):
    - `WorktreeDetailView.swift:11-108`
    - `SidebarListView.swift:11-85`
    - `WorktreeRowsView.swift:11-end`
    - `RepositorySectionView.swift:18-19`
    - `SidebarFooterView.swift:13-17`
  - For each view, audit `body` and computed properties for `state.*` reads; everything read becomes a field on `ViewState`. Keep closure-based actions outside `ViewState` (so equality holds).
  - **Why:** Today, every mutation anywhere in `AppFeature.State` re-evaluates these whole bodies.
  - **Risk:** Medium — easy to forget a field; symptom is "this thing doesn't update anymore." Use the project's existing snapshot/preview tests to detect missing fields; add a quick visual test for each view after migration. Don't migrate `ContentView` itself in this pass — leave it scoped already.
  - **Smoke per view:** Verify every dynamic element of each migrated view still updates (toolbar items, notification badges, archive state, PR check state, run-script state, etc.).

- **[S1 part 2] Split `GhosttySurfaceState`**
  - **What:** Split `GhosttySurfaceState.swift:6-51` into:
    - `GhosttySurfaceUIState` (`@Observable @MainActor`): the fields views read — `searchNeedle`, `searchTotal`, `searchSelected`, `searchFocusCount`, `progressState`, `progressValue`, `title`, `pwd`, `notifications`.
    - `GhosttySurfaceMetaState` (plain `@MainActor` class with stored properties, not `@Observable`): the fields no view reads — `mouseShape`, `mouseVisibility`, `mouseOverLink`, `colorChange*`, `commandExitCode`, `commandDuration`, `keySequenceActive`, `bellCount`.
  - Bridge writes go to the correct one. Wherever a view binds to surface state, point at the UI variant.
  - **Why:** Today, mouse motion (high-frequency Bridge writes) shares an observation registrar with progress/search/title — every mouse-move triggers field-tracking work for every reader.
  - **Risk:** Medium — any forgotten reader will read stale data. Compiler catches missing fields when the type is split; if you keep field names identical and just relocate, the migration is mostly mechanical.
  - **Smoke:** Cursor shape changes correctly on hover; search overlay updates; progress overlay updates; title bar updates.

### 2.2 — TCA state hygiene (S2)

- **[S2 / B25] Cheaper change detection in `applyRepositories`**
  - **What:** In `RepositoriesFeature.swift:2729-2750`, before the full pipeline, compute a digest tuple `[(Repository.ID, Int /* worktree count */, [Worktree.ID])]` from `incomingRepositories` and compare against a cached digest. Short-circuit when equal. Also, stop reading `URL.resourceValues(.creationDateKey)` per-call in `GitClient.swift:87-92` — cache `createdAt` per worktree path, only refresh on add.
  - **Why:** The 30s timer + watcher events trigger this constantly; today equality always misses because `createdAt` jitters.
  - **Risk:** Low — digest is a strict superset of identity; if it matches, state truly hasn't changed structurally.
  - **Smoke:** Add/remove/rename a worktree externally; CherryLily picks it up within next refresh; no spurious sidebar re-renders during idle.

- **[A6] `worktreeIndex` reverse map + in-place keyed mutation**
  - **What:**
    1. Add `var worktreeIndex: [Worktree.ID: Repository.ID]` to `RepositoriesFeature.State`, maintained in `applyRepositories` and on every insert/remove/rename.
    2. Replace `worktree(for:)` and `repositoryID(containing:)` (`RepositoriesFeature.swift:2973-2992, 3027-3036`) with O(1) lookups via the index.
    3. Replace `state.repositories[index] = …` patterns (`:3475-3507, 3286-3304, 3306-3324`) with keyed subscript `state.repositories[id: repoID]?.worktrees[id: wtID] = …`.
  - **Why:** Every notification/file-change/archive currently does O(repos × worktrees) walks; every per-worktree mutation today reallocates a `Repository` struct.
  - **Risk:** Low-medium — must keep index in sync. Add a debug assertion in `#if DEBUG` builds checking index ↔ tree consistency after every mutation.
  - **Smoke:** Rename, archive, restore, delete worktrees from a session with many open repos; sidebar updates correctly.

- **[S2 part 2] Cache `worktreesForInfoWatcher()` + `recencyRetentionIDs(from:)`**
  - **What:** Store both as `@ObservationIgnored` cached properties on `RepositoriesFeature.State` keyed on `repositories.ids.hashValue` and `archivedWorktreeIDs.hashValue`. Recompute only when those change.
  - **Why:** `AppFeature.swift:215-216` recomputes these on every `.repositoriesChanged` fan-out.
  - **Risk:** Low — cache invalidation is hash-keyed and `archivedWorktreeIDs` mutations already happen in known sites.
  - **Smoke:** Add/archive/restore a worktree; watcher receives the right set; command palette recency persists correctly.

- **[B17] Move `withAnimation` out of reducers**
  - **What:** Remove `withAnimation { ... }` wrappers inside `RepositoriesFeature.swift:1345, 1403, 1623, 1699, 1973, 2731`. Instead, attach `.animation(_, value: ...)` to the view side where the visual change actually renders.
  - **Why:** Reducer-side `withAnimation` forces a SwiftUI implicit transaction that re-renders broader subtrees than necessary.
  - **Risk:** Medium — animations that previously fired from action context now need explicit value-keyed animation on the view. Test each: row appearance, archive transitions, notification arrival animation.
  - **Smoke:** Worktree appear/disappear animations still play; notification badge animation still smooth.

### 2.3 — CommandPalette gating

- **[A1] Gate items computation and filtering on `isPresented`**
  - **What:**
    - In `ContentView.swift:91-99` wrap the items argument so it's only computed when `store.commandPalette.isPresented`. Replace `items: CommandPaletteFeature.commandPaletteItems(from: …)` with a conditional / lazy provider.
    - In `CommandPaletteOverlayView.swift:70-93` collapse the four `onChange` handlers + `.task` into a single `.task(id: PaletteWorkKey(isPresented, query, recencyVersion, itemsHash))`. The key is only non-trivial when `isPresented`.
    - In `CommandPaletteFeature.swift:980-983` reuse a single scratch buffer for the fuzzy scorer; drop the redundant `var mutableScores = scores` clone.
  - **Why:** Today, command palette items are recomputed and fuzzy-scored on every store change even when the palette is closed.
  - **Risk:** Low — palette open/close behavior is the boundary. Ensure first-open after a long idle still has items populated promptly.
  - **Smoke:** Open command palette; type; results appear instantly; close palette; type elsewhere; CPU stays low.

### 2.4 — Other A-tier

- **[A2] Debounce binding-driven settings persistence**
  - **What:** In `SettingsFeature.swift:186-190` and `RepositorySettingsFeature.swift:112-125`, debounce `persist(_:)` and the `.delegate(.settingsChanged)` emission to e.g. 300ms after the last binding mutation. Use `.cancellable(id: SettingsPersistID, cancelInFlight: true)` with a clock sleep.
  - **Why:** TextField bindings fire per keystroke; each fires disk writes and 7-effect fan-outs.
  - **Risk:** Low — but a user who edits a text field then quits within 300ms loses the most recent keystrokes. Mitigation: also persist on `.delegate(.willTerminate)` if such a hook exists, otherwise persist on `.binding(.set(\.someField, ...))` for the *first* edit synchronously to seed the file, then debounce subsequent writes.
  - **Smoke:** Edit settings text fields; CPU stays low; values persist correctly across relaunch.

- **[A3] Memoize `toolbarNotificationGroups` + explicit unread counter**
  - **What:**
    - Move `toolbarNotificationGroups` computation into a cached derived property on `RepositoriesFeature.State` (or `WorktreeTerminalManager`), invalidated only when the underlying notification state actually changes.
    - In `WorktreeTerminalManager.swift:365-373` replace the O(worktrees × notifications) walk in `emitNotificationIndicatorCountIfNeeded` with an explicit counter maintained on `appendNotification` / `dismissNotification`.
  - **Why:** Currently runs on every keystroke under any bound text field.
  - **Risk:** Low — counter is straightforward to keep in sync.
  - **Smoke:** Add/clear notifications; toolbar groups & indicator count remain correct.

- **[A7] `WorktreeRow` / `TerminalTabView` `EquatableView` wrapper**
  - **What:**
    - Introduce `WorktreeRowViewState: Equatable` with all 17 fields the body reads (no closures); wrap `WorktreeRow` in `EquatableView { … }` and pass the view-state in.
    - Cache `NSFont.preferredFont(forTextStyle: .body).ascender` in a `static let` (refresh via `NSFont.didChangeNotification` if present, else accept staleness across runtime font changes).
    - Precompute `summaryText: AttributedString` upstream when row data changes; pass as part of the view-state.
    - Same treatment for `TerminalTabView.swift`.
  - **Why:** Sidebar dominates render cost when many repos are open; this is where the post-Section-1 lag will sit.
  - **Risk:** Low-medium — closures-as-actions must not be captured by `ViewState`. Test selection, hover, archive button.
  - **Smoke:** Many worktrees in sidebar; scroll smoothly; row state updates (PR check, run-script, notification dot) still work.

- **[A8] Shared hover debounce for popovers**
  - **What:** Replace per-popover `onHover` `Task` spawning in `NotificationPopoverButton.swift:42-55`, `ToolbarNotificationsPopoverButton.swift:84-97`, `PullRequestChecksPopoverButton.swift:57-70`, `TerminalTabBarTrailingAccessories.swift:178-207` with a single `HoverDebouncer` helper class that maintains one cancellable debounce per call site.
  - **Why:** Mouse traversal across notification rows currently spawns many Tasks/sec.
  - **Risk:** Low — hover behavior unchanged.
  - **Smoke:** Hover across notifications quickly; popovers appear after the same delay; CPU stays low.

### 2.5 — A-tier supporting fixes

- **[A4] Coalesce FS events at DispatchQueue level**
  - **What:** In `WorktreeInfoWatcherManager.swift:180-218`, accumulate `DispatchSource.FileSystemEvent` in an ivar guarded by the queue. Use `DispatchSource`'s built-in event-mask coalescing where possible. Only schedule one `Task { @MainActor in self?.handleEvent(...) }` per debounce window (combine with B19's deadline-based debounce).
  - **Why:** `git fetch` floods MainActor with dozens of Tasks per fetch.
  - **Risk:** Low — events still delivered, just batched.
  - **Smoke:** `git fetch` in a watched worktree; sidebar updates within debounce window; no UI hitch.

### Section 2 — testing checklist

After completing 2.1–2.5, run:
- `make check && make test`
- Visual regression sweep:
  - [ ] Sidebar: every row updates when its data changes (branch, PR status, notification dot, run-script status, archive state, pin state).
  - [ ] Toolbar: notification groups appear/disappear correctly; PR check pill updates.
  - [ ] Repository section: collapse/expand, settings/archive buttons.
  - [ ] Command palette: open, search, select, close — recency persists.
  - [ ] Settings: edit each field; relaunch; values persist.
  - [ ] Terminal: mouse cursor changes shape over links; search overlay highlights; progress overlay appears/disappears; tab activity dot tracks.
  - [ ] Worktree add/remove/rename/archive/restore — sidebar updates; watcher set updates.
  - [ ] Animations: row appearance, notification badge, archive transitions still play.
- Live load test: open 10+ worktrees with 3 tabs each, edit text fields in settings rapidly, open/close command palette; smooth throughout.

---

## Section 3 — Lower impact (polish, hygiene, future-proofing)

> **Status: ✅ Triaged & implemented (4 landed; the rest deferred with rationale).**
> Branch rebased onto `main` first (Sections 1 & 2 were already merged via
> `Merge pwason/PERF` commits). Each landed item: build + full test suite + swiftlint green.
>
> | Item | Status | Commit | Notes |
> |---|---|---|---|
> | B20 — `GhosttyRuntime.surfaceRefs` → `Set` (O(1) register/unregister) | ✅ Landed | `467a135` | Was O(N²) under surface churn |
> | B13 — cache resized open-action app icon (content-keyed `NSCache`) | ✅ Landed | `b3e23c2` | Was decode+lockFocus/draw per toolbar render |
> | M1 — parallelize `pruneWorktrees` in `loadRepositories` | ✅ Landed | `dcd7af9` | Results discarded; refresh latency drops |
> | B14 — exponential backoff on the GitHub-integration recovery poll | ✅ Landed | `dcd7af9` | 15→30→60→120→240→300s; was fixed 15s forever |
> | B5 — `withTaskCancellationHandler` on TmuxClient | ⏸️ Deferred | — | `capture-pane`/`run` are short-lived & self-terminating; refactor risk |
> | B6 — bounded concurrency in `captureAll` | ⏸️ Deferred | — | Hourly/at-quit, short-lived subprocesses; modest value |
> | B18 — cap `pendingEvents` + `.bufferingNewest` | ⏸️ Deferred | — | `.bufferingNewest` could drop semantically-important tab/focus events |
> | B11 — cache `keyboardLayoutId` | ❌ Unsafe | — | Called twice per `keyDown` to detect a layout switch caused *by that key*; caching breaks the detection (the notification can't capture the synchronous mid-event change) |
> | B24 — cache `SplitTree` structural identity | ⏸️ Deferred | — | Value-type caching across mutations; tree is small |
> | B16 — drop immediate PR refresh after merge/close | ❌ Intended | — | A test asserts the immediate refresh is intended behavior |
> | B15 — serialize PR fan-out on availability flip | ⏸️ Deferred | — | Changes replay ordering existing recovery tests depend on |
> | B7 — dedup chatty Ghostty C-actions before the main-thread hop | ⏸️ Deferred | — | Concurrency-sensitive C bridge; high risk |
> | B8 — drop `AnyView` in `TerminalSplitTreeAXContainer` | ⏸️ Deferred | — | Generics + NSHostingView interplay risk |
> | B9 — GeometryReader rewrites (5 views) | ⏸️ Deferred | — | Layout-refactor risk for modest gain |
> | B12 — consolidate per-window NotificationCenter observers | ⏸️ Deferred | — | Structural; medium risk |
> | 3.4 Tier-C sweep (drop `Task { @MainActor }` hops, `ForEach(Array(.enumerated()))`, share `JSONDecoder`, hoist `KeyboardShortcut.display`) | ⏸️ Deferred | — | Either behavior-affecting & unverifiable without manual smoke-test (the Task-hop timing change), per-site risky (index usage), or concurrency-risky (shared decoder) — for collectively negligible gain |
>
> Guiding principle throughout: **zero regressions** supersedes completeness. The deferred
> items are unverifiable-without-manual-testing or carry regression risk disproportionate to
> their (Section-3-level "lower impact") payoff. They can be picked up individually with a
> live smoke-test of the affected behavior.

Tier B and Tier C items. Each is small; together they remove the lingering hitches and lower the floor for sessions with very large worktree/tab counts.

### 3.1 — Per-tab / per-surface micro-optimizations

- **[B12] Consolidate per-window notification observers**
  - **What:** In `GhosttySurfaceView.swift:241-305` move the 5 window-level observers to a single window-level controller that fans out to its surfaces via a weak set. Drop the `Task { @MainActor [weak self] in self?.applyWindowBackgroundAppearance() }` wrappers — the closure is already `.main` queue, so just call directly.
  - **Risk:** Low. Smoke: focus/occlusion/screen changes still update window appearance.

- **[B11] Cache keyboard layout id**
  - **What:** In `GhosttySurfaceView.swift:1316-1332` cache the result of `TISCopyCurrentKeyboardInputSource`. Refresh on `NSTextInputContext.keyboardSelectionDidChangeNotification` (already observed at `GhosttyRuntime.swift:83-92`).
  - **Risk:** Low. Smoke: keystrokes work in default layout; switch keyboard layout → next keystroke uses new id.

- **[B13] Cache resized NSImage in `OpenWorktreeActionMenuLabelView`**
  - **What:** Cache the resized 16×16 NSImage keyed on data hash. Or convert upstream to a `SwiftUI.Image` once when the action data changes.
  - Risk: low.

- **[B24] Cache structural identity at the tree level**
  - **What:** In `SplitTree.swift`, compute `structuralIdentity` once when the tree mutates; expose as `let cached: Int`. Drop the per-body walk in `TerminalSplitTreeView.swift:25-26`.
  - Risk: low.

- **[B8] Drop `AnyView` in `TerminalSplitTreeAXContainer`**
  - **What:** In `TerminalSplitTreeView.swift:291-296` make `TerminalSplitTreeAXContainer` generic over the wrapped view type to avoid `AnyView`. Gate `rootView` reassignment on tree-identity equality.
  - Risk: medium — generics + `NSHostingView` interplay; verify AX still works.

- **[B9] GeometryReader cleanup**
  - **What:** Replace `GeometryReader` usage where the project standard says it shouldn't be needed: `CommandPaletteOverlayView.swift:25-66` (use `.alignmentGuide`/`.containerRelativeFrame`), `SplitView.swift:16-115` (use `HStack/VStack` with `.frame(width: split * available)`), `TerminalSplitTreeView.LeafView` (hoist GR to once-per-tree; use a `DropDelegate`), `TerminalTabsView.swift:20-71` (use `.scrollPosition` + `.containerRelativeFrame`), `GhosttySurfaceProgressBar.swift:38-68` (replace clipped GR with `.frame(maxWidth: .infinity).clipShape(...)`).
  - Risk: medium — each replacement is a small layout refactor; test split resizing, palette positioning, tab overflow scrolling, progress bar animation.

### 3.2 — Concurrency hygiene

- **[B5] `withTaskCancellationHandler` on `TmuxClient` continuations**
  - **What:** Wrap `TmuxClient.run` and `capturePane` (`:82-94, 179-188`) in `withTaskCancellationHandler { … } onCancel: { process.terminate() }`.
  - Risk: low.

- **[B6] Semaphore in `captureAll`**
  - **What:** In `SessionPersistence.captureAll`, wrap tmux captures in `withTaskGroup` with `maxConcurrent = 3-4` (semaphore pattern). Today fans out N concurrent tmux subprocesses.
  - Risk: low (just slower autosave).

- **[B7] Coalesce / dedup chatty Ghostty C-actions before MainActor hop**
  - **What:** In `GhosttyRuntime.swift:209-348` `actionCallback`, for actions known to be high-frequency and idempotent (`MOUSE_SHAPE`, `MOUSE_OVER_LINK`, scrollbar, `PROGRESS_REPORT`), dedup at the worker-thread level via a tiny lock-free state buffer keyed by surface; only post the latest. For actions carrying string buffers (`SET_TITLE`, `PWD`), copy strings to Swift `String` **on the worker thread** before the `DispatchQueue.main.async` to eliminate the use-after-free risk.
  - **Risk:** Medium — concurrency-sensitive; do this last and test under heavy mouse motion + heavy output.
  - **Smoke:** Hover heavily over a noisy `tail -f`; no glitches; no crashes.

- **[B19] Deadline-based debounce in `WorktreeInfoWatcherManager`**
  - **What:** Replace per-event Task recreation in `:220-251` with a stored `Date` deadline + a single timer Task per kind.
  - Risk: low.

- **[B18] Cap `WorktreeTerminalManager.pendingEvents` + use `.bufferingNewest(N)` for the AsyncStream**
  - **What:** In `WorktreeTerminalManager.swift:20, 357-363, 146-163`, cap `pendingEvents` (drop oldest) and create the AsyncStream with `bufferingPolicy: .bufferingNewest(256)`. For latest-wins events (`notificationIndicatorChanged`, `tabFocusChanged`), collapse duplicates.
  - Risk: low — but verify no consumer assumes every event is delivered.

- **[B20] `surfaceRefs` → `Set`**
  - **What:** In `GhosttyRuntime.swift:23, 135-148` replace `[SurfaceReference]` with `Set<SurfaceReference>` (or a dict keyed by `ObjectIdentifier`); drop the per-call linear filter.
  - Risk: low.

### 3.3 — PR refresh hygiene

- **[B14] Exponential backoff for GitHub recovery loop**
  - **What:** In `RepositoriesFeature.swift:2096-2122` replace fixed 15s with exponential backoff (15s → 30s → 60s → 120s → 300s max).
  - Risk: low; recovery just takes slightly longer when CLI is broken.

- **[B15] Serialize PR refresh fan-out on availability flip**
  - **What:** In `RepositoriesFeature.swift:2128-2142`, throttle pending refreshes to e.g. 2 concurrent instead of all-at-once.
  - Risk: low.

- **[B16] Drop duplicate immediate PR refresh**
  - **What:** In `RepositoriesFeature.swift:2300/2332/2362/2497`, remove the immediate `.worktreeInfoEvent(pullRequestRefresh)` after destructive actions; rely on the 2-s debounced one.
  - Risk: low — slight delay in PR state update post-merge.

- **[Reducer M1] Parallelize `pruneWorktrees`**
  - **What:** In `RepositoriesFeature.swift:2613-2615` replace the serial `for root in roots { _ = try? await gitClient.pruneWorktrees(root) }` with a `withTaskGroup` (concurrency capped at 4).
  - Risk: low.

### 3.4 — Tier C polish sweep

- **[Concurrency H8 + repeats]** Drop `Task { @MainActor [weak self] in self?.foo() }` wrappers from closures already on MainActor across `GhosttySurfaceView`, `WindowFocusObserverView`, `GhosttySurfaceBridge`, `HourlyAutosaveTimer`. Replace with direct calls (or `MainActor.assumeIsolated { … }` where needed).
- **[B23] Scope `commandKeyObserver.isPressed`** — pull the read into a tiny sibling view so the rest of `WorktreeRowsView` / `SidebarFooterView` doesn't rebuild on every ⌘ tap.
- **[SwiftUI L1, L2]** Replace `ForEach(Array(x.enumerated()), id: \.element)` with `ForEach(x, id: \.id)`.
- **[SwiftUI L4 / H8]** Hoist constant `KeyboardShortcut(...).display` strings to `static let`.
- **[Concurrency L4]** Share a single `JSONDecoder` per client class.
- Sweep `GhosttySurfaceView` for the remaining `bridge.state.<field> = value` writes that don't guard equality — apply the B10 pattern broadly.

### Section 3 — testing checklist

- `make check && make test`
- Live:
  - [ ] All animations and transitions still smooth.
  - [ ] Mouse hover over noisy `tail -f`; no glitches, no crashes.
  - [ ] GitHub-CLI fails (e.g. `gh auth logout`); recovery loop backs off; reauth works.
  - [ ] All inline checks from Section 1 + Section 2 still pass.
  - [ ] Memory in Instruments after 1 hour of normal use: flat or near-flat.

---

## Notes for the implementer

- **Branch naming:** follow project rule — name the branch by section (e.g. `pwason/perf-section-1`).
- **Per-fix commits:** keep commits small; the section ID (e.g. `[S3]`, `[B10]`) goes in the commit subject.
- **Don't combine sections.** Test each in isolation. If a Section-1 fix exposes a regression, it's much easier to bisect within a small section.
- **If a fix turns out to be wrong** (e.g. nonisolated migration violates an isolation in S7), back it out cleanly and note in this file; don't try to force it.
- **After each section's PR**, update this file's section heading with status (e.g. `## Section 1 — Highest impact (✅ landed in PR #123)`).
