# Toolbar App Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the worktree toolbar's "Open in…" dropdown with a row of icon-only buttons for apps the user pins in Settings, updating live with no restart; keep the Run button.

**Architecture:** Add a global, ordered `pinnedToolbarActions: [String]` to `GlobalSettings`. The toolbar renders one icon button per pinned, installed app (resolved by a new `OpenWorktreeAction.pinnedToolbarCases`), each firing the existing `.openWorktree` action. Settings’ App Launcher screen becomes a pin manager (toggle + reorder). The old per-repo default-open machinery, the menu-bar "Open Worktree" command, and the open shortcut are removed.

**Tech Stack:** Swift 6.2, SwiftUI (macOS 26+), The Composable Architecture, swift-dependencies, `@Shared(.settingsFile)`, XCTest via xcodebuild.

**Conventions:** 2-space indent, 120 col, trailing commas mandatory, swiftlint strict. Views must not mutate `store.*` (send actions). Reducer logic changes require tests. Build with `make build-app`; run a single test class with the `xcodebuild … -only-testing:` invocation from CLAUDE.md.

---

## File map

- **Modify** `cherrylily/Features/Settings/Models/GlobalSettings.swift` — add `pinnedToolbarActions` stored property + decode/seed.
- **Modify** `cherrylily/Domain/OpenWorktreeAction.swift` — add `customIconData`, fix `menuIcon` for customs, add `pinnedToolbarCases(settings:)` + seed helper.
- **Modify** `cherrylily/Features/Settings/Reducer/SettingsFeature.swift` — State field, `globalSettings` mapping, `settingsLoaded` sync, pin/reorder actions + persist.
- **Modify** `cherrylily/Features/Settings/Views/AppLauncherSettingsView.swift` — pin toggles + drag reorder.
- **Modify** `cherrylily/Features/Repositories/Views/WorktreeDetailView.swift` — replace `openMenu` with icon row; drop default-selection/copy-path plumbing; update preview.
- **Modify** `cherrylily/Features/App/Reducer/AppFeature.swift` — remove `openActionSelection`, `openActionSelectionChanged`, `openSelectedWorktree`; drop `openActionID` read/writes.
- **Modify** `cherrylily/Commands/WorktreeCommands.swift` — remove "Open Worktree" command + `openSelectedWorktreeAction` focused value/key.
- **Modify** `cherrylily/App/AppShortcuts.swift` — remove `openFinder` from `.actions` group (keep enum case).
- **Modify** `cherrylily/Support/CustomDump+Extensions.swift` — drop `openAction` dump line.
- **Tests:** `cherrylilyTests/OpenWorktreeActionTests.swift`, `cherrylilyTests/GlobalSettingsTests.swift` (create if absent), `cherrylilyTests/SettingsFeature*Tests.swift`, `cherrylilyTests/AppFeature*` (adjust removed-path tests).

---

## Task 1: Add `pinnedToolbarActions` to GlobalSettings (model + seed)

**Files:**
- Modify: `cherrylily/Features/Settings/Models/GlobalSettings.swift`
- Modify: `cherrylily/Domain/OpenWorktreeAction.swift` (seed helper)
- Test: `cherrylilyTests/GlobalSettingsTests.swift`

- [ ] **Step 1: Add seed helper to `OpenWorktreeAction`** (used by decode; keep decode pure/no NSWorkspace)

In `OpenWorktreeAction.swift`, after `automaticSettingsID`:
```swift
/// Default toolbar pins for users upgrading from before pinning existed:
/// Finder + their configured default editor. Uses the always-available
/// `$EDITOR` action when the default editor is "auto"/empty. Install
/// filtering happens later in `pinnedToolbarCases`, so this stays pure.
static func seededPinnedToolbarActions(defaultEditorID: String) -> [String] {
  let editorID =
    (defaultEditorID.isEmpty || defaultEditorID == automaticSettingsID)
    ? editor.settingsID
    : defaultEditorID
  var seed = [finder.settingsID]
  if editorID != finder.settingsID { seed.append(editorID) }
  return seed
}
```

- [ ] **Step 2: Add the stored property + init param + decode + mapping in `GlobalSettings.swift`**

Add stored property after line `var customWorktreeActions: [CustomWorktreeAction]`:
```swift
  var pinnedToolbarActions: [String]
```
Add to `static let default` initializer args (after `customWorktreeActions: [],`):
```swift
    pinnedToolbarActions: ["finder", "editor"],
```
Add to the memberwise `init(...)` parameter list (after `customWorktreeActions: [CustomWorktreeAction] = [],`):
```swift
    pinnedToolbarActions: [String] = [],
```
and in the body (after `self.customWorktreeActions = customWorktreeActions`):
```swift
    self.pinnedToolbarActions = pinnedToolbarActions
```
Add to `init(from:)` after the `customWorktreeActions = …` block (before `shortcutOverrides =`):
```swift
    pinnedToolbarActions =
      try container.decodeIfPresent([String].self, forKey: .pinnedToolbarActions)
      ?? OpenWorktreeAction.seededPinnedToolbarActions(defaultEditorID: defaultEditorID)
```
(`CodingKeys` and `encode(to:)` are synthesized, so the new property is encoded automatically and `.pinnedToolbarActions` resolves.)

- [ ] **Step 3: Write failing tests** in `cherrylilyTests/GlobalSettingsTests.swift`

```swift
import XCTest
@testable import cherrylily

final class GlobalSettingsTests: XCTestCase {
  func test_decode_absentPins_seedsFinderAndConcreteEditor() throws {
    let json = #"{"appearanceMode":"dark","defaultEditorID":"zed","updatesAutomaticallyCheckForUpdates":true,"updatesAutomaticallyDownloadUpdates":true,"inAppNotificationsEnabled":true,"notificationSoundEnabled":true,"moveNotifiedWorktreeToTop":false,"analyticsEnabled":true,"crashReportsEnabled":true,"githubIntegrationEnabled":true,"deleteBranchOnDeleteWorktree":false,"automaticallyArchiveMergedWorktrees":false,"promptForWorktreeCreation":false,"updateChannel":"stable"}"#
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))
    XCTAssertEqual(settings.pinnedToolbarActions, ["finder", "zed"])
  }

  func test_decode_absentPins_autoEditor_seedsFinderAndEditor() throws {
    let json = #"{"appearanceMode":"dark","defaultEditorID":"auto","updatesAutomaticallyCheckForUpdates":true,"updatesAutomaticallyDownloadUpdates":true,"inAppNotificationsEnabled":true,"notificationSoundEnabled":true,"moveNotifiedWorktreeToTop":false,"analyticsEnabled":true,"crashReportsEnabled":true,"githubIntegrationEnabled":true,"deleteBranchOnDeleteWorktree":false,"automaticallyArchiveMergedWorktrees":false,"promptForWorktreeCreation":false,"updateChannel":"stable"}"#
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))
    XCTAssertEqual(settings.pinnedToolbarActions, ["finder", "editor"])
  }

  func test_decode_presentEmptyPins_isRespected() throws {
    let json = #"{"appearanceMode":"dark","defaultEditorID":"auto","pinnedToolbarActions":[],"updatesAutomaticallyCheckForUpdates":true,"updatesAutomaticallyDownloadUpdates":true,"inAppNotificationsEnabled":true,"notificationSoundEnabled":true,"moveNotifiedWorktreeToTop":false,"analyticsEnabled":true,"crashReportsEnabled":true,"githubIntegrationEnabled":true,"deleteBranchOnDeleteWorktree":false,"automaticallyArchiveMergedWorktrees":false,"promptForWorktreeCreation":false,"updateChannel":"stable"}"#
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))
    XCTAssertEqual(settings.pinnedToolbarActions, [])
  }

  func test_roundTrip_preservesPins() throws {
    var settings = GlobalSettings.default
    settings.pinnedToolbarActions = ["finder", "cursor", "custom.foo"]
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
    XCTAssertEqual(decoded.pinnedToolbarActions, ["finder", "cursor", "custom.foo"])
  }
}
```

- [ ] **Step 4: Run tests — expect FAIL (then PASS after Steps 1–2 compile)**

Run:
```bash
xcodebuild test -project cherrylily.xcodeproj -scheme cherrylily -destination "platform=macOS" \
  -only-testing:cherrylilyTests/GlobalSettingsTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```
Expected: all 4 pass.

- [ ] **Step 5: Commit**
```bash
git add cherrylily/Features/Settings/Models/GlobalSettings.swift cherrylily/Domain/OpenWorktreeAction.swift cherrylilyTests/GlobalSettingsTests.swift
git commit -m "feat(settings): add pinnedToolbarActions with upgrade seeding"
```

---

## Task 2: `OpenWorktreeAction.pinnedToolbarCases` + custom-app icons

**Files:**
- Modify: `cherrylily/Domain/OpenWorktreeAction.swift`
- Test: `cherrylilyTests/OpenWorktreeActionTests.swift`

- [ ] **Step 1: Add `customIconData` and fix `menuIcon`**

Add stored property after `var settingsID: String`:
```swift
  var customIconData: Data?
```
Initialize it in every `OpenWorktreeAction(...)` literal? No — give it a default. Change the memberwise usages by adding a default in the type by declaring it with `= nil` is not allowed for a struct's synthesized init when other inits exist; instead add an explicit default value at declaration:
```swift
  var customIconData: Data? = nil
```
Update `menuIcon`:
```swift
  @MainActor
  var menuIcon: MenuIcon? {
    switch self {
    case .editor:
      return .symbol("apple.terminal")
    default:
      if bundleIdentifier == "custom" {
        if let customIconData { return .app(customIconData) }
        return .symbol("app.dashed")
      }
      return OpenWorktreeActionCache.menuIcon(forBundleIdentifier: bundleIdentifier)
    }
  }
```

- [ ] **Step 2: Add `pinnedToolbarCases(settings:)`**

After `availableCases(settings:)`:
```swift
/// Ordered, installed actions to render as toolbar icons, resolved from
/// `settings.pinnedToolbarActions`. Built-ins map by `settingsID` and are
/// dropped if not installed; custom ids map to the user's custom apps and
/// carry their own icon. Unknown ids are skipped.
static func pinnedToolbarCases(settings: GlobalSettings) -> [OpenWorktreeAction] {
  settings.pinnedToolbarActions.compactMap { id in
    if let builtIn = menuOrder.first(where: { $0.settingsID == id }) {
      return builtIn.isInstalled ? builtIn : nil
    }
    guard let custom = settings.customWorktreeActions.first(where: { $0.id == id }) else {
      return nil
    }
    return OpenWorktreeAction(
      bundleIdentifier: "custom",
      title: custom.name,
      settingsID: custom.id,
      customIconData: custom.icon
    )
  }
}
```
Note: `menuOrder` includes `.editor` ($EDITOR), which is always installed.

- [ ] **Step 3: Write failing tests** (append to `OpenWorktreeActionTests.swift`)

```swift
func test_pinnedToolbarCases_ordersAndFiltersUnknown() {
  var settings = GlobalSettings.default
  settings.pinnedToolbarActions = ["finder", "editor", "does-not-exist"]
  let cases = OpenWorktreeAction.pinnedToolbarCases(settings: settings)
  XCTAssertEqual(cases.map(\.settingsID), ["finder", "editor"])
}

func test_pinnedToolbarCases_resolvesCustomWithIcon() {
  var settings = GlobalSettings.default
  let icon = Data([0x01, 0x02])
  settings.customWorktreeActions = [
    CustomWorktreeAction(id: "custom.foo", name: "Foo", url: URL(filePath: "/Applications/Foo.app"), icon: icon),
  ]
  settings.pinnedToolbarActions = ["custom.foo"]
  let cases = OpenWorktreeAction.pinnedToolbarCases(settings: settings)
  XCTAssertEqual(cases.count, 1)
  XCTAssertEqual(cases[0].settingsID, "custom.foo")
  XCTAssertEqual(cases[0].customIconData, icon)
}

func test_seededPinnedToolbarActions_autoUsesEditor() {
  XCTAssertEqual(OpenWorktreeAction.seededPinnedToolbarActions(defaultEditorID: "auto"), ["finder", "editor"])
  XCTAssertEqual(OpenWorktreeAction.seededPinnedToolbarActions(defaultEditorID: "cursor"), ["finder", "cursor"])
  XCTAssertEqual(OpenWorktreeAction.seededPinnedToolbarActions(defaultEditorID: "finder"), ["finder"])
}
```

- [ ] **Step 4: Run tests — expect PASS**
```bash
xcodebuild test -project cherrylily.xcodeproj -scheme cherrylily -destination "platform=macOS" \
  -only-testing:cherrylilyTests/OpenWorktreeActionTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

- [ ] **Step 5: Commit**
```bash
git add cherrylily/Domain/OpenWorktreeAction.swift cherrylilyTests/OpenWorktreeActionTests.swift
git commit -m "feat(open-action): add pinnedToolbarCases and custom-app icons"
```

---

## Task 3: SettingsFeature — state plumbing + pin/reorder actions

**Files:**
- Modify: `cherrylily/Features/Settings/Reducer/SettingsFeature.swift`
- Test: `cherrylilyTests/SettingsFeaturePinTests.swift` (create)

- [ ] **Step 1: Add State field + mapping + sync**

In `State`, after `var customWorktreeActions: [CustomWorktreeAction]`:
```swift
    var pinnedToolbarActions: [String]
```
In `init(settings:)`, after `customWorktreeActions = settings.customWorktreeActions`:
```swift
      pinnedToolbarActions = settings.pinnedToolbarActions
```
In `globalSettings`, add to the `GlobalSettings(...)` call (after `customWorktreeActions: customWorktreeActions,`):
```swift
        pinnedToolbarActions: pinnedToolbarActions,
```
In `settingsLoaded`, after `state.customWorktreeActions = normalizedSettings.customWorktreeActions`:
```swift
        state.pinnedToolbarActions = normalizedSettings.pinnedToolbarActions
```

- [ ] **Step 2: Add actions**

In `enum Action`, after `case removeCustomAction(String)`:
```swift
    case setToolbarPin(id: String, pinned: Bool)
    case movePinnedToolbarAction(from: IndexSet, to: Int)
```

- [ ] **Step 3: Handle actions in the reducer** (near `removeCustomAction`)

```swift
      case let .setToolbarPin(id, pinned):
        if pinned {
          if !state.pinnedToolbarActions.contains(id) {
            state.pinnedToolbarActions.append(id)
          }
        } else {
          state.pinnedToolbarActions.removeAll { $0 == id }
        }
        return persist(state)

      case let .movePinnedToolbarAction(from, to):
        state.pinnedToolbarActions.move(fromOffsets: from, toOffset: to)
        return persist(state)
```
Also update `removeCustomAction` to unpin the removed app:
```swift
      case .removeCustomAction(let id):
        state.customWorktreeActions.removeAll { $0.id == id }
        state.pinnedToolbarActions.removeAll { $0 == id }
        return persist(state)
```

- [ ] **Step 4: Write failing tests** in `cherrylilyTests/SettingsFeaturePinTests.swift`

```swift
import ComposableArchitecture
import XCTest
@testable import cherrylily

@MainActor
final class SettingsFeaturePinTests: XCTestCase {
  func test_setToolbarPin_addsAndRemoves() async {
    let store = TestStore(initialState: SettingsFeature.State(settings: .default)) {
      SettingsFeature()
    }
    store.exhaustivity = .off
    await store.send(.setToolbarPin(id: "cursor", pinned: true)) {
      $0.pinnedToolbarActions = ["finder", "editor", "cursor"]
    }
    await store.send(.setToolbarPin(id: "finder", pinned: false)) {
      $0.pinnedToolbarActions = ["editor", "cursor"]
    }
  }

  func test_move_reorders() async {
    var initial = SettingsFeature.State(settings: .default)
    initial.pinnedToolbarActions = ["finder", "editor", "cursor"]
    let store = TestStore(initialState: initial) { SettingsFeature() }
    store.exhaustivity = .off
    await store.send(.movePinnedToolbarAction(from: IndexSet(integer: 2), to: 0)) {
      $0.pinnedToolbarActions = ["cursor", "finder", "editor"]
    }
  }

  func test_removeCustomAction_unpins() async {
    var initial = SettingsFeature.State(settings: .default)
    initial.customWorktreeActions = [
      CustomWorktreeAction(id: "custom.foo", name: "Foo", url: URL(filePath: "/Applications/Foo.app"), icon: nil),
    ]
    initial.pinnedToolbarActions = ["finder", "custom.foo"]
    let store = TestStore(initialState: initial) { SettingsFeature() }
    store.exhaustivity = .off
    await store.send(.removeCustomAction("custom.foo")) {
      $0.customWorktreeActions = []
      $0.pinnedToolbarActions = ["finder"]
    }
  }
}
```

- [ ] **Step 5: Run tests + commit**
```bash
xcodebuild test -project cherrylily.xcodeproj -scheme cherrylily -destination "platform=macOS" \
  -only-testing:cherrylilyTests/SettingsFeaturePinTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
git add cherrylily/Features/Settings/Reducer/SettingsFeature.swift cherrylilyTests/SettingsFeaturePinTests.swift
git commit -m "feat(settings): pin/reorder toolbar actions"
```

---

## Task 4: App Launcher settings view → pin manager

**Files:**
- Modify: `cherrylily/Features/Settings/Views/AppLauncherSettingsView.swift`

- [ ] **Step 1: Replace the view body** with a pin list (toggle = pinned) + drag reorder of pinned apps + custom apps section.

Replace the whole `var body` with:
```swift
  var body: some View {
    Form {
      Section(
        header: Text("Toolbar Apps"),
        footer: Text("Pinned apps appear as icons in the worktree toolbar, in this order. Drag to reorder. Newly installed apps may require a restart to appear.")
      ) {
        ForEach(pinnedActions, id: \.id) { action in
          HStack {
            OpenWorktreeActionMenuLabelView(action: action, shortcutHint: nil)
            Spacer()
            Image(systemName: "line.3.horizontal")
              .foregroundStyle(.secondary)
          }
        }
        .onMove { from, to in
          store.send(.movePinnedToolbarAction(from: from, to: to))
        }
        if pinnedActions.isEmpty {
          Text("No apps pinned.")
            .foregroundStyle(.secondary)
        }
      }

      Section(header: Text("Available")) {
        ForEach(unpinnedInstalledActions, id: \.id) { action in
          Toggle(isOn: pinBinding(for: action.settingsID)) {
            OpenWorktreeActionMenuLabelView(action: action, shortcutHint: nil)
          }
        }
      }

      Section(
        header: Text("Custom Tools"),
        footer: Text("Add your own applications, then pin them above.")
      ) {
        ForEach(store.state.customWorktreeActions) { action in
          HStack {
            if let iconData = action.icon, let image = NSImage(data: iconData) {
              Image(nsImage: image).resizable().frame(width: 16, height: 16)
            }
            Text(action.name)
            Spacer()
            Toggle("", isOn: pinBinding(for: action.id)).labelsHidden()
            Button(role: .destructive) {
              store.send(.removeCustomAction(action.id))
            } label: {
              Image(systemName: "minus.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
          }
        }
        Button {
          store.send(.addCustomApplicationButtonTapped)
        } label: {
          HStack {
            Image(systemName: "plus.circle.fill").foregroundStyle(.green)
            Text("Add Application")
          }
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
      }
    }
    .formStyle(.grouped)
  }
```

- [ ] **Step 2: Add helpers** (replace the old `bindingForAction`)

```swift
  private var settings: GlobalSettings { store.state.globalSettings }

  private var pinnedActions: [OpenWorktreeAction] {
    OpenWorktreeAction.pinnedToolbarCases(settings: settings)
  }

  private var unpinnedInstalledActions: [OpenWorktreeAction] {
    let pinned = Set(store.state.pinnedToolbarActions)
    let builtIns = OpenWorktreeAction.menuOrder.filter { $0.isInstalled && !pinned.contains($0.settingsID) }
    return builtIns
  }

  private func pinBinding(for id: String) -> Binding<Bool> {
    Binding(
      get: { store.state.pinnedToolbarActions.contains(id) },
      set: { store.send(.setToolbarPin(id: id, pinned: $0)) }
    )
  }
```
(`OpenWorktreeActionMenuLabelView` already exists. Keep `import AppKit`/`import SwiftUI`/`import ComposableArchitecture`.)

- [ ] **Step 3: Build** (view-only; verified via app build in Task 8). No unit test (SwiftUI view).
```bash
make build-app
```
Expected: build succeeds.

- [ ] **Step 4: Commit**
```bash
git add cherrylily/Features/Settings/Views/AppLauncherSettingsView.swift
git commit -m "feat(settings): App Launcher becomes toolbar pin manager"
```

---

## Task 5: Toolbar — replace dropdown with pinned icon row

**Files:**
- Modify: `cherrylily/Features/Repositories/Views/WorktreeDetailView.swift`

- [ ] **Step 1: `WorktreeToolbarState` — swap `openActionSelection` for `pinnedActions`**

In `struct WorktreeToolbarState`, replace:
```swift
    let openActionSelection: OpenWorktreeAction
    let showExtras: Bool
```
with:
```swift
    let pinnedActions: [OpenWorktreeAction]
    let showExtras: Bool
```

- [ ] **Step 2: `detailBody` — compute `pinnedActions`, drop `openActionSelection`**

Remove the line `let openActionSelection = state.openActionSelection`.
Above the `WorktreeToolbarState(` call, add:
```swift
        @Shared(.settingsFile) var settingsFile
        let pinnedActions = OpenWorktreeAction.pinnedToolbarCases(settings: settingsFile.global)
```
In the `WorktreeToolbarState(` argument list, replace `openActionSelection: openActionSelection,` with:
```swift
          pinnedActions: pinnedActions,
```

- [ ] **Step 3: `WorktreeToolbarContent` — drop selection/copy-path closures**

In `struct WorktreeToolbarContent`, remove these stored properties:
```swift
    let onOpenActionSelectionChanged: (OpenWorktreeAction) -> Void
    let onCopyPath: () -> Void
```
In `detailBody`'s `WorktreeToolbarContent(` call, remove the `onOpenActionSelectionChanged:` and `onCopyPath:` arguments (lines 89–95).

- [ ] **Step 4: Replace `openMenu` usage with an icon row**

In `WorktreeToolbarContent.body`, replace the `ToolbarItemGroup { openMenu(...) }` block (currently lines ~417–422) with:
```swift
      if !toolbarState.pinnedActions.isEmpty {
        ToolbarItemGroup {
          ForEach(toolbarState.pinnedActions, id: \.id) { action in
            Button {
              onOpenWorktree(action)
            } label: {
              OpenWorktreeActionToolbarIcon(action: action)
            }
            .help("Open in \(action.title)")
          }
        }
        ToolbarSpacer(.fixed)
      }
```

- [ ] **Step 5: Delete `openMenu`, `openActionHelpText`; keep `shortcutDisplay`**

Delete the entire `private func openMenu(...)` and `private func openActionHelpText(...)` methods. Keep `shortcutDisplay` (still used by run-script help).

- [ ] **Step 6: Add a small icon view** (icon-only, 16×16) at file scope near `RunScriptToolbarButton`:
```swift
private struct OpenWorktreeActionToolbarIcon: View {
  let action: OpenWorktreeAction

  var body: some View {
    Group {
      switch action.menuIcon {
      case .app(let data):
        Image(nsImage: NSImage(data: data) ?? NSImage())
          .resizable()
          .frame(width: 16, height: 16)
      case .symbol(let name):
        Image(systemName: name)
      case .none:
        Image(systemName: "app.dashed")
      }
    }
    .accessibilityLabel(action.title)
  }
}
```

- [ ] **Step 7: Fix the preview** (`WorktreeToolbarPreview`)

In the `WorktreeToolbarState(` literal inside the preview, replace `openActionSelection: .finder,` with:
```swift
      pinnedActions: [.finder],
```
Remove `onOpenActionSelectionChanged:` and `onCopyPath:` from the preview's `WorktreeToolbarContent(` call (around line 700).

- [ ] **Step 8: Build + commit**
```bash
make build-app
git add cherrylily/Features/Repositories/Views/WorktreeDetailView.swift
git commit -m "feat(toolbar): render pinned app icons; remove Open-in dropdown"
```
(Will not fully build until Task 6 removes `.openActionSelectionChanged` sender — do Tasks 5 and 6 together before building if needed.)

---

## Task 6: Remove default-open machinery from AppFeature

**Files:**
- Modify: `cherrylily/Features/App/Reducer/AppFeature.swift`
- Modify: `cherrylily/Support/CustomDump+Extensions.swift`
- Test: `cherrylilyTests/` (adjust any test referencing removed cases)

- [ ] **Step 1: Remove State + Action members**

In `State`, delete `var openActionSelection: OpenWorktreeAction = .finder`.
In `enum Action`, delete `case openActionSelectionChanged(OpenWorktreeAction)` and `case openSelectedWorktree`.

- [ ] **Step 2: Remove reducer cases**

Delete the whole `case .openActionSelectionChanged(let action):` block (lines ~346–355) and the `case .openSelectedWorktree:` block (lines ~357–359).

- [ ] **Step 3: Remove the two `openActionSelection` assignments**

- In the `guard let worktree else {` cleanup block, delete `state.openActionSelection = .finder`.
- In `.settings(.delegate(.settingsChanged(...)))`, delete the `state.openActionSelection = OpenWorktreeAction.fromSettingsID(...)` assignment (lines ~288–292) and the now-unused `@Shared(.repositorySettings(rootURL)) var repositorySettings` / `@Shared(.settingsFile) var settingsFile` locals if they become unused there. (Verify by compiler; remove only if unused.)
- In `.worktreeSettingsLoaded`, delete the `state.openActionSelection = OpenWorktreeAction.fromSettingsID(...)` block (lines ~643–647) and the now-unused `normalizedDefaultEditorID`/`settingsFile` locals if unused; keep `state.selectedRunScript = settings.runScript`.

- [ ] **Step 4: CustomDump**

In `cherrylily/Support/CustomDump+Extensions.swift:47`, delete the `openAction: openActionSelection,` line.

- [ ] **Step 5: Keep `.openWorktree`** (icons fire it) — no change to that case.

- [ ] **Step 6: Adjust tests** — search and update:
```bash
grep -rn "openActionSelection\|openSelectedWorktree\|openActionSelectionChanged" cherrylilyTests/
```
Remove/repoint any test asserting these. (If `AppFeature*` tests exercised `.openSelectedWorktree`, replace with `.openWorktree(.finder)` where still meaningful, else delete the test.)

- [ ] **Step 7: Build + commit**
```bash
make build-app
git add cherrylily/Features/App/Reducer/AppFeature.swift cherrylily/Support/CustomDump+Extensions.swift cherrylilyTests/
git commit -m "refactor(app): remove per-repo default-open machinery"
```

---

## Task 7: Remove menu command, focused value, and open shortcut

**Files:**
- Modify: `cherrylily/Commands/WorktreeCommands.swift`
- Modify: `cherrylily/Features/Repositories/Views/WorktreeDetailView.swift`
- Modify: `cherrylily/App/AppShortcuts.swift`

- [ ] **Step 1: WorktreeCommands** — remove the command, the focused-value property, and the key.

- Delete the property `@FocusedValue(\.openSelectedWorktreeAction) private var openSelectedWorktreeAction`.
- Delete `let openWorktree = AppShortcuts.openFinder.effective(from: overrides)`.
- Delete the `Button("Open Worktree") { openSelectedWorktreeAction?() } …` block (lines ~69–74).
- In the `extension FocusedValues`, delete the `var openSelectedWorktreeAction` computed property, and delete the `OpenSelectedWorktreeActionKey` struct definition (search for it in the file).

- [ ] **Step 2: WorktreeDetailView** — remove focused-value wiring.

- In `applyFocusedActions`, delete `.focusedSceneValue(\.openSelectedWorktreeAction, actions.openSelectedWorktree)`.
- In `struct FocusedActions`, delete `let openSelectedWorktree: (() -> Void)?`.
- In `makeFocusedActions`, delete `openSelectedWorktree: action(.openSelectedWorktree),`.

- [ ] **Step 3: AppShortcuts** — stop using `openFinder` for opening (keep the enum case for override decode-compat).

In the `.actions` group `shortcuts:` array (line ~331), remove `openFinder,`:
```swift
      shortcuts: [openRepository, openPullRequest, copyPath, runScript, stopRunScript]
```
Leave `case openFinder` in `AppShortcutID`, the `static let openFinder`, and its string mappings intact (so persisted overrides still decode); it simply becomes unbound.

- [ ] **Step 4: Build + commit**
```bash
make build-app
git add cherrylily/Commands/WorktreeCommands.swift cherrylily/Features/Repositories/Views/WorktreeDetailView.swift cherrylily/App/AppShortcuts.swift
git commit -m "refactor: remove Open Worktree command and open shortcut"
```

---

## Task 8: Full build, test sweep, lint

- [ ] **Step 1: Format + lint**
```bash
make check
```
Fix any violations (trailing commas, 120 col).

- [ ] **Step 2: Full build**
```bash
make build-app
```
Expected: success.

- [ ] **Step 3: Full test run**
```bash
make test
```
Expected: all pass. Fix fallout (most likely removed-symbol references in tests).

- [ ] **Step 4: Manual smoke (in a separate terminal, NOT by quitting CherryLily):** launch the dev build, confirm:
  - Toolbar shows Finder + default editor icons by default; clicking opens the worktree there.
  - Settings → App Launcher: pin/unpin updates the toolbar live (no restart); reorder changes icon order; custom app pin shows its icon.
  - Run button unchanged. "Open Worktree" menu item and ⌘O open are gone; Copy Path still available via worktree row context menu.

- [ ] **Step 5: Final commit (if lint fixups)** and open PR.
```bash
git add -A
git commit -m "chore: lint/build fixups for toolbar app icons"
```

---

## Self-review notes
- Spec coverage: dropdown removal (T5/T7), settings selection (T3/T4), icons side-by-side (T5/T6), dynamic-no-restart via `@Shared` (T5 reads settings each render), Run button untouched (verified, no edits to RunScript path), seed Finder+editor (T1). Custom-app icon collision fixed (T2).
- Known limitation documented in settings footer: newly-installed apps need restart (process-lifetime `OpenWorktreeActionCache`).
- Copy Path: dropped from toolbar (dropdown gone) but remains in worktree row context menu (`WorktreeRowsView.swift:282`); not a regression of capability.
- Sequencing caveat: Tasks 5–7 are interdependent (removing senders vs. handlers). Build only after all three; commit per task is fine since intermediate states may not compile. Reviewer should treat T5–T7 as one buildable unit.
