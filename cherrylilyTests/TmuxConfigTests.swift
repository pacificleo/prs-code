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

  @Test func enablesMouseForScrollback() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(conf.contains("set -g mouse on"))
  }

  @Test func bindsMouseDragSelectionToPbcopy() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    // Drag-select-end must route through pbcopy so the macOS clipboard fills
    // reliably (without depending on OSC 52 round-tripping through the host
    // terminal). Both copy-mode and copy-mode-vi tables get the override
    // because users can switch mode-keys.
    #expect(conf.contains("MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel \"pbcopy\""))
    #expect(conf.contains("bind-key -T copy-mode    MouseDragEnd1Pane"))
    #expect(conf.contains("bind-key -T copy-mode-vi MouseDragEnd1Pane"))
  }

  @Test func bindsCopyModeViWheelAndExitKeys() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    // copy-mode-vi must have wheel + cancel bindings because tmux's defaults
    // don't always populate it, and an earlier CherryLily config that did
    // `unbind -a -T copy-mode-vi` leaves servers locked when source-file runs
    // without re-adding the bindings explicitly.
    #expect(conf.contains("bind-key -T copy-mode-vi WheelUpPane"))
    #expect(conf.contains("bind-key -T copy-mode-vi WheelDownPane"))
    #expect(conf.contains("bind-key -T copy-mode-vi Escape"))
    #expect(conf.contains("bind-key -T copy-mode-vi q"))
  }

  @Test func bindsMouseDragStartToEnterCopyMode() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    // Without an explicit MouseDrag1Pane in root, a tmux server started under
    // an earlier config that unbound -a -T root never gets the default
    // copy-mode-on-drag behavior back via source-file. Bind explicitly.
    #expect(conf.contains("bind-key -T root MouseDrag1Pane"))
    #expect(conf.contains("copy-mode -M"))
  }
  @Test func reliesOnDefaultWheelBindings() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    // We rely on tmux's built-in WheelUpPane/WheelDownPane bindings in the root
    // table (and built-in Escape/q in copy-mode) for wheel-scroll UX. We must NOT
    // unbind those tables, otherwise the user gets stuck in copy-mode after a
    // wheel-up. This test guards against accidentally re-introducing the unbinds.
    #expect(!conf.contains("unbind -a -q -T root"))
    #expect(!conf.contains("unbind -a -q -T copy-mode"))
    #expect(!conf.contains("unbind -a -q -T copy-mode-vi"))
  }

  @Test func unbindsOnlyPrefixTable() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(conf.contains("unbind -a -q -T prefix"))
  }

  @Test func setsDefaultShell() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/opt/homebrew/bin/fish")
    #expect(conf.contains("set -g default-shell \"/opt/homebrew/bin/fish\""))
  }

  @Test func enablesPassthroughForOSC() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(conf.contains("set -g allow-passthrough on"))
  }

  @Test func forwardsBellToTerminal() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    // Bell must reach Ghostty so the worktree notification badge fires —
    // tmux normally consumes BEL and surfaces it in the status line, which
    // we have off.
    #expect(conf.contains("set -g bell-action any"))
    #expect(conf.contains("set -g visual-bell off"))
    #expect(conf.contains("set -g monitor-bell on"))
  }

  @Test func setsXtermTerminal() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(conf.contains("set -g default-terminal \"xterm-256color\""))
  }

  @Test func keepsSessionsAliveOnDetach() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(conf.contains("set -g destroy-unattached off"))
  }

  @Test func closesSurfaceWhenSessionDestroyed() {
    // Each Ghostty surface attaches to exactly one `cl_<uuid>` session via
    // `new-session -A`. If that session is ever destroyed out from under a
    // live surface (external kill, crash, errant reconcile), tmux's
    // `detach-on-destroy` decides what the orphaned client does:
    //   off → client SWITCHES to another surviving session, so multiple tabs
    //         silently mirror one session (the multi-tab "same content" bug)
    //   on  → client detaches, the `new-session -A` process exits, and the
    //         surface terminates cleanly instead of hijacking another tab.
    // CherryLily is strictly 1-surface : 1-session, so `on` is correct.
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(conf.contains("set -g detach-on-destroy on"))
  }

  @Test func headerCommentMarksAutoGenerated() {
    let conf = TmuxConfig.generate(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(conf.hasPrefix("# Auto-generated by CherryLily. Do not edit."))
  }
}
