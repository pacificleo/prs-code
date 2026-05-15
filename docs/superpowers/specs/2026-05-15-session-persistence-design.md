# Session Persistence — Design

## Goal

Make terminal contents (tabs, splits, working directories, scrollback) come back when CherryLily is reopened — including across system reboots — without forcing the user to think about how it works. Settings are product-flavored ("Restore terminal contents on launch"); the implementation uses a bundled `tmux` binary as the persistent shell host. Live process / in-flight command resumption is **out of scope** (impossible without OS-level support).

## Decisions

| Question | Decision |
|---|---|
| Default state | **On.** Modern dev tools restore by default. |
| User awareness of tmux | **Zero.** UI never says "tmux", "session", "PTY", "pane". |
| tmux binary | **Bundled inside `CherryLily.app/Contents/MacOS/tmux-cherrylily`** — no external dependency. |
| Save trigger | **On app quit.** Optional hourly safety net (default off). |
| Restore mechanism | tmux server keeps shells alive between app quits. On reboot, replay saved scrollback into fresh sessions. |
| Mapping | **1 tmux server per CherryLily install, 1 tmux session per Ghostty surface.** Custom socket `cherrylily` isolates from user's own tmux. |
| Out-of-scope features | Live process resumption, command replay, restore of in-flight job state. Those are physically impossible across reboot. |

## Settings UI

A new **Sessions** section under Preferences (or in Appearance, alongside "Confirm Before Quit"):

```
┌─ Sessions ────────────────────────────────────────────────────┐
│                                                               │
│  ☑ Restore terminal contents on launch                        │
│      Tabs, splits, working directories, and scrollback come   │
│      back when you reopen CherryLily.                         │
│                                                               │
│  Scrollback to keep per pane:  [50,000 lines  ▼]              │
│      10,000 · 50,000 · 100,000 · 500,000 · Unlimited          │
│                                                               │
│  ▸ Advanced                                                   │
│      ☐ Save automatically every hour                          │
│          In case CherryLily exits unexpectedly.               │
│      Storage: ~/Library/Application Support/CherryLily/…      │
│      [Reveal in Finder]   [Clear saved sessions]              │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

### Setting → mechanism mapping

| User-facing setting | Internal effect |
|---|---|
| Restore terminal contents on launch (`restoreSessionsOnLaunch`) | Surfaces launch via bundled tmux; capture/replay enabled. Off → today's behavior (direct `$SHELL`). |
| Scrollback to keep per pane (`sessionScrollbackLimit: Int?` — nil = unlimited) | `set -g history-limit <N>` in managed `tmux.conf`. |
| Save automatically every hour (`hourlyAutosaveEnabled: Bool`) | Swift `DispatchSourceTimer` calls capture-pane-per-surface. |
| Storage (read-only display) | Default `~/Library/Application Support/CherryLily/sessions/`. Not user-relocatable in v1. |
| Reveal in Finder | `NSWorkspace.activateFileViewerSelecting`. |
| Clear saved sessions | Confirm sheet → `tmux kill-server`, delete `sessions/` directory, restart with fresh state. |

These persist via `GlobalSettings` (mirroring existing `confirmBeforeClosingTabs`).

### Things hidden from the user

Locked-down via the managed `tmux.conf` — never appear in settings:

- Status bar off
- Prefix key unbound
- All key bindings unbound (no `prefix + c`, `prefix + |`, etc.)
- Mouse mode off (mouse events go to Ghostty)
- `default-terminal "xterm-256color"`
- `default-shell` = user's `$SHELL` (or `/bin/zsh` fallback)
- `set-option -g destroy-unattached off` (sessions survive client detach)

## Architecture

### Process layout

```
CherryLily.app
  ├── Ghostty surfaces (existing) — render only
  └── tmux server (bundled binary)
        ├── socket: /private/tmp/tmux-<uid>/cherrylily
        ├── session "cl_<surface-uuid-1>"  ← surface 1
        ├── session "cl_<surface-uuid-2>"  ← surface 2
        └── …
```

- **One tmux server** for the whole CherryLily install. Survives app quit. Killed only on reboot, manual `tmux kill-server`, or "Clear saved sessions".
- **One session per surface** (a CherryLily tab can have multiple split surfaces; each is its own session).
- Custom socket `-L cherrylily` keeps our sessions isolated from any tmux the user runs in their normal terminal.

### Surface UUID lifecycle

The link between a Ghostty surface and its tmux session is a **stable UUID** persisted to disk:

- Today: `GhosttySurfaceView.id` is generated on each create. Volatile. Lost on quit.
- Change: introduce `SurfaceID = UUID` allocated when the surface is first created and **persisted with the layout snapshot**. On relaunch, the same SurfaceID is reused → same tmux session reattached.

### Bundled tmux

- Build pipeline (Makefile addition): download tmux source at a pinned version (e.g. 3.5a), compile with `--prefix=/Frameworks/tmux-cherrylily`, install into `cherrylily.app/Contents/MacOS/tmux-cherrylily` during `build-app` post-step. Or vendor a prebuilt arm64 + x86_64 fat binary in `Frameworks/`.
- Codesigned as part of the existing app codesign step (already entitlements-compatible per `cherrylily/cherrylily.entitlements`).
- BSD-licensed, no GPL contagion.
- Invoked by absolute path: `Bundle.main.bundleURL.appending(path: "Contents/MacOS/tmux-cherrylily")`.

### Managed tmux config

Written by CherryLily on first launch (and refreshed when settings change) to:

```
~/Library/Application Support/CherryLily/tmux.conf
```

Contents driven by Swift template substitution:

```tmux
# Auto-generated by CherryLily. Do not edit.
set -g history-limit {{scrollbackLimit}}
set -g status off
set -g mouse off
set -g default-terminal "xterm-256color"
set -g destroy-unattached off
set -g detach-on-destroy off
set -g default-shell "{{userShell}}"

# Lock down all keybindings — CherryLily handles all UX
unbind -a -T prefix
unbind -a -T root
unbind -a -T copy-mode
unbind -a -T copy-mode-vi

# Tab title / notifications passthrough
set -g allow-passthrough on
set -g set-titles on
set -g set-titles-string "#{pane_title}"
```

User cannot edit (overwritten on settings change). If they need customization, that's a v2.

## Lifecycle

### Surface creation

When a new surface is needed (new tab, new split, restored layout entry):

```
if restoreSessionsOnLaunch is OFF:
    launch shell directly, today's behavior
    return

surfaceID = persisted UUID for this slot, or new UUID
sessionName = "cl_" + surfaceID

# tmux new-session -A creates if missing, attaches if present
launch command:
  tmux-cherrylily \
    -L cherrylily \
    -f ~/Library/Application Support/CherryLily/tmux.conf \
    new-session -A -s <sessionName> -x 200 -y 50 \
    -- {{userShell}}

if scrollback file exists for surfaceID and session was just created:
    after 200ms (let shell start), inject saved scrollback bytes via:
      tmux load-buffer -t <sessionName> -b cl_restore <file>
      tmux paste-buffer -t <sessionName> -b cl_restore -d
```

Replay only happens for newly-created sessions (post-reboot or first launch). For existing sessions (app relaunch, no reboot), no replay needed — tmux's in-memory scrollback is already there.

### Capture (save)

Triggered on:
1. **App quit** (`applicationWillTerminate` / `scenePhase` → `.background` → `.inactive`)
2. **Worktree removal** (capture before kill, only if user wants to recover later — actually no, we delete on remove, see "Cleanup")
3. **Hourly safety net** (if enabled)
4. **Manual "Save Now" command** (optional, future)

Per-surface capture:

```
async for each active surface:
    out = tmux-cherrylily -L cherrylily capture-pane \
            -p -e -S -<scrollbackLimit> -t cl_<surfaceID>:0.0
    write out to ~/Library/Application Support/CherryLily/sessions/<surfaceID>.bin
    on error: log, mark surface as "save-failed", continue
```

Done in parallel across surfaces. Each call is a separate process, so no main-thread blocking. On quit, await all with a 2-second timeout (macOS gives apps ~5 seconds before SIGKILL).

### Restore

On app launch:

```
1. Read layout file (tabs, splits, surface UUIDs, working dirs)
2. tmux ls -L cherrylily → set of live session names
3. ls sessions/ → set of saved scrollback files
4. Reconcile (orphan cleanup, see below)
5. For each layout entry:
     create surface; launch tmux as above; if session was newly-created
     and scrollback file exists, schedule replay
6. Restore selected tab per worktree
7. Restore last focused worktree (existing functionality)
```

### Orphan cleanup (bidirectional)

After steps 1-3 above:

```
expectedIDs = {entry.surfaceID for entry in layout}
liveSessions = parse(tmux ls -F "#{session_name}")
savedFiles = ls(sessions/) → set of UUIDs

for sessionName in liveSessions:
    if sessionName not in {"cl_" + id for id in expectedIDs}:
        tmux kill-session -t sessionName

for fileID in savedFiles:
    if fileID not in expectedIDs:
        delete sessions/<fileID>.bin
```

### Worktree removal

When a worktree is removed (existing flow: archive, delete, `/wt-done`):

- For each surface in the worktree: `tmux kill-session -t cl_<surfaceID>`
- Delete corresponding scrollback files
- Existing `WorktreeTerminalManager.prune(keeping:)` extends with this cleanup

### App quit

```
1. Signal hourly timer to stop
2. Capture all active surfaces (parallel, 2-second timeout)
3. Write layout snapshot
4. Do NOT kill tmux server — let it persist for next launch
5. Exit normally
```

If capture times out (user shutting down system), CherryLily exits cleanly anyway and tmux server inherits the in-memory state until reboot.

## Layout snapshot format

`~/Library/Application Support/CherryLily/layout.json`:

```json
{
  "version": 1,
  "savedAt": "2026-05-15T14:30:00Z",
  "worktrees": [
    {
      "worktreeID": "/path/to/repo/wt-feature-x",
      "selectedTabID": "<uuid>",
      "tabs": [
        {
          "tabID": "<uuid>",
          "title": "main",
          "surfaces": {
            "<surfaceID>": {
              "cwd": "/path/to/repo/wt-feature-x/src",
              "splitTree": { /* SplitTree<UUID> serialization */ }
            }
          }
        }
      ]
    }
  ]
}
```

CWD is captured live via OSC 7 (already parsed by Ghostty into `bridge.state.workingDirectory`). On restore, the new tmux session is launched with `-c <cwd>` so the shell starts there.

## Storage layout

```
~/Library/Application Support/CherryLily/
  ├── tmux.conf                    ← managed config
  ├── layout.json                  ← layout snapshot
  └── sessions/
        ├── <surfaceID-1>.bin      ← scrollback bytes (raw, with ANSI)
        ├── <surfaceID-2>.bin
        └── …
```

Excluded from iCloud sync by default (Application Support isn't synced). For Time Machine: `setExcludedFromBackup=true` on `sessions/` to avoid backing up scrollback (which can be large and is regeneratable). The layout file is small, can be backed up.

## Edge cases

| Case | Handling |
|---|---|
| First launch (no saved state) | `layout.json` doesn't exist → today's empty start. |
| First launch after enabling persistence | Existing tabs become tracked surfaces with newly-allocated UUIDs. Layout written on quit. |
| Disabling persistence | Stop using tmux for new surfaces. Existing live tmux sessions are killed. Scrollback files deleted. Confirm sheet warns about loss. |
| Re-enabling persistence | Fresh start. No prior scrollback. |
| User deletes `layout.json` manually | All live tmux sessions become orphans → killed on next launch. Fresh start. |
| User deletes `sessions/` manually | No replay on next launch; live tmux sessions still attach with current in-memory scrollback. |
| `tmux-cherrylily` binary missing | Persistence silently disabled, log warning, settings page shows error: "Restore unavailable — please reinstall CherryLily." |
| tmux server crashed (rare) | Detected via socket file missing or `tmux ls` fails. Treat as "all sessions dead" — recreate from layout + replay scrollback. |
| Shell exits inside a session (`exit`) | tmux fires `session-closed` hook → CherryLily detects via PTY EOF in Ghostty bridge → close that surface (existing surface-close path). |
| Surface resize | Map to `tmux refresh-client -S` and `resize-window -t <session> -x <cols> -y <rows>`. tmux already adapts to attached client size, so this might be automatic. |
| Disk full on capture | `write` fails. Log; mark file as failed; show one-time alert "Could not save terminal contents — disk full." Persistence remains enabled but stale-file warnings appear. |
| `capture-pane` hangs (tmux unresponsive) | Per-surface 2-second timeout. Surface is recorded as "save-failed" and excluded from quit blocker. |
| Two CherryLily instances launched (`open -n`) | Both try to use socket `cherrylily`. tmux serializes via socket lock — second instance attaches to same server. No corruption. Layout file uses simple last-writer-wins; could corrupt if both write simultaneously. **Decision: prevent multi-instance via `NSApplicationDelegate.applicationShouldHandleReopen`** (already done for window management). |
| Color scheme change mid-session | tmux session colors don't change (ANSI palette is set per session). Only newly-created sessions pick up the new scheme. Acceptable for now; document. |
| Settings change scrollback limit | New limit applies only to new sessions. Show "Applies to new tabs" hint under the picker. |
| OSC 7 not emitted (user without shell integration) | CWD restore degrades to "open at worktree root". Shell integration auto-enable already prompts on first run. |
| Tab title (OSC 0/2) inside tmux | tmux passes through with `set -g set-titles on` and `set-titles-string "#{pane_title}"`. Verify in testing. |
| Desktop notifications (OSC 9 / OSC 777) | tmux passes through with `set -g allow-passthrough on`. Verify. |
| Search inside scrollback | Existing CherryLily search uses Ghostty's grid. Only currently-visible scrollback (Ghostty's window into tmux) is searchable. Historical content beyond Ghostty's local buffer requires `tmux capture-pane`-based search — not in v1. |
| User runs setup script in a tab | Setup script runs as part of `createTab` flow, before tmux wraps. Works inside tmux; no change. |
| User runs "Run Script" tab (existing feature) | Runs as a normal tab with the script as input. tmux session naming: same scheme. Persists across restart. |
| Blocking script (archive, delete) | One-shot; tab destroyed on completion. tmux session killed at the same time. |
| `closeAllSurfaces` (worktree archive cleanup) | Already kills surfaces via `WorktreeTerminalManager`. Extend to kill tmux sessions in same loop. |
| Reattach UX flicker | tmux re-paints screen on attach. Possible mitigation: render scrollback file content statically before live attach. v1 accepts the flicker. |
| 1000+ surfaces accumulating | Soft cap: log warning if `sessions/` has >200 files. UI: "Clear saved sessions" button does the work. |

## Out of scope (explicit)

- **Live process resumption.** A `npm run dev` running before reboot will not be running after reboot. Its output is in scrollback; the process is dead. Not solvable without OS-level support that doesn't exist.
- **Replay of last command.** No "re-run what I had typed" feature. v2 maybe.
- **Cross-machine session sync** (iCloud, Dropbox, Syncthing). v2 if ever.
- **Search across saved scrollback files** without attaching. v2.
- **User-customizable tmux config.** Locked down in v1.
- **Per-worktree persistence override.** Global setting only.
- **Multiple windows of CherryLily** with separate session sets. CherryLily is single-window today; if multi-window comes later, this design assumes shared state.
- **Importing existing tmux sessions** from the user's normal tmux. Different socket, different scope.

## Things you may have missed

These warrant explicit decisions before implementation:

### 1. tmux version pinning and updates

We need a pinned version (3.5a or whatever current). When tmux upstream releases bug fixes, we have to rebuild and ship. Build infrastructure: download → compile → universal binary → codesign → embed. Risk: a tmux bug we ship is harder to fix than user-installed tmux.

**Question:** acceptable to ship monthly with tmux updates, or do we want to use `system tmux` if available and bundled tmux as fallback?

### 2. App size impact

tmux universal binary is ~1.5 MB. Ghostty already adds ~30 MB. Acceptable but worth noting in the spec.

### 3. tmux server crash recovery

If the bundled tmux server crashes (rare but possible — bug in tmux, kernel signal), every CherryLily surface loses its shell. Two options:

- **(a) Detect via socket loss; show "Sessions disconnected" banner; offer to recreate.**
- **(b) Auto-restart the server on detection; recreate sessions from layout; replay scrollback files.**

(b) is more user-friendly but loses any output between last save and crash.

**Question:** which behavior?

### 4. Permissions

tmux creates a Unix socket in `/private/tmp/tmux-<uid>/cherrylily`. Standard tmux behavior. No special entitlements needed beyond what we already have. macOS "Full Disk Access" not required.

### 5. CWD capture reliability

OSC 7 (working directory escape sequence) requires shell integration. Defaults:

- macOS `/bin/zsh` doesn't emit OSC 7 by default
- Ghostty ships shell integration that auto-injects OSC 7 (via `GHOSTTY_RESOURCES_DIR/shell-integration/zsh/...`). It auto-loads if shell starts under Ghostty.
- With tmux underneath, the shell starts under **tmux**, not Ghostty directly. Shell integration may not auto-inject.

**Question:** do we explicitly source Ghostty's shell integration in the tmux-launched shell, or rely on user setup? Probably need to inject a `--rcfile` argument or set `ZDOTDIR` to a CherryLily-managed directory.

### 6. Setup script + tmux interaction

Today's setup script runs as the initial input to a fresh `zsh`. With tmux underneath, the setup script becomes input to the tmux-launched shell. Should still work but needs verification — especially that the script's environment vars (`CHERRYLILY_WORKTREE_PATH`, `CHERRYLILY_ROOT_PATH`) are still set correctly.

### 7. Notification flow with tmux passthrough

CherryLily uses Ghostty's bell + OSC 9 for tab notification badges. tmux's `allow-passthrough on` should forward OSC 9. **Needs explicit testing**, since tmux historically had spotty passthrough support and some sequences get rewritten.

### 8. Migration for existing users

Existing CherryLily installs have no surface UUIDs persisted. On upgrade:

- v1: First launch after upgrade with persistence ON → today's tabs get fresh UUIDs, written to layout, normal flow from there. **No history backfill.**
- Alternative: persistence default OFF for existing users (only ON for new installs). Detect via `lastVersion < persistenceFeatureVersion`.

**Question:** default ON or OFF for existing users? I'd argue ON with a one-time "New: session restore is enabled — disable in Settings if you prefer fresh shells" notification.

### 9. Performance regression measurement

tmux adds a process and ~10-20% throughput overhead for high-output workloads (`cat huge.log`, `tail -f` on a busy file). For interactive work, imperceptible.

**Question:** any benchmark target before/after to validate? Probably manual: build a release, measure `time cat 1GB.log` with persistence on vs off.

### 10. `closeFocusedTab` vs `closeTab(worktreeID, tabID)` vs tmux session lifecycle

The recently-merged tab-close confirmation feature has explicit close paths. Each must also issue `tmux kill-session` for the closed surface. Worth a unit test that verifies sessions go away when tabs close.

### 11. Scrollback content vs grid state

`tmux capture-pane -p -e -S -<N>` dumps **scrollback as ANSI text bytes**. On restore via `paste-buffer`, those bytes are written to the new shell's stdin... wait, `paste-buffer` writes to **stdin** of the running process, not the screen. That means the shell receives the scrollback as input — disastrous (it'd try to execute it).

**Correction needed:** restore mechanism needs to write to **the terminal's output channel**, not the shell's stdin. Two options:

- **(a) Restore by running `cat <file>` as the first thing in the new session.** Simple. The shell prints the file contents (with `cat`'s implicit reset of cursor pos) before showing its prompt. Works because `cat -e` interprets and emits the saved bytes through the terminal directly.
- **(b) Use `tmux send-keys` to type literal text into the pane.** Wrong layer — same stdin issue.
- **(c) Patch tmux** to add a "restore scrollback from file" command. Upstream contribution. Most correct but requires patching.

**Decision needed:** probably (a) for v1. Caveat: if the saved scrollback contains a control sequence that triggers an action (like running a command via `\e]52;...\a` clipboard paste), the user's session would execute it on restore. **This is a security consideration.** Need to either strip dangerous sequences from saved bytes, or accept the risk since it's the user's own scrollback.

**Recommendation for v1:** strip the most dangerous OSC sequences (52 = clipboard manipulate, 8 = hyperlink with arbitrary URI, 133 = semantic prompt that can confuse shell integration) before writing the file. Keep colors/cursor positioning.

### 12. Empty session at startup

When `tmux new-session -A -s <name>` creates a session for the first time, there's a brief moment where the shell is starting and Ghostty is attaching. If we replay scrollback before the shell finishes loading, the replay can be overwritten by the shell's clear-screen-on-prompt behavior. Need to detect "shell is ready" before replay — typically the OSC 133 prompt sequence, or a small fixed delay (200ms is in the spec above).

**Open:** robust "shell ready" detection. v1 may use a simple delay; v2 should hook OSC 133.

### 13. macOS App Nap and Background Activity

If macOS "naps" CherryLily (app in background, no windows visible), the bundled tmux server keeps running normally — it's a separate process. Good. But the hourly-save timer may be deferred. Use `DispatchSourceTimer` with `.strict` flag, or a `UnifiedJobScheduler` (overkill). For v1: accept timer drift in background.

### 14. Test strategy

- Unit: capture/replay file format roundtrip. Layout serialization. Orphan cleanup. UUID stability across restart simulated by direct file writes.
- Integration: launch tmux subprocess in a test, create a session, write scrollback, capture, kill, recreate, restore, verify content.
- E2E manual: set persistence on, type stuff, quit, relaunch (no reboot), verify shells alive + scrollback visible. Then reboot, verify scrollback visible above fresh prompts.

## Implementation phases

Suggested phasing for ship-and-iterate:

**Phase 1 — Foundation (no UI yet, hidden behind a debug flag)**
- Bundled tmux build pipeline + codesign integration
- Surface UUID stable across restarts
- Layout JSON serialization + deserialization
- Orphan cleanup

**Phase 2 — Surface launch wrapping**
- `WorktreeTerminalState` learns about tmux mode
- Surfaces launch via tmux when flag is on
- Existing tests pass with both modes

**Phase 3 — Capture + restore**
- Capture-pane on quit
- Replay on session creation
- OSC sequence sanitization

**Phase 4 — Settings UI**
- New Sessions section
- Settings → tmux config bindings
- "Clear saved sessions" + "Reveal in Finder"

**Phase 5 — Edge case handling**
- Disk-full alerts
- tmux crash detection
- Multi-instance prevention
- Hourly timer

**Phase 6 — Polish**
- Reattach UX (try to hide flicker)
- Migration messaging for existing users
- Documentation
