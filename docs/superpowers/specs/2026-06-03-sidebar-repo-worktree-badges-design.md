# Sidebar Repo & Worktree Badges — Design

**Date:** 2026-06-03
**Branch:** pwason/badges
**Status:** Approved

## Summary

Improve the repositories sidebar with three changes:

1. Restyle the repo header name — larger, bold, white, with a leading accent bar.
2. Add a **worktree count** badge, right-aligned on the repo header line.
3. Add a **tab count** badge, right-aligned on each worktree row.

The app is dark-mode; all styling uses system-provided colors and Dynamic Type.

## Motivation

The repo name currently renders small and dim (`.foregroundStyle(.secondary)`, default body font) and is easy to overlook. The faint line the user perceived as an "underline" is actually the section's top separator. Users also have no at-a-glance sense of how many worktrees a repo has or how many tabs are open in a worktree.

## Design

### 1. Repo header name (`RepoHeaderRow.swift`)

- Font: `.headline` (≈15pt, semibold/bold) instead of default body. Honors Dynamic Type.
- Color: `.primary` (renders white in dark mode) instead of `.secondary`.
- Leading accent bar: a 3pt-wide, rounded `Capsule`/`RoundedRectangle` filled with `.tint` (system accent), insetting the row content. ~6pt spacing between bar and text.
- The `isRemoving` "Removing..." sub-text keeps its current `.caption` / `.tertiary` styling.

### 2. Worktree count badge (repo header line)

- A pill, right-aligned on the repo header row, showing `repository.worktrees.count`.
- Style: number only (no icon), `.caption` weight `.semibold`, `.secondary` foreground, on a `Color.secondary.opacity(~0.12)`-style rounded background (`Capsule`) with horizontal padding. `monospacedDigit()`.
- Placement: `RepoHeaderRow` already sits inside an `HStack` with `.frame(maxWidth: .infinity, alignment: .leading)` in `RepositorySectionView`, followed by hover-only buttons. The count must remain visible whether or not the row is hovered, and sit to the right of the name but before the hover action buttons. The count is added inside `RepoHeaderRow` after a `Spacer`, so it trails the name and the whole unit is leading-aligned with the count pushed right within the name's available width.

### 3. Tab count badge (worktree row)

- A pill, right-aligned on each worktree row's name line, showing the number of open tabs for that worktree.
- Data source: `terminalManager.stateIfExists(for: worktree.id)?.tabManager.tabs.count ?? 0`.
- Same pill visual style as the worktree count, slightly smaller (`.caption2`-ish). `monospacedDigit()`.
- Placement: in `WorktreeRow`'s top `HStack`, on the trailing side. The row already has `Spacer(minLength: 4)` followed by run-script indicator, change-counts, and hover buttons. The tab-count pill sits in this trailing cluster and remains visible when not hovered (unlike the pin/archive buttons which are hover-only). Order: name … Spacer … [tab count] [run-script] [change counts] [hover buttons].
- When a worktree row is selected (highlighted), the pill adapts contrast like the existing change-count view does (lighter background/text on the selection tint).

### 4. Separators (no change needed)

- `RepositorySectionView` draws a 1pt secondary rectangle at the top of a repo header when `showsTopSeparator` is true.
- The caller `SidebarListView.swift` already passes `showsTopSeparator: index > 0`. This yields exactly the requested behavior: **no line above the first repo, a divider at the top of every subsequent repo (i.e. between sections), and nothing below the last repo.**
- **Conclusion: no separator code change is required.** Confirmed against `SidebarListView.swift:91` and `:141`.

## Components Touched

| File | Change |
|------|--------|
| `RepoHeaderRow.swift` | Name font/color/accent bar; add worktree-count param + pill |
| `RepositorySectionView.swift` | Pass `worktreeCount` into `RepoHeaderRow`; confirm separator logic |
| `WorktreeRow.swift` | Add `tabCount` param + trailing pill |
| `WorktreeRowsView.swift` | Compute `tabCount` from `terminalManager` and pass into `WorktreeRow` |
| A small shared `CountBadge`/pill view | Reusable pill for both counts |

## Reusable Component

Introduce a small `CountBadge` view (e.g. `Features/Repositories/Views/CountBadge.swift`):

```
CountBadge(count: Int, isSelected: Bool = false)
```

Renders the number in a capsule with secondary styling, `monospacedDigit()`, adapting contrast when `isSelected`. Both the repo worktree-count and the worktree tab-count use it (size variant via a parameter or font modifier on the call site).

## Data Flow

- Worktree count: synchronous, from `repository.worktrees.count` (already in `Repository` domain model).
- Tab count: read from the `@Observable` `WorktreeTerminalManager` via `stateIfExists(for:)`. Because `WorktreeRowsView` already receives `terminalManager` and the manager is `@Observable`, SwiftUI re-renders when `tabManager.tabs` changes. No new TCA state, no new client, no NSNotification.

## Out of Scope / YAGNI

- No badge for collapsed-vs-expanded counts beyond the raw numbers.
- No icons in the badges (numbers only, per decision).
- No animation on count change beyond SwiftUI defaults.
- No persistence or settings toggle for showing/hiding badges.

## Testing

- These are view-layer changes reading existing state; no new reducer logic is introduced, so no new reducer tests are required (per project rule, tests are added when reducer logic changes).
- If a small pure helper is added (e.g. a function computing tab count for a worktree id), add a focused unit test for it.
- Manual verification: build the app, confirm repo name styling, worktree-count pill updates when worktrees are added/removed, tab-count pill updates when tabs open/close, separators correct at top/bottom, and selected-row contrast is legible.

## Build / Done Criteria

- `make build-app` succeeds.
- `make check` (format + lint) passes; trailing commas, 2-space indent, 120-col.
- Changes committed on `pwason/badges`; PR opened.
