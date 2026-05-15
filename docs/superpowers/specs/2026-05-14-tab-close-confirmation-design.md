# Tab Close Confirmation Dialog — Design

## Goal

Show a confirmation dialog before closing a terminal tab, gated by a new "Confirm before closing terminal tabs" setting (default ON). All four close paths route through the prompt: the tab-bar X button, the tab context menu's Close / Close Others / Close to the Right items, the ⌘W menu command, and Ghostty's own close-tab keybinding.

Single-pane (split / surface) close is **out of scope** — that's a finer-grained action that rarely loses meaningful work. Worktree-deletion / pruning paths also bypass the prompt because the user has already confirmed at the worktree level.

## Decisions

| Question | Decision |
|---|---|
| Behavior | Setting-gated, default ON |
| Trigger paths | Tab-bar X, context menu Close items, ⌘W menu, Ghostty close-tab binding |
| Bulk handling (Close Others / Close to the Right) | One consolidated dialog ("Close N tabs?") |
| Dialog content | Tab title in the prompt; no "Don't ask again" checkbox |

## Architecture

### Setting

Add a new property to `GlobalSettings`:

```swift
var confirmBeforeClosingTabs: Bool   // default true
```

Mirror onto `SettingsFeature.State` and add the corresponding wire-through in `init`, `globalSettings`, `settingsLoaded` (matching every other setting field).

Surface a `Toggle("Confirm before closing terminal tabs", isOn: $store.confirmBeforeClosingTabs)` in the settings view that hosts "Confirm Before Quit". Tooltip: `"Show a confirmation dialog when closing a tab."`.

### Action surface (AppFeature)

Three new request actions:

```swift
case requestCloseTab(worktreeID: Worktree.ID, tabID: TerminalTabID)
case requestCloseOtherTabs(worktreeID: Worktree.ID, keepingTabID: TerminalTabID)
case requestCloseTabsToRight(worktreeID: Worktree.ID, ofTabID: TerminalTabID)
```

Each handler:
1. If `state.settings.confirmBeforeClosingTabs == false` → fire the post-confirmation effect immediately.
2. Else → look up the tab title via `terminalClient.tabTitle(worktreeID, tabID)`, build an `AlertState<Alert>` with that title, present it via the existing `state.alert`.

Two new `AppFeature.Alert` cases:

```swift
case confirmCloseTab(worktreeID: Worktree.ID, tabID: TerminalTabID)
case confirmCloseTabs(worktreeID: Worktree.ID, kind: BulkCloseKind, anchorTabID: TerminalTabID)

enum BulkCloseKind: Equatable { case others, toRight }
```

`alert(.presented(.confirmCloseTab))` and `alert(.presented(.confirmCloseTabs))` handlers run the actual close via the new `TerminalClient` commands (below) and clear `state.alert`.

**Why request/confirm split:** keeps the existing `closeTab` action available unchanged for callers that explicitly want no prompt (worktree archive cleanup, pruning).

### TerminalClient surface

New commands (by-id variants for the bulk and post-confirmation single cases; existing `closeFocusedTab(Worktree)` stays for the ⌘W focused-tab path):

```swift
case closeTab(worktreeID: Worktree.ID, tabID: TerminalTabID)
case closeOtherTabs(worktreeID: Worktree.ID, keepingTabID: TerminalTabID)
case closeTabsToRight(worktreeID: Worktree.ID, ofTabID: TerminalTabID)
```

New event:

```swift
case tabCloseRequested(worktreeID: Worktree.ID, tabID: TerminalTabID)
```

New query:

```swift
var tabTitle: @MainActor @Sendable (Worktree.ID, TerminalTabID) -> String?
```

`WorktreeTerminalManager` implements all three — the by-id close commands route to `WorktreeTerminalState.closeTab(_:)` / `closeOtherTabs(keeping:)` / `closeTabsToRight(of:)` (which already exist). `tabTitle` reads `stateIfExists(for:)?.tabManager.tabs.first(where: { $0.id == tabID })?.title`.

### Trigger path rewiring

1. **Tab bar X button + context menu close items.** `WorktreeTerminalTabsView` currently passes `closeTab: { tabId in state.closeTab(tabId) }` (and similar for `closeOtherTabs`, `closeTabsToRight`) directly to its child views. Switch those callbacks to `store.send(.requestCloseTab(worktreeID, tabID))` etc. The view needs `@Bindable var store: StoreOf<AppFeature>` if not already, plus `worktreeID` in scope.

2. **⌘W menu command.** `AppFeature.Action.closeTab` currently does `await terminalClient.send(.closeFocusedTab(worktree))`. Change to:

   ```swift
   case .closeTab:
     guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else { return .none }
     return .run { send in
       guard let tabID = await terminalClient.currentTabID(worktree.id) else { return }
       await send(.requestCloseTab(worktreeID: worktree.id, tabID: tabID))
     }
   ```

   The existing `closeTab` analytics capture moves to the post-confirmation effect.

3. **Ghostty close-tab keybinding.** `WorktreeTerminalState.createSurface` currently sets:

   ```swift
   view.bridge.onCloseTab = { [weak self] _ in
     guard let self else { return false }
     self.closeTab(tabId)
     return true
   }
   ```

   Change to invoke a new callback hook on `WorktreeTerminalState`:

   ```swift
   var onRequestCloseTab: ((TerminalTabID) -> Void)?

   view.bridge.onCloseTab = { [weak self] _ in
     guard let self else { return false }
     self.onRequestCloseTab?(tabId)
     return true
   }
   ```

   The closure returns `true` synchronously to acknowledge Ghostty's binding; the actual close is deferred.

   `WorktreeTerminalManager` wires the hook to emit `TerminalClient.Event.tabCloseRequested(worktreeID, tabID)`. AppFeature subscribes (already does for `terminalEvent`) and dispatches `.requestCloseTab(...)`.

### Dialog content

Single tab close:
- Title: `"Close \"<tab title>\"?"` (fallback `"Close tab?"` if title lookup returns nil)
- Body: none
- Buttons: `Close` (default, `.destructive` role), `Cancel` (`.cancel` role)

Bulk Close Others:
- Title: `"Close other tabs in '<branch>'?"` where `<branch>` is the worktree name
- Body: `"This will close N tab(s)."` (N computed at action-handle time from the worktree's tab manager)
- Same buttons

Bulk Close to the Right:
- Title: `"Close tabs to the right of \"<anchor tab title>\"?"`
- Body: `"This will close N tab(s)."`
- Same buttons

## Edge cases

- **Setting OFF.** All paths close immediately, no behavior change vs today.
- **Last tab in worktree.** Still confirm. After confirmation, existing fallback behavior kicks in (worktree's last surface closes via the same paths used today).
- **Rapid double-trigger.** TCA's `@Presents` alert state holds at most one alert; a second `requestCloseTab` while one is presented is a no-op (the new `state.alert = AlertState { … }` overwrite would replace the prior, but since both prompts are equivalent for the same tab there's no user-visible issue).
- **Worktree deletion / archive cleanup.** Calls into `WorktreeTerminalManager.closeAllSurfaces()` / `closeFocusedTab` directly via the existing terminal-manager API rather than the new `request*` actions. No prompt — the user already confirmed at the worktree level.
- **Ghostty close-tab binding fires while a confirmation is on screen.** The new event `tabCloseRequested` reaches AppFeature, fires `.requestCloseTab` again, which sets the alert state to an equivalent prompt (same tab). Visually unchanged.
- **`closeFocusedSurface` (close one split inside a tab).** Unaffected — surface close keeps its current immediate behavior.
- **Bulk close target gone by the time the user confirms.** `WorktreeTerminalState.closeOtherTabs` / `closeTabsToRight` are tolerant — they iterate the tabs that exist at the moment they run.
- **Title contains quotes or other special characters.** Pass through to `TextState`; SwiftUI alert handles escaping.

## Testing plan

Use TCA `TestStore`. No `Task.sleep` — use `TestClock` for any timing.

- **`requestCloseTab` with confirm ON** → `state.alert` populated with the expected title; assert no `closeTab` command sent.
- **`alert(.presented(.confirmCloseTab))`** → `terminalClient.send(.closeTab(worktreeID, tabID))` issued; `state.alert` cleared.
- **`alert(.dismiss)`** → no command sent; alert cleared.
- **`requestCloseTab` with confirm OFF** → command sent immediately; `state.alert` never set.
- **`terminalEvent(.tabCloseRequested)` for current selection** → routes through to `requestCloseTab` and (with confirm ON) presents the alert.
- **`requestCloseOtherTabs` confirm-then-execute** → presents alert with body "This will close N tab(s)."; on confirm, sends `.closeOtherTabs`.
- **`requestCloseTabsToRight` confirm-then-execute** → same shape with the `closeTabsToRight` command.
- **Title lookup fallback** → when `tabTitle` returns nil, alert title is `"Close tab?"`.
- **Settings persistence** → toggling `confirmBeforeClosingTabs` via the binding action persists to `SettingsFile`.
- **`tabTitle` query** — unit test in `WorktreeTerminalManager` that the lookup returns the right title for an existing tab and `nil` for unknown.
- **`onRequestCloseTab` hook** — unit test that the Ghostty `onCloseTab` callback path fires the new hook (not the old direct close) when set.

## Out of scope

- "Don't ask again" inline checkbox in the dialog (keep dialog minimal; user can flip the setting).
- Confirm on close of a split / surface (only tab close).
- Confirm on app quit while tabs are open (already covered by the existing "Confirm Before Quit" setting).
- Per-worktree or per-tab override of the confirmation setting.
