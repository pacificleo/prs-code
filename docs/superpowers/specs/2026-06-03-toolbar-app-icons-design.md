# Toolbar App Icons (replace "Open in…" dropdown)

Date: 2026-06-03
Branch: pwason/apps
Status: Approved design — ready for implementation plan

## Summary

Replace the worktree toolbar's "Open in…" split-button + dropdown with a fixed
row of icon-only buttons, one per app the user has **pinned to the toolbar** in
Settings. Clicking an icon opens the selected worktree's directory in that app.
The Run button is unchanged. Pinning is a new, explicit settings concept; the
toolbar updates live (no restart) when pins change.

## Goals

1. Remove the dropdown (split-button + chevron menu) completely.
2. Let the user choose which apps appear, via a new "pin to toolbar" selection
   in Settings.
3. Render pinned apps as icons placed directly next to each other (no dropdown),
   in user-defined order.
4. Changes in Settings take effect dynamically (no restart) for pin/unpin/
   reorder/add-custom. Detecting a brand-new on-disk install still needs a
   restart (documented limitation).
5. Keep the Run button as-is.

## Non-goals

- `defaultEditorID` / the Appearance "Default editor" picker / `$EDITOR`
  (`.editor`) behavior — left untouched.
- Cache invalidation for newly-installed apps (YAGNI; documented limitation).
- Any change to the Run-script feature.

## Current behavior (for reference)

- Toolbar `openMenu` (`WorktreeDetailView.swift:443`) renders a primary button
  (opens the per-repo default app) plus a chevron `Menu` listing
  `OpenWorktreeAction.availableCases` + "Copy Path".
- The default app is `state.openActionSelection`, persisted per repository as
  `repositorySettings.openActionID`, and restored from `defaultEditorID` on load.
- The same default-open is reachable from the menu bar: **Worktrees ▸ Open
  Worktree** (`WorktreeCommands.swift:69`), bound to `AppShortcuts.openFinder`
  (⌘O) via the `openSelectedWorktreeAction` focused value → `.openSelectedWorktree`.
- App install-status and icons are resolved through `OpenWorktreeActionCache`
  (process-lifetime, lock-guarded) — every toolbar render is cache-backed.

## Design

### 1. Settings model (`GlobalSettings`)

- **Add** `pinnedToolbarActions: [String]` — ordered list of `settingsID`s
  (built-in `settingsID` or custom-action `id`). Order defines left→right icon
  order in the toolbar.
- **Decode default / migration:** when the key is absent (existing users), seed
  with `["finder", <resolved default editor settingsID>]`, de-duplicated, keeping
  only installed entries. The resolved default editor comes from the existing
  `defaultEditorID` (falling back to the auto-detected preferred editor). New
  installs get the same seed.
- **Retire** `disabledWorktreeActions`: keep the stored field for decode-compat,
  but stop reading it anywhere. (It only ever fed the now-deleted dropdown.)

### 2. Pinned-action resolution (`OpenWorktreeAction`)

- Add a resolver, e.g.
  `static func pinnedToolbarCases(settings: GlobalSettings) -> [OpenWorktreeAction]`,
  that maps `settings.pinnedToolbarActions` (in order) to `OpenWorktreeAction`
  values, dropping ids that are not installed / no longer exist. Built-ins map
  by `settingsID`; custom ids map to the matching `CustomWorktreeAction`.
- **Custom-app icons must not collide.** Today custom actions are built with
  `bundleIdentifier == "custom"`, so `menuIcon` resolves through the shared
  `"custom"` cache key and returns `nil` (no icon). Fix: carry the custom app's
  own icon into the action so each renders its own icon. Approach: extend
  `OpenWorktreeAction.MenuIcon` usage so a custom action returns
  `.app(customAction.icon)` when `icon` data is present (fallback to a generic
  SF Symbol when absent), bypassing the `"custom"` cache key. Built-in icon
  resolution stays on `OpenWorktreeActionCache` unchanged.

### 3. Settings view (`AppLauncherSettingsView`)

Rework into the pin manager:

- A single list of pinnable apps: installed built-ins (`menuOrder` filtered by
  `isInstalled`) plus custom apps. Each row shows the app icon + name and a
  toggle "Show in toolbar" (membership in `pinnedToolbarActions`).
- The pinned rows are **drag-reorderable**; order writes back to
  `pinnedToolbarActions`.
- "Add Application" (custom apps) stays; newly added custom apps appear in the
  list and can be pinned.
- Removing a custom app also removes it from `pinnedToolbarActions`.
- All reads/writes go through `@Shared(.settingsFile)` directly (no new
  dependency client), per project conventions. Mutations use
  `$settingsFile.withLock`.

### 4. Toolbar (`WorktreeDetailView`)

- Delete `openMenu(...)` and its helpers (`openActionHelpText`, the
  `OpenWorktreeActionMenuLabelView` usage for the dropdown).
- Add a `ToolbarItemGroup` rendering pinned apps:
  ```
  ForEach(pinnedActions) { action in
    Button { onOpenWorktree(action) } label: { icon(for: action) }
      .help("Open in \(action.title)")
  }
  ```
  - Icons are icon-only, 16×16, sourced from `action.menuIcon` (cache-backed for
    built-ins; per-app data for customs). SF-symbol fallback when no icon.
  - Placed in the existing toolbar region to the left of the Run button; the Run
    button group is unchanged.
  - Tooltip on every button ("Open in <App>"), per UX standards.
- `pinnedActions` derive from `@Shared(.settingsFile).pinnedToolbarActions` so
  the row re-renders live on settings changes.
- Each button fires the existing `.openWorktree(action)` reducer action (kept).

### 5. Cleanup / removals

Remove the orphaned default-open machinery:

- `AppFeature`: `openActionSelection` state, `openActionSelectionChanged` action,
  `.openSelectedWorktree` action, and the `openActionID` read/write
  (`repositorySettings.openActionID`). Remove the `openActionSelection`
  initialization paths (lines ~154, ~288, ~643) and the CustomDump reference
  (`CustomDump+Extensions.swift:47`).
- Menu bar: remove **Worktrees ▸ Open Worktree** button (`WorktreeCommands.swift`)
  and the `openSelectedWorktreeAction` focused value + its `focusedSceneValue`
  wiring.
- `AppShortcuts`: remove `openFinder` from the active/displayed shortcut list
  (line ~331) and its remaining references. **Keep the `openFinder` enum case**
  so persisted `shortcutOverrides` still decode; it simply becomes unused.
- Keep `repositorySettings.openActionID` field for decode-compat (stop using it).

### 6. Dynamic update & known limitation

- Pin/unpin/reorder and add/remove custom apps update `settingsFile` (`@Shared`),
  which the toolbar observes → live re-render, no restart.
- A brand-new app installed on disk while the app is running is not detected
  until restart, because `OpenWorktreeActionCache` is process-lifetime. Accepted;
  documented in settings copy if helpful. No cache-invalidation built.

## Testing (per project: add tests for reducer changes)

- `.openWorktree(action)` still opens the correct app for built-in and custom
  pinned actions (existing coverage retained/updated).
- `OpenWorktreeAction.pinnedToolbarCases` ordering, filtering of uninstalled /
  missing ids, and custom-action mapping (including own-icon resolution).
- `GlobalSettings` migration: absent `pinnedToolbarActions` seeds Finder +
  default editor (installed-only, de-duplicated); present value round-trips.
- Settings pin/unpin/reorder mutate `pinnedToolbarActions` correctly; removing a
  custom app also unpins it.
- Removed paths: assert `.openSelectedWorktree` / `openActionSelectionChanged`
  no longer exist (compile-level), and no test depends on the dropdown.

## Open risks

- Removing an `AppShortcut` case is risky for override decoding; mitigated by
  keeping the enum case and only unwiring it.
- Many pinned apps produce a wide icon row (no limit, per decision); acceptable
  since the user controls the count.
