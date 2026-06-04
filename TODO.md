# TODO

## Tests still pollute the developer's real `~/.zsh_history`

**Status:** open · **Found:** 2026-06-03 · **Severity:** annoyance (not destructive)

`make test` appends fixture commands to the real `~/.zsh_history`
(`export CHERRYLILY_ROOT_PATH='/tmp/repo'…`, `(\n…\n)`, `exit $?`,
`echo hello-capture`).

**Root cause:** several unit tests spawn *real* shells.
- `Process`-spawned tmux path (e.g. `TmuxClientCaptureTests`) inherits `$HOME`,
  so a `$HOME` redirect fixes it.
- The **Ghostty login-shell path** — `runScript` / `runBlockingScript` in
  `WorktreeTerminalManagerTests`, `AppFeatureRunScriptTests`,
  `RepositoriesFeatureTests`, `AppFeatureArchivedSelectionTests`,
  `AppFeatureDefaultEditorTests`, `RepositorySettingsKeyTests`,
  `ToolbarNotificationGroupingTests` — still writes to the real history.

**What we know:** `HOME=temp` empirically *does* stop zsh pollution
(`/etc/zshrc` uses `HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history`), but redirecting
`$HOME` from `CherryLilyApp.init()` / the app delegate did **not** reach the
Ghostty-spawned shells. The partial `TestHomeIsolation` helper
(`cherrylilyTests/TestHomeIsolation.swift`, commit `e8f6b72`) only covers the
`Process` path.

**Proper fix (preferred):** stop these *unit* tests from spawning real login
shells at all — inject/mock the terminal surface (`WorktreeTerminalManager` /
`GhosttyRuntime`) so `runScript` / `runBlockingScript` assert on the command
string + state transitions instead of executing. Then drop the env-trick
helper.

**Interim mitigation:** back up `~/.zsh_history`, then remove fixture
logical-commands honoring backslash-continuation. Signatures:
`CHERRYLILY_(ROOT|WORKTREE)_PATH=`, `hello-capture`, `exit $?`, and `(...)`
subshells whose body ∈ {`echo ok`, `exit 1`, `exit 0`, `sleep 10`,
`echo hello-capture`}.
