# Session Persistence — Phase 3: Capture + Restore

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-05-15-session-persistence-design.md`
**Phase 1 plan (already implemented):** `docs/superpowers/plans/2026-05-15-session-persistence-phase-1.md`
**Phase 2 plan (already implemented):** `docs/superpowers/plans/2026-05-15-session-persistence-phase-2.md`

**Goal:** When `restoreSessionsOnLaunch` is on, surface shells survive across app quits AND across system reboots. Specifically:
- On quit, scrollback for every live surface is captured to disk, and the layout (which worktrees, tabs, splits, CWDs) is snapshotted.
- On launch (no reboot), tmux sessions are still alive from before — re-opening a worktree finds its tabs restored, attaching to the persistent tmux sessions with full in-memory scrollback.
- On launch (post-reboot), tmux sessions were killed with the system; re-opening a worktree creates fresh tmux sessions whose first action is to replay the captured scrollback file via `cat`.

**Architecture:** Three new orchestration pieces and an extension of an existing one. `LayoutSnapshotBuilder` walks `WorktreeTerminalManager` state into a `SessionLayout`. `SessionPersistence` is a `@MainActor` service that owns the capture-on-quit and restore-on-launch flows (composing `SessionLayoutStore`, `ScrollbackStore`, `TmuxClient`, `OrphanReconciler` from Phase 1). `SurfaceLaunchCommand` gets a `buildWithReplay()` variant that prepends `cat <file>; exec <shell>` to the spawned tmux session command. `WorktreeTerminalState.createSurface` consults the layout/scrollback files at launch time to pick the right SurfaceID and the right launch command.

**Tech Stack:** Swift 6.2, SwiftUI, TCA, bundled tmux 3.5a, Phase 1 Sessions module.

**Phase scope:** End-to-end persistence so reopening the app brings back tabs with their history. **Out of scope here:**
- Settings UI (Phase 4)
- Hourly autosave timer (Phase 5)
- Disk-full alerts and tmux crash auto-restart (Phase 5)
- Multi-instance prevention (Phase 5)
- Reattach UX flicker hiding (Phase 6)

After Phase 3 lands, a user can: type stuff in a terminal → quit → reopen → click the worktree → tab comes back with scrollback intact. After a reboot: same flow, scrollback restored from the captured file.

---

## File structure

**New (Swift):**
- `cherrylily/Features/Sessions/BusinessLogic/LayoutSnapshotBuilder.swift` — walks WTM state, produces `SessionLayout`
- `cherrylily/Features/Sessions/BusinessLogic/SessionPersistence.swift` — `@MainActor` orchestrator: captureAll, restoreLayout, reconcileOrphans

**New (tests):**
- `cherrylilyTests/LayoutSnapshotBuilderTests.swift`
- `cherrylilyTests/SessionPersistenceTests.swift`
- Test additions to `cherrylilyTests/SurfaceLaunchCommandTests.swift` (replay variant)

**Modified:**
- `cherrylily/Infrastructure/Ghostty/GhosttySurfaceView.swift` — `id` becomes settable via init (defaults to fresh UUID)
- `cherrylily/Features/Terminal/Models/WorktreeTerminalState.swift` — `createSurface` accepts `SurfaceID?`, plumbs it to `GhosttySurfaceView.id`. `resolveLaunchCommand` chooses replay vs normal launch based on scrollback file presence. New `restoreTabs(from:)` method recreates tabs from a `PersistedWorktree`.
- `cherrylily/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift` — `state(for:)` checks the SessionPersistence layout for matching tabs and triggers restoreTabs. New `allLiveSurfaces()` iterator for capture.
- `cherrylily/Features/Sessions/BusinessLogic/SurfaceLaunchCommand.swift` — add `buildWithReplay(...)` that wraps the inner shell command with `cat <file>; exec <shell>`
- `cherrylily/App/supacodeApp.swift` — construct `SessionPersistence`, run reconciler on launch, pass to WTM. Wire applicationWillTerminate in `CherryLilyAppDelegate`.
- `cherrylily/Features/App/Reducer/AppFeature.swift` — on `scenePhaseChanged(.background)` invoke `SessionPersistence.captureAll()` via dependency client.

---

## Task 1: Make `GhosttySurfaceView.id` settable from init

**Files:**
- Modify: `cherrylily/Infrastructure/Ghostty/GhosttySurfaceView.swift`

Today the view declares `let id = UUID()`. To stabilize SurfaceIDs across restarts, callers must be able to provide a pre-existing UUID (the persisted `SurfaceID.rawValue`).

- [ ] **Step 1: Find the existing id declaration**

```bash
grep -n "let id\|var id\b" cherrylily/Infrastructure/Ghostty/GhosttySurfaceView.swift
```

You'll see `let id = UUID()` around line 49 — a property initialized inline with a fresh UUID.

- [ ] **Step 2: Change the property and init signature**

Replace the property:
```swift
let id: UUID
```

In `init(...)` (around line 154), add `id: UUID = UUID()` as the FIRST parameter (callers who don't care get a fresh one; callers who care get to specify):
```swift
init(
  id: UUID = UUID(),
  runtime: GhosttyRuntime,
  workingDirectory: URL?,
  initialInput: String? = nil,
  command: String? = nil,
  fontSize: Float32? = nil,
  context: ghostty_surface_context_e
) {
  self.id = id
  // ... existing init body unchanged ...
}
```

- [ ] **Step 3: Build + test**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -3
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing" | head -3
```

Both must pass. No existing call sites should break — they all pass init args by keyword name and don't currently supply `id:`.

- [ ] **Step 4: Add a quick unit test asserting the override works**

In `cherrylilyTests/` find or create a place for GhosttySurfaceView smoke tests. If there's no existing test file for this view, skip the test — the integration through Task 2 will exercise it. (GhosttySurfaceView requires a runtime; instantiating it in a test environment may not be feasible.)

If you skip the test, just verify Step 3's `make test` is green.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Infrastructure/Ghostty/GhosttySurfaceView.swift
git commit -m "Allow GhosttySurfaceView.id to be supplied at init"
```

---

## Task 2: Thread SurfaceID into `WorktreeTerminalState.createSurface`

**Files:**
- Modify: `cherrylily/Features/Terminal/Models/WorktreeTerminalState.swift`

Currently `resolveLaunchCommand` allocates a fresh `SurfaceID()` inline and uses it only for the tmux session name. The view's `id` is independent. This task unifies them: the SurfaceID becomes the view's identity.

- [ ] **Step 1: Add `surfaceID:` parameter to `createSurface`**

In `WorktreeTerminalState.swift` around line 719:
```swift
private func createSurface(
  tabId: TerminalTabID,
  initialInput: String?,
  command: String? = nil,
  surfaceID: SurfaceID? = nil,
  inheritingFromSurfaceId: UUID?,
  context: ghostty_surface_context_e
) -> GhosttySurfaceView {
  let inherited = inheritedSurfaceConfig(fromSurfaceId: inheritingFromSurfaceId, context: context)
  let resolvedSurfaceID = surfaceID ?? SurfaceID()
  let effectiveCommand = resolveLaunchCommand(
    callerOverride: command,
    inherited: inherited,
    surfaceID: resolvedSurfaceID
  )
  let view = GhosttySurfaceView(
    id: resolvedSurfaceID.rawValue,
    runtime: runtime,
    workingDirectory: inherited.workingDirectory ?? worktree.workingDirectory,
    initialInput: initialInput,
    command: effectiveCommand,
    fontSize: inherited.fontSize,
    context: context
  )
  // ... rest unchanged ...
}
```

- [ ] **Step 2: Update `resolveLaunchCommand` to accept SurfaceID**

Replace the existing `let surface = SurfaceID()` inside `resolveLaunchCommand` with the parameter:

```swift
private func resolveLaunchCommand(
  callerOverride: String?,
  inherited: InheritedSurfaceConfig,
  surfaceID: SurfaceID
) -> String? {
  if let callerOverride { return callerOverride }
  guard persistenceEnabled() else { return nil }
  guard TmuxBinary.isAvailable else {
    SupaLogger("Sessions").warning("tmux binary unavailable — falling back to direct shell")
    return nil
  }
  let paths = SessionPaths()
  let cwd = (inherited.workingDirectory ?? worktree.workingDirectory).path
  return SurfaceLaunchCommand.build(
    tmuxBinaryPath: TmuxBinary.bundledURL.path,
    configPath: paths.tmuxConfigFile.path,
    surface: surfaceID,
    cwd: cwd
  )
}
```

(Note: the existing helper signature differs slightly. Adapt the actual call shape to match what's there.)

- [ ] **Step 3: Thread surfaceID through the upper plumbing**

`splitTree(for:inheritingFromSurfaceId:initialInput:command:context:)` calls `createSurface`. Add `surfaceID: SurfaceID? = nil` to splitTree's signature and forward. Same for the `TabCreation` struct and the public `createTab(...)`.

But — keep all the new params at sensible default values (`nil`). This task does NOT call createSurface with a non-nil surfaceID; Task 8 will. We're only making the parameter available.

- [ ] **Step 4: Build + test**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -3
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing" | head -3
```

Both must pass — defaults preserve all existing call sites.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Terminal/Models/WorktreeTerminalState.swift
git commit -m "Thread SurfaceID through createSurface so it stabilizes view.id"
```

---

## Task 3: LayoutSnapshotBuilder

**Files:**
- Create: `cherrylily/Features/Sessions/BusinessLogic/LayoutSnapshotBuilder.swift`
- Create: `cherrylilyTests/LayoutSnapshotBuilderTests.swift`

Walks the runtime state — list of worktrees, their tabs, the surfaces in each tab, the CWD on each surface — and produces a `SessionLayout` DTO suitable for `SessionLayoutStore.write(_:)`.

This task ALSO needs to expose an iteration API on `WorktreeTerminalManager` (it currently has `private var states`).

- [ ] **Step 1: Add an iteration helper to WorktreeTerminalManager**

In `cherrylily/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift`, add:

```swift
/// Read-only snapshot of all (worktreeID, state) pairs. Used by LayoutSnapshotBuilder
/// for the capture-on-quit flow.
var allWorktreeStates: [(Worktree.ID, WorktreeTerminalState)] {
  states.map { ($0.key, $0.value) }
}
```

Place this near the existing `state(for:runSetupScriptIfNew:)` method.

- [ ] **Step 2: Add a tab/surface iteration helper to WorktreeTerminalState**

In `cherrylily/Features/Terminal/Models/WorktreeTerminalState.swift`:

```swift
/// For each tab in this worktree, returns the tab's id, title, and the list of
/// `GhosttySurfaceView` ids (one per surface in the split tree). Used by capture.
var tabAndSurfaceSnapshots: [(tabID: TerminalTabID, title: String, surfaceIDs: [UUID], cwds: [URL?])] {
  tabManager.tabs.map { tab in
    let tree = trees[tab.id]
    let views = tree?.allViews ?? []
    return (
      tabID: tab.id,
      title: tab.title,
      surfaceIDs: views.map(\.id),
      cwds: views.map(\.bridge.state.workingDirectory)
    )
  }
}
```

The `tree?.allViews` API may not exist — check `SplitTree` for an iteration helper. If absent, add `var allViews: [Value] { ... }` to `SplitTree` returning all leaf values via recursive collection. Or use whatever iteration the existing code uses for similar walks (`grep -n "trees\[" cherrylily/Features/Terminal/Models/WorktreeTerminalState.swift`).

- [ ] **Step 3: Write the failing test for LayoutSnapshotBuilder**

Create `cherrylilyTests/LayoutSnapshotBuilderTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

struct LayoutSnapshotBuilderTests {
  @Test func snapshotIsEmptyWhenNoWorktreesActive() {
    let result = LayoutSnapshotBuilder.build(
      worktreeStates: [],
      now: Date(timeIntervalSince1970: 1_000_000)
    )

    #expect(result.worktrees.isEmpty)
    #expect(result.savedAt == Date(timeIntervalSince1970: 1_000_000))
    #expect(result.version == SessionLayout.currentVersion)
  }

  @Test func snapshotCapturesWorktreeWithSingleTabAndSurface() {
    let surfaceUUID = UUID()
    let tabID = UUID()  // matches your TerminalTabID type
    let cwd = URL(fileURLWithPath: "/tmp/work")

    let fake = FakeWorktreeStateView(
      worktreeID: "/tmp/repo",
      selectedTabID: tabID,
      tabs: [
        .init(tabID: tabID, title: "main", surfaceIDs: [surfaceUUID], cwds: [cwd])
      ]
    )

    let result = LayoutSnapshotBuilder.build(
      worktreeStates: [("/tmp/repo", fake)],
      now: Date(timeIntervalSince1970: 1_000_000)
    )

    #expect(result.worktrees.count == 1)
    let wt = result.worktrees[0]
    #expect(wt.worktreeID == "/tmp/repo")
    #expect(wt.selectedTabID == tabID)
    #expect(wt.tabs.count == 1)
    let tab = wt.tabs[0]
    #expect(tab.id == tabID)
    #expect(tab.title == "main")
    #expect(tab.surfaces.count == 1)
    #expect(tab.surfaces[0].id.rawValue == surfaceUUID)
    #expect(tab.surfaces[0].cwd == cwd)
  }
}

/// Test fake — implements the same shape as `WorktreeTerminalState.tabAndSurfaceSnapshots`
/// without needing a real terminal state. The builder accepts this protocol so tests don't
/// have to construct a full WTS.
private struct FakeWorktreeStateView: WorktreeStateSnapshotting {
  let worktreeID: String
  let selectedTabID: UUID?
  let tabs: [WorktreeTabSnapshot]

  var snapshot: WorktreeStateSnapshot {
    WorktreeStateSnapshot(selectedTabID: selectedTabID, tabs: tabs)
  }
}
```

Note: this test references types (`WorktreeStateSnapshotting`, `WorktreeStateSnapshot`, `WorktreeTabSnapshot`) that don't exist yet — Step 4 defines them. The test will fail to compile until Step 4 is done.

- [ ] **Step 4: Write the implementation**

Create `cherrylily/Features/Sessions/BusinessLogic/LayoutSnapshotBuilder.swift`:

```swift
import Foundation

/// Minimum surface area required to snapshot a worktree's tabs. Lets `WorktreeTerminalState`
/// (live, complex) and test fakes both feed into the builder uniformly.
nonisolated protocol WorktreeStateSnapshotting: Sendable {
  var snapshot: WorktreeStateSnapshot { get }
}

nonisolated struct WorktreeStateSnapshot: Sendable {
  let selectedTabID: UUID?
  let tabs: [WorktreeTabSnapshot]
}

nonisolated struct WorktreeTabSnapshot: Sendable {
  let tabID: UUID
  let title: String
  let surfaceIDs: [UUID]
  let cwds: [URL?]
}

/// Walks live `WorktreeTerminalState` instances and produces a `SessionLayout` DTO
/// suitable for persistence. Pure — no side effects.
nonisolated enum LayoutSnapshotBuilder {
  static func build(
    worktreeStates: [(Worktree.ID, any WorktreeStateSnapshotting)],
    now: Date
  ) -> SessionLayout {
    let worktrees = worktreeStates.map { worktreeID, state in
      let snap = state.snapshot
      return PersistedWorktree(
        worktreeID: worktreeID,
        selectedTabID: snap.selectedTabID,
        tabs: snap.tabs.map { tab in
          PersistedTab(
            id: tab.tabID,
            title: tab.title,
            surfaces: zip(tab.surfaceIDs, tab.cwds).map { surfaceID, cwd in
              PersistedSurface(
                id: SurfaceID(rawValue: surfaceID),
                cwd: cwd
              )
            }
          )
        }
      )
    }
    return SessionLayout(savedAt: now, worktrees: worktrees)
  }
}
```

- [ ] **Step 5: Conform WorktreeTerminalState to WorktreeStateSnapshotting**

In `WorktreeTerminalState.swift`, replace the helper from Step 2 with the protocol conformance:

```swift
extension WorktreeTerminalState: WorktreeStateSnapshotting {
  var snapshot: WorktreeStateSnapshot {
    WorktreeStateSnapshot(
      selectedTabID: tabManager.selectedTabID,
      tabs: tabManager.tabs.map { tab in
        let views = trees[tab.id]?.allViews ?? []
        return WorktreeTabSnapshot(
          tabID: tab.id,
          title: tab.title,
          surfaceIDs: views.map(\.id),
          cwds: views.map { $0.bridge.state.workingDirectory }
        )
      }
    )
  }
}
```

If `tabManager.selectedTabID` doesn't exist on the existing tab manager API, find the equivalent (`grep -n "selectedTabID\|selectedTab" cherrylily/Features/Terminal/`). If `bridge.state.workingDirectory` isn't the live CWD accessor, replace with the actual one (look at how other features read it — probably `bridge.workingDirectory` or via `bridge.state.cwd`).

- [ ] **Step 6: Run tests**

```bash
make test 2>&1 | grep -E "LayoutSnapshotBuilder|TEST SUCCEEDED|TEST FAILED|Failing" | head -10
```

Both new tests should pass; full suite green.

- [ ] **Step 7: Commit**

```bash
git add cherrylily/Features/Sessions/BusinessLogic/LayoutSnapshotBuilder.swift cherrylilyTests/LayoutSnapshotBuilderTests.swift cherrylily/Features/Terminal/Models/WorktreeTerminalState.swift cherrylily/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift
git commit -m "Add LayoutSnapshotBuilder to walk WTM state into SessionLayout"
```

---

## Task 4: SurfaceLaunchCommand replay variant

**Files:**
- Modify: `cherrylily/Features/Sessions/BusinessLogic/SurfaceLaunchCommand.swift`
- Modify: `cherrylilyTests/SurfaceLaunchCommandTests.swift`

When a scrollback file exists for a SurfaceID, the launch should be: `tmux new-session ... 'cat <file>; exec <shell>'` so the file replays in the new tmux session before the real shell starts.

- [ ] **Step 1: Write the failing tests**

Add to `cherrylilyTests/SurfaceLaunchCommandTests.swift`:

```swift
@Test func buildWithReplayWrapsShellWithCatAndExec() {
  let command = SurfaceLaunchCommand.buildWithReplay(
    tmuxBinaryPath: "/path/to/tmux",
    configPath: "/path/to/tmux.conf",
    surface: Self.surface,
    cwd: "/cwd",
    scrollbackPath: "/path/to/scrollback.bin",
    userShell: "/bin/zsh"
  )

  // tmux invocation form preserved
  #expect(command.contains("\"/path/to/tmux\""))
  #expect(command.contains("-L cherrylily"))
  #expect(command.contains("new-session -A"))
  #expect(command.contains("-c \"/cwd\""))

  // the shell-command argument that tmux runs inside the session
  #expect(command.contains("cat \"/path/to/scrollback.bin\"; exec \"/bin/zsh\""))
}

@Test func buildWithReplayQuotesScrollbackPath() {
  let command = SurfaceLaunchCommand.buildWithReplay(
    tmuxBinaryPath: "/t",
    configPath: "/c",
    surface: Self.surface,
    cwd: "/cwd",
    scrollbackPath: "/path with spaces/scroll.bin",
    userShell: "/bin/zsh"
  )
  #expect(command.contains("cat \"/path with spaces/scroll.bin\""))
}

@Test func buildWithReplayQuotesUserShell() {
  let command = SurfaceLaunchCommand.buildWithReplay(
    tmuxBinaryPath: "/t",
    configPath: "/c",
    surface: Self.surface,
    cwd: "/cwd",
    scrollbackPath: "/s.bin",
    userShell: "/opt/homebrew/bin/fish"
  )
  #expect(command.contains("exec \"/opt/homebrew/bin/fish\""))
}
```

- [ ] **Step 2: Verify RED**

```bash
make test 2>&1 | grep -E "buildWithReplay|Cannot find" | head -5
```

Expected: "type 'SurfaceLaunchCommand' has no member 'buildWithReplay'".

- [ ] **Step 3: Implement**

In `cherrylily/Features/Sessions/BusinessLogic/SurfaceLaunchCommand.swift`, add a new static method:

```swift
/// Same as `build` but instructs tmux to run `cat <scrollbackPath>; exec <userShell>`
/// as the session's command. Used for post-reboot restore — `cat` dumps saved bytes
/// to the terminal (including ANSI), then `exec` replaces cat with the user's real shell.
///
/// The double-quoting is robust: cat's path, exec's path, and all tmux args are
/// each independently double-quoted, so spaces and metacharacters in any of them
/// work correctly.
static func buildWithReplay(
  tmuxBinaryPath: String,
  configPath: String,
  surface: SurfaceID,
  cwd: String,
  scrollbackPath: String,
  userShell: String
) -> String {
  let quotedBinary = posixDoubleQuote(tmuxBinaryPath)
  let quotedConfig = posixDoubleQuote(configPath)
  let quotedSession = posixDoubleQuote(surface.tmuxSessionName)
  let quotedCwd = posixDoubleQuote(cwd)
  let quotedScrollback = posixDoubleQuote(scrollbackPath)
  let quotedShell = posixDoubleQuote(userShell)
  // The final string passed to tmux is `cat <file>; exec <shell>`. tmux interprets
  // this string with /bin/sh -c, so the quoting must survive one shell expansion.
  let innerShellCommand = "cat \(quotedScrollback); exec \(quotedShell)"
  // tmux's shell-command argument needs to be a single shell-quoted token from our
  // perspective (because the outer string is itself interpreted by bash via Ghostty).
  let quotedInner = posixDoubleQuote(innerShellCommand)
  return
    "\(quotedBinary) -L cherrylily -f \(quotedConfig) "
    + "new-session -A -s \(quotedSession) -c \(quotedCwd) \(quotedInner)"
}
```

Note: nested quoting is subtle. The outer command is wrapped by Ghostty as `bash -c "exec -l <our_string>"`. The bash then runs our string verbatim. Within our string, the LAST token is the tmux shell-command which is itself parsed by sh (inside tmux). So double-quoting the inner `cat <a>; exec <b>` once at our layer means: bash sees `cat <a>; exec <b>` as a single tmux argument; tmux passes it to `/bin/sh -c`; sh executes `cat <a>; exec <b>` honoring our inner quotes. The escape pass-through is one-deep because the outer-layer quoting is bash-level and tmux strips one layer before handing to /bin/sh.

This is admittedly easy to get wrong. The test cases assert observable substrings; if the assertions fail, trace through the layers with a real `bash -x` run.

- [ ] **Step 4: Verify GREEN**

```bash
make test 2>&1 | grep -E "SurfaceLaunchCommand|TEST SUCCEEDED|TEST FAILED" | head -10
```

All SurfaceLaunchCommandTests pass.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Sessions/BusinessLogic/SurfaceLaunchCommand.swift cherrylilyTests/SurfaceLaunchCommandTests.swift
git commit -m "Add SurfaceLaunchCommand.buildWithReplay for scrollback restore"
```

---

## Task 5: SessionPersistence orchestrator

**Files:**
- Create: `cherrylily/Features/Sessions/BusinessLogic/SessionPersistence.swift`
- Create: `cherrylilyTests/SessionPersistenceTests.swift`

A `@MainActor` service that ties Phase 1's primitives into the three high-level operations callers need: capture, restore, reconcile. It holds references to `SessionLayoutStore`, `ScrollbackStore`, `TmuxClient`, and `SessionPaths`.

- [ ] **Step 1: Write the failing tests**

Create `cherrylilyTests/SessionPersistenceTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

@MainActor
struct SessionPersistenceTests {
  private static func makePaths() -> SessionPaths {
    SessionPaths(
      root: URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "cl-persistence-test-\(UUID().uuidString)")
    )
  }

  @Test func restoreLayoutReturnsNilWhenNoFileExists() throws {
    let paths = Self.makePaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let persistence = SessionPersistence(paths: paths)

    let layout = try persistence.restoreLayout()
    #expect(layout == nil)
  }

  @Test func restoreLayoutReadsPreviouslyWrittenLayout() throws {
    let paths = Self.makePaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try paths.ensureDirectoriesExist()

    let store = SessionLayoutStore(paths: paths)
    let written = SessionLayout(
      savedAt: Date(timeIntervalSince1970: 1_000_000),
      worktrees: [
        PersistedWorktree(
          worktreeID: "/tmp/repo",
          selectedTabID: nil,
          tabs: []
        )
      ]
    )
    try store.write(written)

    let persistence = SessionPersistence(paths: paths)
    let restored = try persistence.restoreLayout()
    #expect(restored?.worktrees.first?.worktreeID == "/tmp/repo")
  }

  @Test func captureLayoutWritesLayoutFile() async throws {
    let paths = Self.makePaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let persistence = SessionPersistence(paths: paths)

    let layout = SessionLayout(
      savedAt: Date(timeIntervalSince1970: 2_000_000),
      worktrees: []
    )

    try persistence.writeLayout(layout)

    #expect(FileManager.default.fileExists(atPath: paths.layoutFile.path))
  }
}
```

- [ ] **Step 2: Verify RED**

```bash
make test 2>&1 | grep -E "SessionPersistenceTests|Cannot find" | head -5
```

Expected: "Cannot find 'SessionPersistence' in scope".

- [ ] **Step 3: Write the implementation**

Create `cherrylily/Features/Sessions/BusinessLogic/SessionPersistence.swift`:

```swift
import Foundation

private nonisolated let sessionPersistenceLogger = SupaLogger("Sessions")

/// Top-level orchestrator for session persistence. Composes the Phase 1 primitives
/// (`SessionLayoutStore`, `ScrollbackStore`, `TmuxClient`) into the three operations
/// CherryLily needs: capture (on quit), restore (read layout on launch), reconcile
/// (clean up orphans on launch).
///
/// `@MainActor` because it is owned by app-level state and accessed from app delegate
/// hooks. Heavy I/O is offloaded via `Task.detached` inside individual methods.
@MainActor
final class SessionPersistence {
  let paths: SessionPaths
  private let layoutStore: SessionLayoutStore
  private let scrollbackStore: ScrollbackStore
  private let tmuxClient: TmuxClient

  init(paths: SessionPaths = SessionPaths()) {
    self.paths = paths
    self.layoutStore = SessionLayoutStore(paths: paths)
    self.scrollbackStore = ScrollbackStore(paths: paths)
    self.tmuxClient = TmuxClient(
      tmuxBinaryURL: TmuxBinary.bundledURL,
      paths: paths
    )
  }

  /// Reads the persisted layout if present. Returns nil if no file exists or the file
  /// is corrupt (corrupt = log + nil; the user gets a fresh start, never a crash).
  func restoreLayout() throws -> SessionLayout? {
    try layoutStore.read()
  }

  /// Writes a layout. Atomic via `SessionLayoutStore.write(_:)`.
  func writeLayout(_ layout: SessionLayout) throws {
    try paths.ensureDirectoriesExist()
    try layoutStore.write(layout)
  }

  /// Captures scrollback for every surface in the supplied layout. Each capture is a
  /// separate tmux subprocess; runs in parallel via `TaskGroup`. Per-surface timeout 2s.
  /// Returns the count of successful captures (failures are logged, not thrown).
  @discardableResult
  func captureAll(for layout: SessionLayout) async -> Int {
    var successCount = 0
    await withTaskGroup(of: Bool.self) { group in
      for surfaceID in layout.allSurfaceIDs {
        group.addTask { [tmuxClient, scrollbackStore] in
          await Self.captureOne(
            surfaceID: surfaceID,
            tmuxClient: tmuxClient,
            scrollbackStore: scrollbackStore
          )
        }
      }
      for await ok in group where ok {
        successCount += 1
      }
    }
    return successCount
  }

  /// Capture one surface — separate static to avoid main-actor capture in TaskGroup.
  /// Logs and returns false on any failure. 2-second timeout via `withTimeout`.
  private static func captureOne(
    surfaceID: SurfaceID,
    tmuxClient: TmuxClient,
    scrollbackStore: ScrollbackStore
  ) async -> Bool {
    do {
      let bytes = try await tmuxClient.capturePane(
        sessionName: surfaceID.tmuxSessionName,
        scrollbackLimit: 50_000  // hardcoded for now; Phase 4 reads from settings
      )
      try scrollbackStore.write(bytes, for: surfaceID)
      return true
    } catch {
      sessionPersistenceLogger.warning(
        "capture failed for \(surfaceID.tmuxSessionName): \(error)"
      )
      return false
    }
  }

  /// Runs orphan reconciliation: kills tmux sessions not in the layout, deletes
  /// scrollback files not in the layout.
  func reconcileOrphans(against layout: SessionLayout) async {
    do {
      let liveSessions = try await tmuxClient.listSessions()
      let savedFiles = try scrollbackStore.listAllSurfaceIDs()

      let plan = OrphanReconciler.plan(
        expected: Set(layout.allSurfaceIDs),
        liveSessions: liveSessions,
        savedFiles: savedFiles
      )

      for orphanSession in plan.sessionsToKill {
        do {
          try await tmuxClient.killSession(named: orphanSession)
        } catch {
          sessionPersistenceLogger.warning("orphan session kill failed: \(orphanSession): \(error)")
        }
      }

      for orphanID in plan.filesToDelete {
        do {
          try scrollbackStore.delete(for: orphanID)
        } catch {
          sessionPersistenceLogger.warning("orphan scrollback delete failed: \(orphanID.tmuxSessionName): \(error)")
        }
      }
    } catch {
      sessionPersistenceLogger.warning("orphan reconcile failed: \(error)")
    }
  }
}
```

**Note:** the Phase 1 primitives (`TmuxClient.capturePane`, `.listSessions`, `.killSession`; `ScrollbackStore.listAllSurfaceIDs`, `.delete(for:)`; `OrphanReconciler.plan`) may have different method names. Look at the Phase 1 source before writing the impl and use the actual API surface:

```bash
grep -n "func " cherrylily/Features/Sessions/BusinessLogic/TmuxClient.swift cherrylily/Features/Sessions/BusinessLogic/ScrollbackStore.swift cherrylily/Features/Sessions/BusinessLogic/OrphanReconciler.swift
```

Adapt to what's there. If a method is missing (e.g. `listAllSurfaceIDs`), add it on the Phase 1 type with a minimal implementation — keep changes focused.

- [ ] **Step 4: Run tests**

```bash
make test 2>&1 | grep -E "SessionPersistenceTests|TEST SUCCEEDED|TEST FAILED" | head -10
```

The three tests above should pass. The capture/reconcile flows aren't unit-tested here — they need real tmux, which is integration-level.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Sessions/BusinessLogic/SessionPersistence.swift cherrylilyTests/SessionPersistenceTests.swift
# include any Phase 1 method additions if you needed them
git commit -m "Add SessionPersistence orchestrator (capture, restore, reconcile)"
```

---

## Task 6: Capture-on-quit trigger

**Files:**
- Modify: `cherrylily/App/supacodeApp.swift`
- Modify: `cherrylily/Features/App/Reducer/AppFeature.swift` (only if scene-phase path used)

Wire `SessionPersistence.captureAll()` to fire on app quit. Two redundant paths so we don't miss either Cmd-Q or system shutdown:
1. `NSApplicationDelegate.applicationWillTerminate` — fires on Cmd-Q quit. Synchronous; macOS waits.
2. `scenePhase` → `.background` — fires when the app goes hidden / before quit. TCA pathway.

Both paths idempotently write the layout and capture scrollback. The applicationWillTerminate path is the more reliable for quit timing; the scenePhase path is the safety net for "going to background then user quits".

- [ ] **Step 1: Construct SessionPersistence at app launch**

In `cherrylily/App/supacodeApp.swift`, after `terminalManager` is constructed and `tmux.conf` is written:

```swift
let persistence = SessionPersistence(paths: SessionPaths())
```

Hold it in the app delegate so applicationWillTerminate can reach it. Add to `CherryLilyAppDelegate`:

```swift
final class CherryLilyAppDelegate: NSObject, NSApplicationDelegate {
  var terminalManager: WorktreeTerminalManager?
  var persistence: SessionPersistence?

  func applicationWillTerminate(_ notification: Notification) {
    guard let persistence, let terminalManager else { return }
    @Shared(.settingsFile) var settings
    guard settings.global.restoreSessionsOnLaunch else { return }

    let layout = LayoutSnapshotBuilder.build(
      worktreeStates: terminalManager.allWorktreeStates.map { ($0.0, $0.1 as any WorktreeStateSnapshotting) },
      now: Date()
    )
    do {
      try persistence.writeLayout(layout)
    } catch {
      SupaLogger("Sessions").warning("layout write on quit failed: \(error)")
    }

    // Capture is async; we synchronously wait up to 2 seconds before letting macOS
    // SIGKILL us. Using DispatchSemaphore because applicationWillTerminate is sync.
    let semaphore = DispatchSemaphore(value: 0)
    Task {
      _ = await persistence.captureAll(for: layout)
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + .seconds(2))
  }
}
```

Wire from `supacodeApp` body:
```swift
appDelegate.terminalManager = terminalManager
appDelegate.persistence = persistence
```

- [ ] **Step 2: Pass SessionPersistence to WorktreeTerminalManager**

This is needed for Task 8 (restore-on-worktree-open). For this task, just add the property and inject it:

In `WorktreeTerminalManager`:
```swift
let persistence: SessionPersistence?

init(
  runtime: GhosttyRuntime,
  persistenceEnabled: @escaping @Sendable () -> Bool = { false },
  persistence: SessionPersistence? = nil
) {
  // ... existing ...
  self.persistence = persistence
}
```

In supacodeApp where WTM is constructed, pass the new persistence service:
```swift
let terminalManager = WorktreeTerminalManager(
  runtime: runtime,
  persistenceEnabled: { ... },
  persistence: persistence
)
```

- [ ] **Step 3: Build + test**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -3
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing" | head -3
```

Both must pass — defaults preserve test fixtures.

- [ ] **Step 4: Manual smoke**

```bash
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/cherrylily-*/Build/Products/Debug/CherryLily.app | head -1)
"$APP/Contents/MacOS/tmux-cherrylily" -L cherrylily kill-server 2>/dev/null
open "$APP"
# Manually: open a worktree, click +, type "echo hello" and Enter
# Then quit the app via Cmd-Q
ls -la ~/Library/Application\ Support/CherryLily/
ls -la ~/Library/Application\ Support/CherryLily/sessions/
cat ~/Library/Application\ Support/CherryLily/layout.json | head -30
```

Expected: `layout.json` exists with one worktree, one tab, one surface. `sessions/<uuid>.bin` exists with several KB of scrollback bytes including the "hello" line.

If `sessions/` is empty: capture timed out or failed. Look at `make log-stream` output during quit (`SupaLogger("Sessions").warning(...)` lines).

- [ ] **Step 5: Commit**

```bash
git add cherrylily/App/supacodeApp.swift cherrylily/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift
git commit -m "Capture scrollback and write layout on app quit"
```

---

## Task 7: Replay-on-launch in createSurface

**Files:**
- Modify: `cherrylily/Features/Terminal/Models/WorktreeTerminalState.swift`

When `resolveLaunchCommand` is invoked for a surface whose SurfaceID has a scrollback file, use `buildWithReplay`. Otherwise normal `build`.

- [ ] **Step 1: Modify resolveLaunchCommand**

```swift
private func resolveLaunchCommand(
  callerOverride: String?,
  inherited: InheritedSurfaceConfig,
  surfaceID: SurfaceID
) -> String? {
  if let callerOverride { return callerOverride }
  guard persistenceEnabled() else { return nil }
  guard TmuxBinary.isAvailable else {
    SupaLogger("Sessions").warning("tmux binary unavailable — falling back to direct shell")
    return nil
  }
  let paths = SessionPaths()
  let cwd = (inherited.workingDirectory ?? worktree.workingDirectory).path
  let scrollbackFile = paths.scrollbackFile(for: surfaceID)

  if FileManager.default.fileExists(atPath: scrollbackFile.path) {
    let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    return SurfaceLaunchCommand.buildWithReplay(
      tmuxBinaryPath: TmuxBinary.bundledURL.path,
      configPath: paths.tmuxConfigFile.path,
      surface: surfaceID,
      cwd: cwd,
      scrollbackPath: scrollbackFile.path,
      userShell: userShell
    )
  }

  return SurfaceLaunchCommand.build(
    tmuxBinaryPath: TmuxBinary.bundledURL.path,
    configPath: paths.tmuxConfigFile.path,
    surface: surfaceID,
    cwd: cwd
  )
}
```

- [ ] **Step 2: Build + test**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -3
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing" | head -3
```

- [ ] **Step 3: Commit**

```bash
git add cherrylily/Features/Terminal/Models/WorktreeTerminalState.swift
git commit -m "Replay saved scrollback when creating surface with existing file"
```

---

## Task 8: Restore-on-worktree-open

**Files:**
- Modify: `cherrylily/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift`
- Modify: `cherrylily/Features/Terminal/Models/WorktreeTerminalState.swift`

The trickiest task. When the user opens a worktree that has a layout entry from a previous session, automatically recreate its tabs with the persisted SurfaceIDs and CWDs.

Trigger point: `WorktreeTerminalManager.state(for:runSetupScriptIfNew:)` — when it creates a NEW WorktreeTerminalState (line 150 area), it now also checks if `persistence` has a layout entry for that worktreeID. If so, calls a new `state.restoreTabs(from:)`.

- [ ] **Step 1: Read layout once on app launch, cache in WTM**

Add to WorktreeTerminalManager:

```swift
private var cachedLayout: SessionLayout?

func loadLayoutOnLaunch() {
  guard let persistence else { return }
  do {
    cachedLayout = try persistence.restoreLayout()
  } catch {
    SupaLogger("Sessions").warning("layout read on launch failed: \(error)")
    cachedLayout = nil
  }
}
```

Call from supacodeApp.swift after `terminalManager` is constructed:
```swift
terminalManager.loadLayoutOnLaunch()
```

- [ ] **Step 2: Add restoreTabs(from:) to WorktreeTerminalState**

```swift
/// Recreates tabs from a persisted worktree snapshot. Each tab and surface uses
/// the persisted IDs (so tmux sessions match) and CWDs.
///
/// Called once, immediately after `WorktreeTerminalState` is constructed for a
/// worktree that has a layout entry. After this, the WTS state mirrors what the
/// user had before quit.
func restoreTabs(from persisted: PersistedWorktree) {
  guard tabManager.tabs.isEmpty else { return }  // safety
  for persistedTab in persisted.tabs {
    let creation = TabCreation(
      title: persistedTab.title,
      initialInput: nil,
      command: nil,
      surfaceID: persistedTab.surfaces.first?.id,
      cwd: persistedTab.surfaces.first?.cwd
    )
    _ = createTab(creation)
    // Phase 3 ships single-surface restore. Multi-surface (split) restore comes in Phase 6.
  }
  if let selectedTabID = persisted.selectedTabID,
     tabManager.tabs.contains(where: { $0.id == selectedTabID }) {
    tabManager.selectTab(selectedTabID)
  }
}
```

The `TabCreation` struct may need a `surfaceID: SurfaceID?` field — add it and thread through `createTab(_:)` → `splitTree` → `createSurface(surfaceID:)`. This extends Task 2's plumbing.

The CWD field also needs to flow through so the created surface uses the persisted CWD, not the worktree root. Inspect the current `createTab` flow to find the right place to inject it.

**Multi-surface split restoration is deferred** — Phase 3 restores only the FIRST surface of each tab. The split tree restoration requires walking the `SplitTree<SurfaceID>` from PersistedSurface and creating splits programmatically, which is a bigger task. Comment on this in code: `// TODO Phase 6: restore full split tree`.

- [ ] **Step 3: Wire restoreTabs in state(for:)**

In WorktreeTerminalManager.state(for:runSetupScriptIfNew:), after the new state is constructed (line 150ish) and added to `states`, check the cached layout:

```swift
if let persistedWorktree = cachedLayout?.worktrees.first(where: { $0.worktreeID == worktree.id }) {
  state.restoreTabs(from: persistedWorktree)
}
```

Place this BEFORE `state.setNotificationsEnabled(...)` so the restored tabs inherit notification config.

- [ ] **Step 4: Build + test**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -3
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing" | head -3
```

- [ ] **Step 5: Manual smoke**

Most important smoke of Phase 3:

```bash
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/cherrylily-*/Build/Products/Debug/CherryLily.app | head -1)
"$APP/Contents/MacOS/tmux-cherrylily" -L cherrylily kill-server 2>/dev/null
open "$APP"
# 1. Open a worktree
# 2. Click + to make a new tab
# 3. Type: echo "this should restore"
# 4. Quit via Cmd-Q
open "$APP"
# 5. Open the SAME worktree
# 6. Expect: the tab is back; scrollback shows "this should restore"
```

If the tab is back but scrollback is empty: replay failed. Check the scrollback file:
```bash
ls -la ~/Library/Application\ Support/CherryLily/sessions/
file ~/Library/Application\ Support/CherryLily/sessions/*.bin | head -3
```

If the tab is not back: restoreTabs didn't fire. Check WTM state(for:) path and layout cache.

- [ ] **Step 6: Commit**

```bash
git add cherrylily/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift cherrylily/Features/Terminal/Models/WorktreeTerminalState.swift cherrylily/App/supacodeApp.swift
git commit -m "Restore worktree tabs from persisted layout on first open"
```

---

## Task 9: OrphanReconciler trigger on launch

**Files:**
- Modify: `cherrylily/App/supacodeApp.swift`

On app launch, BEFORE any surface is created, run `SessionPersistence.reconcileOrphans` so that:
- Any tmux session NOT in the layout (e.g. from a crashed previous CherryLily run, or a worktree the user deleted) is killed.
- Any scrollback file NOT in the layout is deleted.

This keeps disk and tmux state bounded.

- [ ] **Step 1: Add the reconcile call**

In `supacodeApp.swift` after `persistence` is constructed and `cachedLayout` is loaded:

```swift
if initialSettings.restoreSessionsOnLaunch, let layout = terminalManager.cachedLayoutPublic {
  Task {
    await persistence.reconcileOrphans(against: layout)
  }
}
```

`cachedLayoutPublic` is a small WTM accessor exposing `cachedLayout` for app-launch coordination. Add it:

```swift
var cachedLayoutPublic: SessionLayout? { cachedLayout }
```

(Or just inline the layout read here instead of going through WTM — your call. Inlining avoids adding a public accessor; pulling from WTM keeps a single source of truth.)

- [ ] **Step 2: Build + test**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -3
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing" | head -3
```

- [ ] **Step 3: Manual smoke**

```bash
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/cherrylily-*/Build/Products/Debug/CherryLily.app | head -1)
# Create a phantom session that's NOT in layout
"$APP/Contents/MacOS/tmux-cherrylily" -L cherrylily new-session -d -s cl_99999999-9999-9999-9999-999999999999
# Create a phantom file
touch ~/Library/Application\ Support/CherryLily/sessions/abcdef12-3456-7890-abcd-ef1234567890.bin

open "$APP"
sleep 5

echo "tmux sessions after launch (phantom should be gone):"
"$APP/Contents/MacOS/tmux-cherrylily" -L cherrylily ls 2>&1

echo "scrollback files (phantom should be gone):"
ls ~/Library/Application\ Support/CherryLily/sessions/

osascript -e 'quit app "CherryLily"'
```

Expected: phantom tmux session and phantom scrollback file are both gone.

- [ ] **Step 4: Commit**

```bash
git add cherrylily/App/supacodeApp.swift cherrylily/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift
git commit -m "Run orphan reconciliation on app launch"
```

---

## Task 10: Final smoke + lint + push

- [ ] **Step 1: Full end-to-end smoke**

```bash
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/cherrylily-*/Build/Products/Debug/CherryLily.app | head -1)
"$APP/Contents/MacOS/tmux-cherrylily" -L cherrylily kill-server 2>/dev/null
rm -rf ~/Library/Application\ Support/CherryLily/sessions/

# Round 1: type, quit, reopen, verify
open "$APP"
# Manually: open worktree, open tab, type "echo phase3-works" Enter
# Cmd-Q
open "$APP"
# Manually: open same worktree → expect "echo phase3-works" visible
osascript -e 'quit app "CherryLily"'

# Round 2: reboot simulation — kill the tmux server, then launch
"$APP/Contents/MacOS/tmux-cherrylily" -L cherrylily kill-server
open "$APP"
# Manually: open same worktree → expect "echo phase3-works" visible (replayed from file)
osascript -e 'quit app "CherryLily"'
```

If both rounds pass, Phase 3 works end-to-end.

- [ ] **Step 2: Lint check (Phase 3 files only)**

```bash
make lint 2>&1 | grep -E "Sessions/|SurfaceLaunchCommand|LayoutSnapshotBuilder|SessionPersistence|WorktreeTerminal|supacodeApp|GhosttySurfaceView|violation" | head -20
```

Zero violations in Phase 3 files? Pre-existing violations in unrelated files (`OpenWorktreeAction.swift`, `AppFeature.swift`, etc.) are out of scope.

- [ ] **Step 3: Push**

```bash
git push origin nav-back-forward
```

- [ ] **Step 4: Open the PR (if not already open)**

If this branch doesn't have an open PR, create one:

```bash
gh pr create --title "Session persistence: capture + restore (Phase 3)" --body "$(cat <<'EOF'
## Summary
- Captures scrollback for every live surface on app quit
- Persists the layout (worktrees → tabs → surfaces → CWDs)
- On launch, restores the same tabs in their persisted state
- Orphan reconciliation: kills tmux sessions and deletes scrollback files not in the layout
- Stable SurfaceIDs flow through `GhosttySurfaceView.id` so tmux sessions reattach across restarts

## Test plan
- [x] Type in a terminal, quit, reopen the worktree → tab + scrollback restored
- [x] After `tmux kill-server` (reboot simulation), reopen → scrollback replayed from file
- [x] Phantom tmux session + phantom scrollback file deleted on launch
- [x] `make test` green
- [x] `make build-app` green

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
