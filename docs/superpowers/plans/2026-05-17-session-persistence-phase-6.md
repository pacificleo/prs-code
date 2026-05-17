# Session Persistence — Phase 6: Polish

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Spec:** `docs/superpowers/specs/2026-05-15-session-persistence-design.md`
**Phase 1-5 already implemented.**

**Goal:** Multi-surface split restoration (the TODO from Phase 3), OSC passthrough verification, and reattach UX polish.

---

## Task 1: Multi-surface (split tree) restoration

**Files:**
- Modify: `cherrylily/Features/Sessions/Models/SessionLayout.swift` — add structural fields to `PersistedTab` so split shape can be serialized
- Modify: `cherrylily/Features/Terminal/Models/WorktreeTerminalState.swift` — restoreTabs walks the split tree, recreating panes via `performSplitAction`
- Modify: `cherrylily/Features/Sessions/BusinessLogic/LayoutSnapshotBuilder.swift` — capture full split tree shape, not just leaves

Currently Phase 3 restores only the FIRST surface per tab. Splits are lost.

### Approach

Extend `PersistedTab` with `splitTree: PersistedSplitTree?` (nil = single surface = current behavior). `PersistedSplitTree` is a recursive Codable mirror of `SplitTree.Node`:

```swift
indirect enum PersistedSplitTree: Codable, Equatable, Sendable {
  case leaf(PersistedSurface)
  case split(direction: PersistedSplitDirection, ratio: Double,
             left: PersistedSplitTree, right: PersistedSplitTree)
}
enum PersistedSplitDirection: String, Codable, Sendable {
  case horizontal, vertical
}
```

`LayoutSnapshotBuilder` walks the live `SplitTree<GhosttySurfaceView>` and produces a `PersistedSplitTree`. `restoreTabs` does the inverse: create the leftmost leaf via `createTab`, then for each split node, call `performSplitAction(.new(direction:targetID:))` to add a pane, recursing.

### Test plan

- TDD `LayoutSnapshotBuilder` for a 3-pane horizontal split → expect 1 PersistedTab with a 2-level tree
- TDD a fake restore against an in-memory split-tree builder

---

## Task 2: OSC passthrough verification suite

**Files:**
- Create: `cherrylilyTests/OSCPassthroughTests.swift`
- Possibly: helper to launch a real tmux session and emit bytes through it

Verifies that under our tmux config, the following OSC sequences reach Ghostty as expected:
- BEL (0x07) → bell action fires
- OSC 7 (cwd) → tracked
- OSC 0/2 (title) → updated
- OSC 8 (hyperlink) → renders
- OSC 9 / OSC 777 (notifications) → fire
- OSC 133 (semantic prompt) → integration loaded

For each, we can't easily assert Ghostty's response from a unit test. But we CAN write an **integration test** that:
1. Spawns a tmux session on our custom socket
2. Sends sequences via `tmux send-keys`
3. `tmux capture-pane -p -e` to read back the output
4. Assert the sequence appears in the captured bytes (proving tmux didn't strip it)

This validates the tmux side of passthrough. The Ghostty side is harder to test programmatically; document as manual smoke test.

---

## Task 3: Reattach UX polish

**Files:**
- Modify: `cherrylily/Features/Terminal/Models/WorktreeTerminalState.swift` or `cherrylily/Features/Terminal/Views/TerminalSplitTreeView.swift`

On restore, when `cat <file>` dumps a multi-MB scrollback, the terminal "flashes" — first showing terminal-default state, then rapidly redrawing from the cat output. Spec line 311 acknowledges this as v1 acceptable.

For Phase 6 polish: render a brief "Restoring…" overlay until the first OSC 133 prompt arrives (signaling the shell is ready), then dismiss. This needs a hook on the bridge for the FIRST prompt event after restore.

- [ ] Add `bridge.state.hasReceivedFirstPrompt: Bool`
- [ ] Set to true on first GHOSTTY_ACTION_PROMPT_TITLE / OSC 133 event
- [ ] In LeafView, overlay a translucent "Restoring previous session…" until `hasReceivedFirstPrompt` becomes true OR a 2-second timeout elapses
- [ ] Only show overlay when surface was created with a scrollback file (otherwise it's a fresh session)

Pass an `isRestoring: Bool` from `createSurface` down to the view via GhosttySurfaceView property, default false. Set true when scrollback file existed at launch.

---

## Task 4: Migration messaging for existing users

**Files:**
- Modify: `cherrylily/App/supacodeApp.swift` — one-time first-run-after-upgrade banner

Per spec section 8: "No notification or onboarding modal." But add a one-time tip surfaced via the existing in-app notification system: "Tabs now restore across launches. Disable in Settings → Sessions."

Detect via a stored UserDefaults flag — show once, then never again.

---

## Task 5: Lint + push
