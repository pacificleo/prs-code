# Session Persistence — Phase 2: Surface Launch Wrapping

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-05-15-session-persistence-design.md`
**Phase 1 plan (already implemented):** `docs/superpowers/plans/2026-05-15-session-persistence-phase-1.md`

**Goal:** When the (hidden) `restoreSessionsOnLaunch` setting is on, every Ghostty surface launches its shell wrapped in a `tmux new-session -A -s cl_<uuid>` invocation. When off, today's behavior is preserved exactly. No UI yet (Phase 4), no capture/replay yet (Phase 3) — Phase 2 just wires the launch path.

**Architecture:** Three new pieces — `TmuxConfig` (writes the managed tmux.conf), `SurfaceLaunchCommand` (composes the tmux argv as a shell-quoted string Ghostty can `exec`), and a `restoreSessionsOnLaunch: Bool` setting field. `GhosttySurfaceView` gains an optional `command:` init parameter that forwards to `ghostty_surface_config_s.command`. `WorktreeTerminalState.createSurface` consults the flag and either passes the tmux command (when on) or nothing (when off, preserving today's "use Ghostty's default shell" behavior).

**Tech Stack:** Swift 6.2, SwiftUI, TCA, Ghostty C API (`ghostty.h`), bundled tmux 3.5a.

**Phase scope:** Surface launch wrapping only. **Out of scope here:**
- Settings UI (Phase 4)
- Capture-on-quit (Phase 3)
- Replay-on-launch (Phase 3)
- Layout serialization triggered (Phase 3 — the *types* exist from Phase 1, but no caller writes them yet)
- SurfaceIDs surviving app restart (Phase 3 — Phase 2 generates fresh UUIDs each launch)

After Phase 2 lands, you can flip the setting in code and observe that surfaces launch through tmux. They'll still die when you quit the app (no capture). That's expected — Phase 3 ships the "shells survive restart" behavior.

---

## File structure

**New (Swift):**
- `cherrylily/Features/Sessions/BusinessLogic/TmuxConfig.swift` — generates managed tmux.conf content
- `cherrylily/Features/Sessions/BusinessLogic/TmuxConfigWriter.swift` — writes tmux.conf to disk (idempotent)
- `cherrylily/Features/Sessions/BusinessLogic/SurfaceLaunchCommand.swift` — composes the tmux invocation as a single shell-quoted command string

**New (tests):**
- `cherrylilyTests/TmuxConfigTests.swift`
- `cherrylilyTests/TmuxConfigWriterTests.swift`
- `cherrylilyTests/SurfaceLaunchCommandTests.swift`

**Modified:**
- `cherrylily/Features/Settings/Models/GlobalSettings.swift` — add `restoreSessionsOnLaunch: Bool` (default true)
- `cherrylily/Features/Settings/Reducer/SettingsFeature.swift` — mirror the field
- `cherrylily/Infrastructure/Ghostty/GhosttySurfaceView.swift` — add optional `command:` init parameter; forward to `ghostty_surface_config_s.command`
- `cherrylily/Features/Terminal/Models/WorktreeTerminalState.swift` — `createSurface` consults a persistence flag and computes the tmux command when on
- `cherrylily/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift` — exposes the persistence flag to `WorktreeTerminalState`
- `cherrylily/App/supacodeApp.swift` — write `tmux.conf` on launch when persistence is on

---

## Task 1: Add `restoreSessionsOnLaunch` setting field

**Files:**
- Modify: `cherrylily/Features/Settings/Models/GlobalSettings.swift`
- Modify: `cherrylily/Features/Settings/Reducer/SettingsFeature.swift`

Mirrors the established pattern (`confirmBeforeQuit`, `confirmBeforeClosingTabs`, etc.). No UI — just the field. Default **true** per the spec.

- [ ] **Step 1: Read GlobalSettings.swift to find the right insertion points**

```bash
grep -n "confirmBeforeClosingTabs" cherrylily/Features/Settings/Models/GlobalSettings.swift
```

You'll see the field declared once, defaulted in `static let default`, accepted in `init(...)`, assigned in init body, and decoded in `init(from:)`. Mirror that for `restoreSessionsOnLaunch`.

- [ ] **Step 2: Add the field to GlobalSettings**

Add `var restoreSessionsOnLaunch: Bool` immediately after `var confirmBeforeClosingTabs: Bool`.

In `static let default`, add `restoreSessionsOnLaunch: true,` after `confirmBeforeClosingTabs: true,`.

In `init(...)` parameter list, add `restoreSessionsOnLaunch: Bool = true,` after `confirmBeforeClosingTabs: Bool = true,`.

In init body, add `self.restoreSessionsOnLaunch = restoreSessionsOnLaunch` after `self.confirmBeforeClosingTabs = confirmBeforeClosingTabs`.

In `init(from decoder:)`, add:
```swift
restoreSessionsOnLaunch =
  try container.decodeIfPresent(Bool.self, forKey: .restoreSessionsOnLaunch)
  ?? Self.default.restoreSessionsOnLaunch
```
after the corresponding `confirmBeforeClosingTabs` block.

- [ ] **Step 3: Add the field to SettingsFeature.State**

Read `cherrylily/Features/Settings/Reducer/SettingsFeature.swift`. Find every reference to `confirmBeforeClosingTabs` (state property declaration, init copy, `globalSettings` computed property, `settingsLoaded` reducer body) and add the same five mirror points for `restoreSessionsOnLaunch`.

- [ ] **Step 4: Build and run tests**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -3
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing tests" | head -3
```

Both should succeed. Some existing tests use `GlobalSettings.default` and may need updating if they assert on equality — check the failure output and add `restoreSessionsOnLaunch:` to any failing fixture init.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Settings/Models/GlobalSettings.swift cherrylily/Features/Settings/Reducer/SettingsFeature.swift
# include any test fixture updates if needed
git commit -m "Add restoreSessionsOnLaunch setting (default on, no UI yet)"
```

---

## Task 2: TmuxConfig — managed config text generator

**Files:**
- Create: `cherrylily/Features/Sessions/BusinessLogic/TmuxConfig.swift`
- Create: `cherrylilyTests/TmuxConfigTests.swift`

A pure function that returns the text of the managed tmux.conf. Pure, easy to unit-test, isolated from disk.

- [ ] **Step 1: Write the failing test**

Create `cherrylilyTests/TmuxConfigTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

struct TmuxConfigTests {
  @Test func includesScrollbackLimit() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(conf.contains("set -g history-limit 50000"))
  }

  @Test func hidesStatusBar() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(conf.contains("set -g status off"))
  }

  @Test func disablesMouse() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(conf.contains("set -g mouse off"))
  }

  @Test func unbindsAllPrefixAndRootKeys() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(conf.contains("unbind -a -T prefix"))
    #expect(conf.contains("unbind -a -T root"))
  }

  @Test func setsDefaultShell() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/opt/homebrew/bin/fish")
    #expect(conf.contains("set -g default-shell \"/opt/homebrew/bin/fish\""))
  }

  @Test func enablesPassthroughForOSC() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(conf.contains("set -g allow-passthrough on"))
  }

  @Test func setsXtermTerminal() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(conf.contains("set -g default-terminal \"xterm-256color\""))
  }

  @Test func keepsSessionsAliveOnDetach() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(conf.contains("set -g destroy-unattached off"))
  }

  @Test func headerCommentMarksAutoGenerated() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(conf.hasPrefix("# Auto-generated by CherryLily. Do not edit."))
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | grep -E "TmuxConfigTests|Cannot find" | head -10
```

Expected: build error "Cannot find 'TmuxConfig' in scope" — RED.

- [ ] **Step 3: Write minimal implementation**

Create `cherrylily/Features/Sessions/BusinessLogic/TmuxConfig.swift`:

```swift
import Foundation

/// Generates the text of the managed tmux configuration file.
/// Locks down tmux so the user perceives shells as if they were running directly:
/// no status bar, no key bindings, no mouse interception.
nonisolated enum TmuxConfig {
  /// Returns the full text of the managed `tmux.conf` for the given parameters.
  static func generate(scrollbackLimit: Int, userShell: String) -> String {
    """
    # Auto-generated by CherryLily. Do not edit.

    set -g history-limit \(scrollbackLimit)
    set -g status off
    set -g mouse off
    set -g default-terminal "xterm-256color"
    set -g destroy-unattached off
    set -g detach-on-destroy off
    set -g default-shell "\(userShell)"

    # Lock down all keybindings — CherryLily handles all UX
    unbind -a -T prefix
    unbind -a -T root
    unbind -a -T copy-mode
    unbind -a -T copy-mode-vi

    # Tab title / notifications passthrough
    set -g allow-passthrough on
    set -g set-titles on
    set -g set-titles-string "#{pane_title}"
    """
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
make test 2>&1 | grep -E "TmuxConfigTests|TEST SUCCEEDED|TEST FAILED|Failing" | head -5
```

Expected: All 9 TmuxConfigTests pass.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Sessions/BusinessLogic/TmuxConfig.swift cherrylilyTests/TmuxConfigTests.swift
git commit -m "Add TmuxConfig managed configuration generator"
```

---

## Task 3: TmuxConfigWriter — writes config to disk idempotently

**Files:**
- Create: `cherrylily/Features/Sessions/BusinessLogic/TmuxConfigWriter.swift`
- Create: `cherrylilyTests/TmuxConfigWriterTests.swift`

Wraps `TmuxConfig` + a write to `paths.tmuxConfigFile`. Idempotent — if the file already exists with the same content, no write.

- [ ] **Step 1: Write the failing test**

Create `cherrylilyTests/TmuxConfigWriterTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

struct TmuxConfigWriterTests {
  private static func makeTempPaths() -> SessionPaths {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "cl-tmuxconf-test-\(UUID().uuidString)")
    return SessionPaths(root: temp)
  }

  @Test func writesConfigToTmuxConfigFile() throws {
    let paths = Self.makeTempPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let writer = TmuxConfigWriter(paths: paths)
    try writer.writeIfChanged(scrollbackLimit: 12345, userShell: "/bin/zsh")

    let written = try String(contentsOf: paths.tmuxConfigFile, encoding: .utf8)
    #expect(written.contains("set -g history-limit 12345"))
  }

  @Test func writeIfChangedSkipsWriteWhenContentMatches() throws {
    let paths = Self.makeTempPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let writer = TmuxConfigWriter(paths: paths)

    try writer.writeIfChanged(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    let firstMtime = try FileManager.default.attributesOfItem(
      atPath: paths.tmuxConfigFile.path
    )[.modificationDate] as? Date
    #expect(firstMtime != nil)

    // Wait a tick so a write would visibly change mtime.
    Thread.sleep(forTimeInterval: 0.05)

    try writer.writeIfChanged(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    let secondMtime = try FileManager.default.attributesOfItem(
      atPath: paths.tmuxConfigFile.path
    )[.modificationDate] as? Date

    #expect(firstMtime == secondMtime, "writeIfChanged should not rewrite identical content")
  }

  @Test func writeIfChangedRewritesWhenScrollbackLimitChanges() throws {
    let paths = Self.makeTempPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let writer = TmuxConfigWriter(paths: paths)

    try writer.writeIfChanged(scrollbackLimit: 10_000, userShell: "/bin/zsh")
    try writer.writeIfChanged(scrollbackLimit: 50_000, userShell: "/bin/zsh")

    let written = try String(contentsOf: paths.tmuxConfigFile, encoding: .utf8)
    #expect(written.contains("set -g history-limit 50000"))
    #expect(!written.contains("set -g history-limit 10000"))
  }

  @Test func writeIfChangedCreatesParentDirectoryIfMissing() throws {
    let paths = Self.makeTempPaths()
    // Note: do NOT call ensureDirectoriesExist — the writer must create the dir itself
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let writer = TmuxConfigWriter(paths: paths)

    try writer.writeIfChanged(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(FileManager.default.fileExists(atPath: paths.tmuxConfigFile.path))
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | grep -E "TmuxConfigWriterTests|Cannot find" | head -5
```

Expected: "Cannot find 'TmuxConfigWriter' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `cherrylily/Features/Sessions/BusinessLogic/TmuxConfigWriter.swift`:

```swift
import Foundation

private nonisolated let tmuxConfigLogger = SupaLogger("TmuxConfig")

/// Writes the managed tmux.conf to disk.
/// Skips the write when on-disk content already matches what `TmuxConfig.generate`
/// would produce — keeps file mtime stable across no-op invocations.
nonisolated struct TmuxConfigWriter: Sendable {
  let paths: SessionPaths

  func writeIfChanged(scrollbackLimit: Int, userShell: String) throws {
    let desired = TmuxConfig.generate(scrollbackLimit: scrollbackLimit, userShell: userShell)

    if let existing = try? String(contentsOf: paths.tmuxConfigFile, encoding: .utf8),
       existing == desired
    {
      return
    }

    try paths.ensureDirectoriesExist()
    try desired.data(using: .utf8)?.write(to: paths.tmuxConfigFile, options: [.atomic])
    tmuxConfigLogger.debug("wrote tmux.conf with history-limit=\(scrollbackLimit)")
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
make test 2>&1 | grep -E "TmuxConfigWriterTests|TEST SUCCEEDED|TEST FAILED|Failing" | head -5
```

Expected: All 4 TmuxConfigWriterTests pass.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Sessions/BusinessLogic/TmuxConfigWriter.swift cherrylilyTests/TmuxConfigWriterTests.swift
git commit -m "Add TmuxConfigWriter with idempotent disk write"
```

---

## Task 4: SurfaceLaunchCommand — composes the tmux invocation string

**Files:**
- Create: `cherrylily/Features/Sessions/BusinessLogic/SurfaceLaunchCommand.swift`
- Create: `cherrylilyTests/SurfaceLaunchCommandTests.swift`

Ghostty's surface config takes a single C string for `command`. Ghostty parses that as a shell command via its built-in command parser. We need to compose a properly-quoted tmux invocation:

```
/path/to/tmux-cherrylily -L cherrylily -f /path/to/tmux.conf new-session -A -s cl_<uuid>
```

Quoting is critical because the binary path AND the config path may contain spaces (`/Users/Some Name/...`).

- [ ] **Step 1: Write the failing test**

Create `cherrylilyTests/SurfaceLaunchCommandTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

struct SurfaceLaunchCommandTests {
  private static let dummyBinary = URL(fileURLWithPath: "/bin/tmux-cherrylily")
  private static let dummyConfig = URL(fileURLWithPath: "/tmp/tmux.conf")

  @Test func commandStartsWithBinaryPath() {
    let id = SurfaceID()
    let cmd = SurfaceLaunchCommand.compose(
      tmuxBinary: Self.dummyBinary,
      tmuxConfig: Self.dummyConfig,
      socketName: "cherrylily",
      surfaceID: id
    )
    #expect(cmd.hasPrefix("'/bin/tmux-cherrylily'"))
  }

  @Test func commandIncludesSocketAndConfigFlags() {
    let id = SurfaceID()
    let cmd = SurfaceLaunchCommand.compose(
      tmuxBinary: Self.dummyBinary,
      tmuxConfig: Self.dummyConfig,
      socketName: "cherrylily",
      surfaceID: id
    )
    #expect(cmd.contains("-L 'cherrylily'"))
    #expect(cmd.contains("-f '/tmp/tmux.conf'"))
  }

  @Test func commandAttachOrCreatesSessionByID() {
    let id = SurfaceID(rawValue: UUID(uuidString: "7C8C2B5E-5D7E-4C7E-9C7E-6C7E7C7E7C7E")!)
    let cmd = SurfaceLaunchCommand.compose(
      tmuxBinary: Self.dummyBinary,
      tmuxConfig: Self.dummyConfig,
      socketName: "cherrylily",
      surfaceID: id
    )
    #expect(cmd.contains("new-session -A -s 'cl_7c8c2b5e-5d7e-4c7e-9c7e-6c7e7c7e7c7e'"))
  }

  @Test func quotesBinaryPathContainingSpaces() {
    let binary = URL(fileURLWithPath: "/Applications/My App.app/Contents/MacOS/tmux-cherrylily")
    let cmd = SurfaceLaunchCommand.compose(
      tmuxBinary: binary,
      tmuxConfig: Self.dummyConfig,
      socketName: "cherrylily",
      surfaceID: SurfaceID()
    )
    #expect(cmd.hasPrefix("'/Applications/My App.app/Contents/MacOS/tmux-cherrylily'"))
  }

  @Test func escapesSingleQuotesInPaths() {
    // Pathological: a path containing a literal single quote.
    let config = URL(fileURLWithPath: "/tmp/it's.conf")
    let cmd = SurfaceLaunchCommand.compose(
      tmuxBinary: Self.dummyBinary,
      tmuxConfig: config,
      socketName: "cherrylily",
      surfaceID: SurfaceID()
    )
    // POSIX-shell single-quote escape: '...'\''...'
    #expect(cmd.contains(#"'/tmp/it'\''s.conf'"#))
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | grep -E "SurfaceLaunchCommandTests|Cannot find" | head -5
```

Expected: "Cannot find 'SurfaceLaunchCommand' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `cherrylily/Features/Sessions/BusinessLogic/SurfaceLaunchCommand.swift`:

```swift
import Foundation

/// Composes the shell command Ghostty should `exec` for a tmux-backed surface.
///
/// Ghostty takes a single C string for `surface_config.command` and parses it as
/// a shell command. We build a properly POSIX-quoted argv string here so paths
/// with spaces or quotes work correctly.
nonisolated enum SurfaceLaunchCommand {
  /// Composes:
  ///   '<tmuxBinary>' -L '<socketName>' -f '<tmuxConfig>' new-session -A -s 'cl_<uuid>'
  static func compose(
    tmuxBinary: URL,
    tmuxConfig: URL,
    socketName: String,
    surfaceID: SurfaceID
  ) -> String {
    let parts: [String] = [
      shellQuote(tmuxBinary.path),
      "-L", shellQuote(socketName),
      "-f", shellQuote(tmuxConfig.path),
      "new-session", "-A", "-s", shellQuote(surfaceID.tmuxSessionName),
    ]
    return parts.joined(separator: " ")
  }

  /// POSIX shell single-quote escape. Wraps the value in `'...'` and replaces any
  /// literal single quote with `'\''` (close, escaped quote, reopen).
  static func shellQuote(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "'", with: #"'\''"#)
    return "'\(escaped)'"
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
make test 2>&1 | grep -E "SurfaceLaunchCommandTests|TEST SUCCEEDED|TEST FAILED|Failing" | head -5
```

Expected: All 5 SurfaceLaunchCommandTests pass.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Sessions/BusinessLogic/SurfaceLaunchCommand.swift cherrylilyTests/SurfaceLaunchCommandTests.swift
git commit -m "Add SurfaceLaunchCommand for composing tmux invocation"
```

---

## Task 5: GhosttySurfaceView — accept optional `command:` parameter

**Files:**
- Modify: `cherrylily/Infrastructure/Ghostty/GhosttySurfaceView.swift`

Ghostty's `ghostty_surface_config_s` has a `const char* command` field (header line 447). We need to expose it through `GhosttySurfaceView.init` so callers can override the shell.

- [ ] **Step 1: Find the existing init and createSurface**

```bash
grep -n "init(\|createSurface\|workingDirectoryCString\|initialInputCString" cherrylily/Infrastructure/Ghostty/GhosttySurfaceView.swift | head -20
```

You should see an `init` taking `workingDirectory:`, `initialInput:`, `fontSize:`, `context:`, and a `private var workingDirectoryCString: UnsafeMutablePointer<CChar>?` declared near `initialInputCString`.

- [ ] **Step 2: Add a `command: String?` init parameter mirroring `initialInput`**

Find the existing init signature. Add `command: String? = nil,` after `initialInput: String? = nil,`.

Add a `private let commandCString: UnsafeMutablePointer<CChar>?` next to `initialInputCString`.

In the init body, mirror the `initialInputCString = ...` assignment for `commandCString`:
```swift
if let command {
  commandCString = command.withCString { strdup($0) }
} else {
  commandCString = nil
}
```

In `deinit` (where `initialInputCString` is freed), free `commandCString` similarly.

In `createSurface()` (around line 837), add immediately after `config.initial_input = ...`:
```swift
config.command = commandCString.map { UnsafePointer($0) }
```

- [ ] **Step 3: Build to confirm no Ghostty header signature issues**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -5
```

Expected: BUILD SUCCEEDED. (The Ghostty header at line 447 already declares `const char* command`, so this is a passthrough.)

- [ ] **Step 4: Run tests to confirm no regressions**

```bash
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing tests" | head -3
```

Expected: TEST SUCCEEDED. The new parameter has a `nil` default so existing call sites are unchanged.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Infrastructure/Ghostty/GhosttySurfaceView.swift
git commit -m "GhosttySurfaceView: accept optional command override"
```

---

## Task 6: Thread persistence settings into WorktreeTerminalManager

**Files:**
- Modify: `cherrylily/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift`
- Modify: `cherrylily/App/supacodeApp.swift` (where the manager is constructed)

`WorktreeTerminalManager` needs to know whether persistence is enabled. The simplest, lowest-coupling design: pass it a closure that reads the current setting.

- [ ] **Step 1: Add a `persistenceEnabled` closure to WorktreeTerminalManager**

In `WorktreeTerminalManager.swift`, add a stored property near the top:

```swift
let persistenceEnabled: @Sendable () -> Bool
```

Update the initializer signature to accept it. Default it to `{ false }` for tests.

```swift
init(runtime: GhosttyRuntime, persistenceEnabled: @escaping @Sendable () -> Bool = { false }) {
  self.runtime = runtime
  self.persistenceEnabled = persistenceEnabled
}
```

- [ ] **Step 2: Wire it from supacodeApp.swift**

In `cherrylily/App/supacodeApp.swift`, find where `WorktreeTerminalManager` is instantiated:

```bash
grep -n "WorktreeTerminalManager(" cherrylily/App/supacodeApp.swift
```

Replace the construction with one that reads the live setting:

```swift
let terminalManager = WorktreeTerminalManager(
  runtime: runtime,
  persistenceEnabled: {
    @Shared(.settingsFile) var settingsFile
    return settingsFile.global.restoreSessionsOnLaunch
  }
)
```

(`@Shared(.settingsFile)` is available because `Sharing` is already imported in supacodeApp.swift.)

- [ ] **Step 3: Build and test**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -3
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing tests" | head -3
```

Existing tests should pass — the closure defaults to `{ false }` so manager creation in tests doesn't change behavior.

- [ ] **Step 4: Commit**

```bash
git add cherrylily/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift cherrylily/App/supacodeApp.swift
git commit -m "Plumb persistence-enabled flag into WorktreeTerminalManager"
```

---

## Task 7: Bootstrap — write tmux.conf on app launch when persistence is on

**Files:**
- Modify: `cherrylily/App/supacodeApp.swift`

Each launch, regenerate `tmux.conf` if persistence is on (idempotent, so cheap when nothing changed). Read the current `scrollbackLimit` from settings.

Note: `restoreSessionsOnLaunch` is the master toggle. The per-pane scrollback limit will be added to settings in Phase 4 (UI). For Phase 2, hardcode 50_000 — Phase 4 will replace with a settings field.

- [ ] **Step 1: Find the right spot in supacodeApp.swift**

In `cherrylily/App/supacodeApp.swift`, the `init()` of the App struct is where the initial settings are read and the `terminalManager` is created. Insert the tmux.conf bootstrap immediately after `terminalManager` is created.

- [ ] **Step 2: Add the bootstrap call**

```swift
if initialSettings.restoreSessionsOnLaunch {
  do {
    try TmuxConfigWriter(paths: CherryLilyPaths.sessions)
      .writeIfChanged(scrollbackLimit: 50_000, userShell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
  } catch {
    SupaLogger("Sessions").error("Failed to write tmux.conf at launch: \(error)")
  }
}
```

(`SupaLogger` is the established logging API; the existing supacodeApp.swift already imports the modules needed.)

- [ ] **Step 3: Build and test**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -3
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing tests" | head -3
```

Both must pass.

- [ ] **Step 4: Manual verification**

```bash
make build-app
~/Library/Developer/Xcode/DerivedData/cherrylily-*/Build/Products/Debug/CherryLily.app/Contents/MacOS/CherryLily &
sleep 2
cat ~/Library/Application\ Support/CherryLily/tmux.conf | head -10
osascript -e 'quit app "CherryLily"'
```

Expected: `tmux.conf` exists with `set -g history-limit 50000` and the lock-down settings. (If the file isn't being created, the setting may have decoded as false from a stale settings file — try deleting `~/Library/Application Support/CherryLily/settings.json` and relaunching.)

- [ ] **Step 5: Commit**

```bash
git add cherrylily/App/supacodeApp.swift
git commit -m "Write managed tmux.conf at app launch when persistence enabled"
```

---

## Task 8: WorktreeTerminalState — wrap shell launch in tmux when persistence is on

**Files:**
- Modify: `cherrylily/Features/Terminal/Models/WorktreeTerminalState.swift`

This is the integration point. `createSurface(...)` currently creates a `GhosttySurfaceView` with `initialInput`, `workingDirectory`, etc. — but no `command` override (Ghostty uses its default shell). When persistence is on, we pass a tmux-wrapping command.

For Phase 2, each surface gets a fresh `SurfaceID` at creation. Persistence across restart (stable SurfaceIDs from layout) is Phase 3.

- [ ] **Step 1: Find the createSurface site**

```bash
grep -n "GhosttySurfaceView(" cherrylily/Features/Terminal/Models/WorktreeTerminalState.swift
```

You'll see the `GhosttySurfaceView` constructor inside the private `createSurface(tabId:initialInput:inheritingFromSurfaceId:context:)` method.

- [ ] **Step 2: Add a stored property for the persistence flag and inject from manager**

In `WorktreeTerminalState`:
- Add `private let persistenceEnabled: () -> Bool`
- Initialize in `init` from a parameter.

In `WorktreeTerminalManager.state(for:runSetupScriptIfNew:)`, where `WorktreeTerminalState` is constructed, pass `persistenceEnabled: { [weak self] in self?.persistenceEnabled() ?? false }`.

- [ ] **Step 3: Compute the launch command in createSurface**

In the `createSurface(tabId:...)` private method, before constructing `GhosttySurfaceView`:

```swift
let launchCommand: String? = {
  guard persistenceEnabled() else { return nil }
  guard TmuxBinary.isAvailable else {
    SupaLogger("Sessions").warning("tmux binary unavailable — falling back to direct shell")
    return nil
  }
  let surfaceID = SurfaceID()
  let paths = CherryLilyPaths.sessions
  return SurfaceLaunchCommand.compose(
    tmuxBinary: TmuxBinary.bundledURL,
    tmuxConfig: paths.tmuxConfigFile,
    socketName: paths.tmuxSocketName,
    surfaceID: surfaceID
  )
}()
```

Pass `command: launchCommand` to `GhosttySurfaceView(...)`.

- [ ] **Step 4: Build and test**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -3
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing tests" | head -3
```

Existing tests should pass — `persistenceEnabled` defaults to `{ false }` in test fixtures.

- [ ] **Step 5: Manual smoke test (real)**

```bash
make build-app
~/Library/Developer/Xcode/DerivedData/cherrylily-*/Build/Products/Debug/CherryLily.app/Contents/MacOS/CherryLily &
sleep 3
~/Library/Developer/Xcode/DerivedData/cherrylily-*/Build/Products/Debug/CherryLily.app/Contents/MacOS/tmux-cherrylily -L cherrylily ls
osascript -e 'quit app "CherryLily"'
```

Expected: `tmux ls` shows at least one `cl_<uuid>` session (the surface CherryLily launched). If the listing is empty or errors, the launch command isn't being passed correctly — check the surface's process tree with `pgrep -lf tmux-cherrylily`.

- [ ] **Step 6: Commit**

```bash
git add cherrylily/Features/Terminal/Models/WorktreeTerminalState.swift cherrylily/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift
git commit -m "Wrap surface shell in tmux when persistence enabled"
```

---

## Task 9: Final smoke + lint + push

- [ ] **Step 1: Lint Phase 2 files**

```bash
mise exec -- swiftlint --strict cherrylily/Features/Sessions cherrylilyTests/TmuxConfig*.swift cherrylilyTests/SurfaceLaunchCommandTests.swift cherrylily/Infrastructure/Ghostty/GhosttySurfaceView.swift cherrylily/Features/Terminal cherrylily/App/supacodeApp.swift cherrylily/Features/Settings 2>&1 | tail -20
```

Address any new violations (rename short identifiers, break long lines, etc.) — same playbook as Phase 1's Task 13.

- [ ] **Step 2: Build Release**

```bash
make build-release 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -3
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Full test suite**

```bash
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing tests" | head -3
```

Expected: TEST SUCCEEDED.

- [ ] **Step 4: End-to-end manual check**

Persistence ON (default after Task 1):
```bash
make install-dev-build
open /Applications/CherryLily.app
sleep 5
/Applications/CherryLily.app/Contents/MacOS/tmux-cherrylily -L cherrylily ls
osascript -e 'quit app "CherryLily"'
sleep 1
/Applications/CherryLily.app/Contents/MacOS/tmux-cherrylily -L cherrylily ls
```

After quit, the tmux server should still be running with the sessions intact (since we haven't added quit-cleanup yet). That's *expected* for Phase 2 — Phase 3 adds capture-on-quit. Manually clean up:

```bash
/Applications/CherryLily.app/Contents/MacOS/tmux-cherrylily -L cherrylily kill-server
```

- [ ] **Step 5: Commit any lint cleanups, then push**

```bash
git add -u  # only modified files
git commit -m "Clean up Phase 2 SwiftLint violations"  # if needed
git push
```

- [ ] **Step 6: Phase 2 commit summary**

```bash
git log --oneline ab92f68..HEAD
```

(Where `ab92f68` is the parent of Task 1's commit — Phase 1's last commit.)

---

## What Phase 2 leaves for later

- **Phase 3:** capture-on-quit, replay-on-launch, layout serialization that ties SurfaceIDs to tabs/worktrees, orphan reconciliation triggered at launch.
- **Phase 4:** Settings UI (the Sessions section), so users can toggle this without editing JSON.
- **Phase 5:** disk-full alerts, server-crash auto-restart-and-replay, multi-instance prevention, hourly autosave.
- **Phase 6:** reattach UX (hide flicker), OSC passthrough verification (per the spec's explicit test list).

After Phase 2 lands you can flip `restoreSessionsOnLaunch` in `~/Library/Application Support/CherryLily/settings.json` (or just trust the default) and observe surfaces launching through tmux. They won't *survive* quit yet — that's Phase 3.

---

## Self-review notes

- Every step includes runnable code or exact commands with expected output.
- Type and method names are consistent across tasks: `TmuxConfig`, `TmuxConfigWriter`, `SurfaceLaunchCommand`, `restoreSessionsOnLaunch`, `persistenceEnabled`.
- File paths exact and match the synchronized-folder layout.
- Tests precede implementations in TDD tasks.
- Each task ends with a commit so history bisects cleanly.
- Tasks 5–8 build on each other but can be reviewed independently (each compiles and tests cleanly between commits).
- Ghostty C-API integration concretely uses `ghostty_surface_config_s.command` (verified in `Frameworks/GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h:447`).
- Scope check: Phase 2 only. Phase 3+ explicitly deferred.
