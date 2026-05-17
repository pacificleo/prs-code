# Session Persistence — Phase 4: Settings UI

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-05-15-session-persistence-design.md` (Settings UI section, lines 21-55)
**Phase 1 plan:** `docs/superpowers/plans/2026-05-15-session-persistence-phase-1.md`
**Phase 2 plan:** `docs/superpowers/plans/2026-05-15-session-persistence-phase-2.md`
**Phase 3 plan:** `docs/superpowers/plans/2026-05-15-session-persistence-phase-3.md`

**Goal:** Expose Phase 1–3's session persistence via a new **Sessions** section in Preferences, with controls for the restore toggle, scrollback limit, hourly autosave (control only — timer comes in P5), storage path display, "Reveal in Finder", and "Clear saved sessions".

**Architecture:** Add two new fields to `GlobalSettings` (`sessionScrollbackLimit: Int?` where nil = unlimited; `hourlyAutosaveEnabled: Bool`). Mirror in `SettingsFeature.State`. Add `.sessions` case to `SettingsSection`. New `SessionsSettingsView` with controls. Wire scrollback limit into the two consumers (`TmuxConfigWriter` at app launch, `SessionPersistence.captureOne` at capture time). "Clear saved sessions" deletes scrollback files + `layout.json` but does NOT touch live tmux state (so the user's current session keeps working).

**Tech Stack:** Swift 6.2, SwiftUI, TCA `@ObservableState` with `BindableAction`, swift-sharing.

**Phase scope:** Settings UI + scrollback limit consumption. **Out of scope here:**
- Hourly autosave timer wiring (control surface only; Phase 5)
- Disk full / tmux crash detection (Phase 5)
- Settings-driven OSC sanitization toggles (none planned; sanitization is locked-down per spec)

After Phase 4 lands: users can find Settings → Sessions, toggle restore, change scrollback limit (which takes effect on next tab open via tmux.conf rewrite), reveal the storage folder, and clear saved sessions. Hourly autosave toggle persists but doesn't fire yet.

---

## File structure

**Modified:**
- `cherrylily/Features/Settings/Models/GlobalSettings.swift` — add `sessionScrollbackLimit: Int?` (default 50_000) and `hourlyAutosaveEnabled: Bool` (default false)
- `cherrylily/Features/Settings/Reducer/SettingsFeature.swift` — mirror both fields
- `cherrylily/Features/Settings/Views/SettingsSection.swift` — add `.sessions` case
- `cherrylily/Features/Settings/Views/SettingsView.swift` — add nav entry + detail case
- `cherrylily/App/supacodeApp.swift` — read `sessionScrollbackLimit` from settings when calling `TmuxConfigWriter`
- `cherrylily/Features/Sessions/BusinessLogic/SessionPersistence.swift` — accept scrollback limit per capture (replaces hardcoded 50_000)

**New:**
- `cherrylily/Features/Settings/Views/SessionsSettingsView.swift`
- `cherrylily/Features/Sessions/BusinessLogic/SessionDataClearer.swift` — small helper for "Clear saved sessions"

**Tests:**
- `cherrylilyTests/SessionDataClearerTests.swift` — verifies layout + scrollback are deleted; live tmux untouched
- Extend `cherrylilyTests/SessionPersistenceTests.swift` to cover the new `scrollbackLimit` parameter on capture

---

## Task 1: Add `sessionScrollbackLimit` and `hourlyAutosaveEnabled` to GlobalSettings

**Files:**
- Modify: `cherrylily/Features/Settings/Models/GlobalSettings.swift`

Mirror the established 5-touch-point pattern (`confirmBeforeClosingTabs`, `restoreSessionsOnLaunch`).

- [ ] **Step 1: Find insertion points**

```bash
grep -n "restoreSessionsOnLaunch" cherrylily/Features/Settings/Models/GlobalSettings.swift
```

You'll see 5 places: var decl, `static let default`, `init(...)` parameter, init body assignment, `init(from decoder:)` decode-if-present.

- [ ] **Step 2: Add `sessionScrollbackLimit: Int?` (default 50_000)**

After `restoreSessionsOnLaunch` at every touch point. The type is `Int?` so the user can pick "Unlimited" → nil.

Mirror for default: `sessionScrollbackLimit: 50_000,`
Mirror for init param: `sessionScrollbackLimit: Int? = 50_000,`
Mirror for init body: `self.sessionScrollbackLimit = sessionScrollbackLimit`
Mirror for decode: 
```swift
sessionScrollbackLimit =
  try container.decodeIfPresent(Int.self, forKey: .sessionScrollbackLimit)
  ?? Self.default.sessionScrollbackLimit
```

- [ ] **Step 3: Add `hourlyAutosaveEnabled: Bool` (default false)**

Mirror at same 5 points right after `sessionScrollbackLimit`. Default `false`.

- [ ] **Step 4: Build and run tests**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -3
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing" | head -3
```

Existing tests that use `GlobalSettings.default` should still compile — defaults preserve them.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Settings/Models/GlobalSettings.swift
git commit -m "Add sessionScrollbackLimit and hourlyAutosaveEnabled settings"
```

---

## Task 2: Mirror in SettingsFeature.State

**Files:**
- Modify: `cherrylily/Features/Settings/Reducer/SettingsFeature.swift`

Same 4-touch-point pattern as Phase 2 Task 1 did for `restoreSessionsOnLaunch`.

- [ ] **Step 1: Find existing pattern**

```bash
grep -n "restoreSessionsOnLaunch" cherrylily/Features/Settings/Reducer/SettingsFeature.swift
```

4 places: State property, init copy from settings, `globalSettings` computed property, `settingsLoaded` reducer body.

- [ ] **Step 2: Add both fields**

After every `restoreSessionsOnLaunch` line, add:
```swift
var sessionScrollbackLimit: Int?
var hourlyAutosaveEnabled: Bool
```

(State property)

```swift
sessionScrollbackLimit = settings.sessionScrollbackLimit
hourlyAutosaveEnabled = settings.hourlyAutosaveEnabled
```

(init body, settingsLoaded body)

```swift
sessionScrollbackLimit: sessionScrollbackLimit,
hourlyAutosaveEnabled: hourlyAutosaveEnabled,
```

(globalSettings computed property)

- [ ] **Step 3: Build + test**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -3
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing" | head -3
```

- [ ] **Step 4: Commit**

```bash
git add cherrylily/Features/Settings/Reducer/SettingsFeature.swift
git commit -m "Mirror session settings in SettingsFeature state"
```

---

## Task 3: Add `.sessions` case to SettingsSection

**Files:**
- Modify: `cherrylily/Features/Settings/Views/SettingsSection.swift`

- [ ] **Step 1: Add the case**

In the enum:
```swift
enum SettingsSection: Hashable {
  case general
  case notifications
  case worktree
  case sessions    // ← new
  case shortcuts
  case updates
  case advanced
  case appLauncher
  case github
  case repository(Repository.ID)
}
```

- [ ] **Step 2: Build (test will fail because SettingsView still has to handle new case in switch)**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -10
```

Expected: build fails on `SettingsView.swift`'s switch — Swift's exhaustive switch will demand a case for `.sessions`. That's expected; Task 4 wires the view in.

If the build error is missing-case-in-switch, proceed. If a different error, investigate.

- [ ] **Step 3: Don't commit yet — Task 4 finishes the wire**

Hold the commit until SettingsView builds again (after Task 4).

---

## Task 4: Create SessionsSettingsView + wire into SettingsView

**Files:**
- Create: `cherrylily/Features/Settings/Views/SessionsSettingsView.swift`
- Modify: `cherrylily/Features/Settings/Views/SettingsView.swift`

The UI per spec:

```
☑ Restore terminal contents on launch
    Tabs, splits, working directories, and scrollback come back
    when you reopen CherryLily.

Scrollback to keep per pane:  [50,000 lines  ▼]
    10,000 · 50,000 · 100,000 · 500,000 · Unlimited

▸ Advanced
    ☐ Save automatically every hour
        In case CherryLily exits unexpectedly.
    Storage: ~/Library/Application Support/CherryLily/…
    [Reveal in Finder]   [Clear saved sessions]
```

- [ ] **Step 1: Create SessionsSettingsView.swift**

```swift
import AppKit
import ComposableArchitecture
import SwiftUI

struct SessionsSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var showClearConfirm = false

  // 5 choices for the scrollback picker; nil = Unlimited
  private static let scrollbackChoices: [(label: String, value: Int?)] = [
    ("10,000 lines", 10_000),
    ("50,000 lines", 50_000),
    ("100,000 lines", 100_000),
    ("500,000 lines", 500_000),
    ("Unlimited", nil),
  ]

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $store.restoreSessionsOnLaunch) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Restore terminal contents on launch")
            Text("Tabs, splits, working directories, and scrollback come back when you reopen CherryLily.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .help("When enabled, CherryLily saves your terminal state on quit and restores it on next launch.")

        Picker(selection: $store.sessionScrollbackLimit) {
          ForEach(Self.scrollbackChoices, id: \.label) { choice in
            Text(choice.label).tag(choice.value)
          }
        } label: {
          Text("Scrollback to keep per pane")
        }
        .pickerStyle(.menu)
        .help("How much history to capture for each pane on quit. Applies to new tabs.")
      }

      Section("Advanced") {
        Toggle(isOn: $store.hourlyAutosaveEnabled) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Save automatically every hour")
            Text("In case CherryLily exits unexpectedly.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .help("Periodically captures scrollback while CherryLily is running.")

        VStack(alignment: .leading, spacing: 8) {
          Text("Storage")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          HStack {
            Text(SessionPaths().root.path)
              .font(.caption)
              .lineLimit(1)
              .truncationMode(.middle)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
            Spacer()
          }
          HStack {
            Button("Reveal in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([SessionPaths().root])
            }
            .help("Open the session storage folder in Finder.")

            Button(role: .destructive) {
              showClearConfirm = true
            } label: {
              Text("Clear saved sessions")
            }
            .help("Deletes the saved layout and scrollback files. Your current terminals stay open.")
          }
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(
      "Clear saved sessions?",
      isPresented: $showClearConfirm,
      titleVisibility: .visible
    ) {
      Button("Clear", role: .destructive) {
        SessionDataClearer(paths: SessionPaths()).clearSavedData()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This deletes the saved layout and scrollback files. "
        + "Your currently open tabs will keep running, but won't be restorable until next quit."
      )
    }
  }
}
```

- [ ] **Step 2: Add nav entry + detail case in SettingsView.swift**

In the sidebar `List`, add between Worktree and Shortcuts (matches spec ordering — Sessions is its own section, related to terminal state):

```swift
Label("Sessions", systemImage: "clock.arrow.circlepath")
  .tag(SettingsSection.sessions)
```

In the `switch selection`:
```swift
case .sessions:
  SettingsDetailView {
    SessionsSettingsView(store: settingsStore)
      .navigationTitle("Sessions")
      .navigationSubtitle("Restore terminal contents across launches")
  }
```

- [ ] **Step 3: Build + run**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -5
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing" | head -3
```

If the Picker tag types don't match (Int? vs Int) you'll see a generic-inference error — make sure tags are `.tag(choice.value)` where `choice.value: Int?`.

- [ ] **Step 4: Manual UI check (light, non-destructive)**

If the user opens Preferences → Sessions, the view should render. They can verify by visually inspecting; we won't drive the UI from this session.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Settings/Views/SessionsSettingsView.swift cherrylily/Features/Settings/Views/SettingsSection.swift cherrylily/Features/Settings/Views/SettingsView.swift
git commit -m "Add Sessions settings panel"
```

---

## Task 5: Wire `sessionScrollbackLimit` into TmuxConfigWriter call site

**Files:**
- Modify: `cherrylily/App/supacodeApp.swift`

Today `bootstrapSessionPersistence` hardcodes `scrollbackLimit: 50_000`. Replace with the user's setting.

For nil (unlimited), tmux interprets `set -g history-limit 0` as no scrollback (NOT unlimited). The actual "unlimited" idiom in tmux is a very large number. Use `Int.max` or a defensive cap like `1_000_000` (one million lines, ~hundreds of MB worst case). **Decision: cap at 1_000_000** when the setting is nil — safer than tmux's giant integer behavior, still gigantic for any practical use. Document this in code.

- [ ] **Step 1: Read the bootstrap function**

```bash
grep -B1 -A12 "bootstrapSessionPersistence" cherrylily/App/supacodeApp.swift
```

- [ ] **Step 2: Take the setting as a parameter**

Change signature to accept the limit:

```swift
private static func bootstrapSessionPersistence(
  persistence: SessionPersistence,
  scrollbackLimit: Int?
) {
  let effectiveLimit = scrollbackLimit ?? 1_000_000
  do {
    try TmuxConfigWriter(paths: persistence.paths)
      .writeIfChanged(
        scrollbackLimit: effectiveLimit,
        userShell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
      )
  } catch {
    SupaLogger("Sessions").warning("Failed to write tmux.conf at launch: \(error)")
  }
}
```

At the call site (in init), pass `scrollbackLimit: initialSettings.sessionScrollbackLimit`.

- [ ] **Step 3: Build + test**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -3
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing" | head -3
```

- [ ] **Step 4: Commit**

```bash
git add cherrylily/App/supacodeApp.swift
git commit -m "Use user's scrollback limit when writing tmux.conf"
```

---

## Task 6: Wire `sessionScrollbackLimit` into SessionPersistence capture

**Files:**
- Modify: `cherrylily/Features/Sessions/BusinessLogic/SessionPersistence.swift`
- Modify: `cherrylily/App/supacodeApp.swift` (delegate's `applicationWillTerminate` reads setting on capture)

Today `SessionPersistence.captureAll(for:)` hardcodes `50_000`. Make it parametric.

- [ ] **Step 1: Modify captureAll signature**

```swift
@discardableResult
func captureAll(for layout: SessionLayout, scrollbackLimit: Int?) async -> Int {
  let effectiveLimit = scrollbackLimit ?? 1_000_000
  // ... existing TaskGroup body, passing effectiveLimit into captureOne ...
}

private static func captureOne(
  surfaceID: SurfaceID,
  scrollbackLimit: Int,
  tmuxClient: TmuxClient,
  scrollbackStore: ScrollbackStore
) async -> Bool {
  // use scrollbackLimit instead of hardcoded 50_000
}
```

- [ ] **Step 2: Update SessionPersistenceTests**

The existing tests don't exercise capture — but if any did, they'd need the new param. Just update method calls; the four layout-focused tests stay the same.

- [ ] **Step 3: Update the applicationWillTerminate caller**

In `CherryLilyAppDelegate.applicationWillTerminate(_:)`:

```swift
@Shared(.settingsFile) var settings
guard settings.global.restoreSessionsOnLaunch else { return }
let scrollbackLimit = settings.global.sessionScrollbackLimit

// ... layout + writeLayout (unchanged) ...

let semaphore = DispatchSemaphore(value: 0)
Task {
  _ = await persistence.captureAll(for: layout, scrollbackLimit: scrollbackLimit)
  semaphore.signal()
}
_ = semaphore.wait(timeout: .now() + .seconds(2))
```

- [ ] **Step 4: Build + test**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -3
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Failing" | head -3
```

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Sessions/BusinessLogic/SessionPersistence.swift cherrylily/App/supacodeApp.swift
git commit -m "Honor user's scrollback limit during capture"
```

---

## Task 7: SessionDataClearer for "Clear saved sessions"

**Files:**
- Create: `cherrylily/Features/Sessions/BusinessLogic/SessionDataClearer.swift`
- Create: `cherrylilyTests/SessionDataClearerTests.swift`

**Important UX note:** "Clear saved sessions" must NOT kill live tmux sessions. CherryLily IS the user's terminal — killing tmux destroys their work. We only delete persisted state (layout.json + sessions/*.bin). The next time the user quits, fresh state will be written.

- [ ] **Step 1: Write the test (TDD)**

Create `cherrylilyTests/SessionDataClearerTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

struct SessionDataClearerTests {
  private static func makePaths() -> SessionPaths {
    SessionPaths(
      root: URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "cl-clear-test-\(UUID().uuidString)")
    )
  }

  @Test func clearRemovesLayoutFile() throws {
    let paths = Self.makePaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try paths.ensureDirectoriesExist()
    try Data("{}".utf8).write(to: paths.layoutFile)
    #expect(FileManager.default.fileExists(atPath: paths.layoutFile.path))

    SessionDataClearer(paths: paths).clearSavedData()

    #expect(!FileManager.default.fileExists(atPath: paths.layoutFile.path))
  }

  @Test func clearRemovesAllScrollbackFiles() throws {
    let paths = Self.makePaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try paths.ensureDirectoriesExist()
    let id1 = SurfaceID()
    let id2 = SurfaceID()
    try Data("a".utf8).write(to: paths.scrollbackFile(for: id1))
    try Data("b".utf8).write(to: paths.scrollbackFile(for: id2))

    SessionDataClearer(paths: paths).clearSavedData()

    #expect(!FileManager.default.fileExists(atPath: paths.scrollbackFile(for: id1).path))
    #expect(!FileManager.default.fileExists(atPath: paths.scrollbackFile(for: id2).path))
  }

  @Test func clearLeavesTmuxConfigFile() throws {
    let paths = Self.makePaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try paths.ensureDirectoriesExist()
    try Data("# config".utf8).write(to: paths.tmuxConfigFile)

    SessionDataClearer(paths: paths).clearSavedData()

    // tmux.conf is managed config — survives "clear saved sessions"
    #expect(FileManager.default.fileExists(atPath: paths.tmuxConfigFile.path))
  }

  @Test func clearIsIdempotent() throws {
    let paths = Self.makePaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try paths.ensureDirectoriesExist()
    // No files exist; clearing should not throw
    SessionDataClearer(paths: paths).clearSavedData()
    // Second clear also fine
    SessionDataClearer(paths: paths).clearSavedData()
    #expect(true)
  }
}
```

- [ ] **Step 2: Verify RED**

```bash
make test 2>&1 | grep -E "SessionDataClearer|Cannot find" | head -5
```

Expected: "Cannot find 'SessionDataClearer' in scope".

- [ ] **Step 3: Implement**

Create `cherrylily/Features/Sessions/BusinessLogic/SessionDataClearer.swift`:

```swift
import Foundation

private nonisolated let clearerLogger = SupaLogger("Sessions")

/// Deletes saved session state — layout.json and all scrollback files — without
/// touching live tmux sessions or the managed tmux.conf.
///
/// Live state is intentionally preserved: CherryLily is the user's terminal, so
/// killing tmux sessions would destroy their open work. After clear, the next
/// `applicationWillTerminate` will write a fresh layout from current state.
nonisolated struct SessionDataClearer: Sendable {
  let paths: SessionPaths

  func clearSavedData() {
    let fm = FileManager.default

    if fm.fileExists(atPath: paths.layoutFile.path) {
      do {
        try fm.removeItem(at: paths.layoutFile)
      } catch {
        clearerLogger.warning("failed to delete layout.json: \(error)")
      }
    }

    do {
      let contents = try fm.contentsOfDirectory(at: paths.sessionsDirectory, includingPropertiesForKeys: nil)
      for url in contents where url.pathExtension == "bin" {
        do {
          try fm.removeItem(at: url)
        } catch {
          clearerLogger.warning("failed to delete \(url.lastPathComponent): \(error)")
        }
      }
    } catch {
      // sessions directory may not exist — that's fine, nothing to clear
      if (error as NSError).code != NSFileReadNoSuchFileError {
        clearerLogger.warning("failed to enumerate sessions directory: \(error)")
      }
    }
  }
}
```

- [ ] **Step 4: Verify GREEN**

```bash
make test 2>&1 | grep -E "SessionDataClearer|TEST SUCCEEDED|TEST FAILED" | head -10
```

All 4 tests pass; full suite green.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Sessions/BusinessLogic/SessionDataClearer.swift cherrylilyTests/SessionDataClearerTests.swift
git commit -m "Add SessionDataClearer for non-destructive 'Clear saved sessions'"
```

---

## Task 8: Final smoke + lint + push

- [ ] **Step 1: Self-smoke (deferred to user)**

Per [[feedback-cherrylily-self-terminal]]: do NOT run any destructive smoke from within this session. Instead, hand the user a checklist they can run on their own time:

1. Open Preferences → Sessions — does the panel render with the correct controls?
2. Toggle restore-on-launch off → on. Does the setting persist (kill app, reopen, check Settings)?
3. Change scrollback to 10,000 → check `cat ~/Library/Application\ Support/CherryLily/tmux.conf` shows `history-limit 10000`.
4. Click "Reveal in Finder" — Finder window opens at the CherryLily folder.
5. Click "Clear saved sessions" → confirm → `ls ~/Library/Application\ Support/CherryLily/` shows tmux.conf but no layout.json or sessions/*.bin. Live tabs untouched.

- [ ] **Step 2: Lint (scoped)**

```bash
make lint 2>&1 | grep -E "Sessions/|SessionsSettingsView|SessionDataClearer|GlobalSettings|SettingsFeature|SettingsSection|SettingsView|supacodeApp|violation" | head -20
```

Zero violations in Phase 4 files.

- [ ] **Step 3: Push**

```bash
git push origin nav-back-forward
```
