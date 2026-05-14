# Back/Forward Tab Navigation — Design

## Goal

Replace the branch-name button on the `WorktreeDetailView` toolbar with two arrow buttons that act as browser-style back/forward navigation across recently focused tabs. The navigation operates on `(worktree, tab)` history, dedupes consecutive identical entries, clears forward on a fresh selection, skips entries whose worktree or tab no longer exists, and lives only in memory (no persistence across launches).

The branch-rename action moves to a sidebar context menu and keeps its `⌘M` keyboard shortcut.

## Decisions

| Question | Decision |
|---|---|
| Granularity | Tab-level: each `(worktreeID, tabID)` focus is one history entry |
| Forward stack on new selection | Browser-like — clear forward when a fresh selection is made |
| Actions that record | Sidebar click, tab-bar click, keyboard tab/worktree switch, programmatic jumps |
| Persistence | In-memory only |
| Keyboard shortcuts | ⌘← back, ⌘→ forward |
| Rename branch | Move to sidebar context menu; keep ⌘M shortcut |
| Implementation | `NavigationHistory` value type in `AppFeature.State` |

## Architecture

### Data model

```swift
struct NavigationEntry: Equatable, Hashable {
  let worktreeID: Worktree.ID
  let tabID: TerminalTabID?   // nil if the worktree has no tabs at the moment
}

struct NavigationHistory: Equatable {
  private(set) var backStack: [NavigationEntry] = []   // top == current
  private(set) var forwardStack: [NavigationEntry] = []
  let cap = 50

  var current: NavigationEntry? { backStack.last }
  var canGoBack: Bool { backStack.count > 1 }
  var canGoForward: Bool { !forwardStack.isEmpty }

  /// Idempotent. If `entry == current`, no-op. Otherwise pushes and clears forward.
  mutating func record(_ entry: NavigationEntry)

  /// Returns destination, or nil if no valid prior entry remains.
  /// Discards invalid entries from history as it walks. On success, the
  /// previous current entry is moved to forwardStack.
  mutating func goBack(isValid: (NavigationEntry) -> Bool) -> NavigationEntry?

  /// Mirror of goBack for the forward direction.
  mutating func goForward(isValid: (NavigationEntry) -> Bool) -> NavigationEntry?
}
```

**Why idempotent recording:** removes the need for an "isNavigatingFromHistory" flag. The back/forward effect drives `selectWorktree` + `focusTab`, which fires the existing change events; those events feed `record(...)`, but since `current` already equals the destination, both no-op. Same trick handles "user clicks the same tab twice".

**Cap behavior:** when pushing makes `backStack.count + forwardStack.count > 50`, drop oldest entries from the bottom of `backStack`.

### Where it lives

- `var navigationHistory = NavigationHistory()` added to `AppFeature.State`.
- Two new top-level actions on `AppFeature.Action`:
  - `case navigateBack`
  - `case navigateForward`

### Event sources that feed `record(...)`

1. **Worktree change** — existing `repositories(.delegate(.selectedWorktreeChanged(worktree)))` handler in `AppFeature` (lines 128–171). After the existing logic, call:
   ```swift
   state.navigationHistory.record(
     NavigationEntry(worktreeID: worktree.id, tabID: currentTabID(for: worktree.id))
   )
   ```
   `currentTabID(for:)` reads `worktreeTerminalManager.stateIfExists(for:)?.tabManager.selectedTabId`.

2. **Tab focus change** — a new event:
   ```swift
   // TerminalClient.Event
   case tabFocusChanged(worktreeID: Worktree.ID, tabID: TerminalTabID)
   ```
   Emitted by `WorktreeTerminalState` only when `TerminalTabManager.selectedTabId` actually changes. The existing `focusChanged(...surfaceID)` is split-level and is too noisy for history (a tab can contain multiple split surfaces; intra-tab focus changes should not push history). We keep `focusChanged` for everything that already uses it and add `tabFocusChanged` alongside it.

   AppFeature's existing terminal-event subscription handles this case and calls:
   ```swift
   state.navigationHistory.record(
     NavigationEntry(worktreeID: worktreeID, tabID: tabID)
   )
   ```

### New TerminalClient command

```swift
// TerminalClient.Command
case focusTab(worktreeID: Worktree.ID, tabID: TerminalTabID)
```

Implemented in `WorktreeTerminalManager` by routing to the worktree's `WorktreeTerminalState`, which calls `tabManager.selectTab(tabID)` and focuses the tab's primary surface so Ghostty receives focus correctly.

### Effect for navigateBack / navigateForward

```swift
case .navigateBack:
  let isValid: (NavigationEntry) -> Bool = { entry in
    state.repositories.allWorktrees.contains(where: { $0.id == entry.worktreeID }) &&
    (entry.tabID.map { tabExists(in: entry.worktreeID, tabID: $0) } ?? true)
  }
  guard let dest = state.navigationHistory.goBack(isValid: isValid) else { return .none }
  return .merge(
    .send(.repositories(.selectWorktree(dest.worktreeID, focusTerminal: true))),
    dest.tabID.map { tabID in
      .run { _ in await terminalClient.send(.focusTab(worktreeID: dest.worktreeID, tabID: tabID)) }
    } ?? .none
  )
```

`navigateForward` is symmetric.

`tabExists(in:tabID:)` reads from the same `WorktreeTerminalManager` access path used by `currentTabID(for:)`. If the tab exists but the worktree is currently the focused one, `selectWorktree` is a no-op and only the tab focus moves; if the worktree changes, both effects fire.

### UI changes

**Removed:** `WorktreeDetailTitleView` from the toolbar in `WorktreeDetailView.swift` (lines 271–278). In `WorktreeDetailTitleView.swift`, delete the title-button view; keep `RenameBranchPopover` (it will be reused by the sidebar context menu and the ⌘M shortcut). Rename the file to `RenameBranchPopover.swift`.

**Added:** Two `ToolbarItem`s in the leading slot, in this order:

```
[ ◀ chevron.backward ]  [ ▶ chevron.forward ]   …existing flexible spacer + status + open menu + run script
```

Both are SwiftUI `Button`s with system images, plain monochrome style, standard toolbar size. No custom colors.

**State binding** for each:
- `disabled(!store.navigationHistory.canGoBack)` / `canGoForward`
- `keyboardShortcut(.leftArrow, modifiers: .command)` / `(.rightArrow, modifiers: .command)`
- `help(...)` tooltip:
  - Enabled: `"Back to <repoName> · <branch>[ · <tabTitle>] (⌘←)"` — peek destination is `backStack.dropLast().last`. Same shape for forward (`forwardStack.last`).
  - Disabled: `"Back (⌘←)"` / `"Forward (⌘→)"`.
- Action: `store.send(.navigateBack)` / `.navigateForward` (top-level `AppFeature.Action`, not nested under `repositories`).

The peek mapper that turns a `NavigationEntry` into the tooltip string handles stale entries gracefully (worktree gone → fall back to "Back (⌘←)").

### Branch rename relocation

- In `SidebarListView`'s worktree row: add `.contextMenu { Button("Rename Branch…") { … } }` that surfaces the existing `RenameBranchPopover` anchored on the row (or as a sheet — pick whichever reads cleanly inside a context menu).
- The rename action is unchanged: still calls `repositories(.requestRenameBranch(worktreeID, newName))`. Validation, error alert, and the `branch_renamed` analytics event stay as-is.
- **⌘M shortcut preserved** at the `WorktreeDetailView` level — triggers rename for the currently focused worktree by opening the popover/sheet over the detail view.

## Edge cases

- **First launch.** Repository auto-restore fires `selectedWorktreeChanged` → `record` pushes one entry. `canGoBack=false` (only 1 in stack), `canGoForward=false`. Both buttons disabled.
- **Worktree removed** (`/wt-done`, sidebar delete). No eager purge. The next time the user hits back/forward and the destination's worktree no longer exists, `isValid` returns false; `goBack`/`goForward` discards the entry and continues walking until it finds a valid one or the stack is empty.
- **Tab closed.** Same lazy strategy. If the destination's `tabID` is nonexistent in the worktree, drop the entry. We do *not* fall back to "any tab in that worktree" — we drop the whole entry to keep semantics predictable.
- **Worktree with no tabs yet.** Entry has `tabID == nil`. `isValid` accepts it; navigating just selects the worktree.
- **Cap.** When pushing makes total > 50, drop oldest from the bottom of `backStack`.
- **Tab created/closed via terminal events.** These don't push history themselves. Tab creation typically results in the new tab becoming focused, which fires `tabFocusChanged`, which records. So creating a tab naturally adds an entry.
- **Rapid back-back-back.** Each press is independent; each sends a navigate effect; each effect causes selection events that idempotent-record into the (already correct) `current`. AppFeature serializes actions, so no races.

## Testing plan

Use TCA `TestStore` per CLAUDE.md. No `Task.sleep` — use `TestClock` for any timing.

- **Record sequence.** Push A → B → C; assert `backStack == [A, B, C]`, `forwardStack == []`.
- **Idempotent.** Record C again; assert state unchanged.
- **Back.** Assert effect dispatches `selectWorktree(B.worktreeID)` and `focusTab(B.worktreeID, B.tabID)`; simulate the resulting `selectedWorktreeChanged` and `tabFocusChanged` events; assert no double-push (`backStack == [A, B]`, `forwardStack == [C]`).
- **Back-then-record(D).** Assert `forwardStack` is cleared (`backStack == [A, B, D]`, `forwardStack == []`).
- **Stale entry.** Invalidate B (worktree removed); back from C should land on A; assert B is removed from both stacks.
- **Stale tab.** Invalidate the tab on B (tab closed); back from C should drop B and land on A.
- **Cap.** Push 60 entries; assert combined size is 50; assert oldest entries dropped.
- **canGoBack/canGoForward bindings** drive button `disabled` state correctly.
- **`focusTab` command** — unit test in `WorktreeTerminalManager` that the command routes to the right worktree's tab manager and selects the tab.
- **`tabFocusChanged` event** — unit test that `WorktreeTerminalState` emits the event only when `selectedTabId` actually changes (not for split focus changes within the same tab).

## Out of scope

- Right-click history dropdown on back/forward buttons (browser-style "long history list").
- Persistence across app launches.
- Cross-window history (each window, if multi-window is added later, would have its own).
- Eager purge of history when worktrees/tabs are removed (lazy purge on navigation is sufficient).
