import Foundation

/// Composes the tmux invocation string passed to Ghostty's `surface_config.command`.
///
/// Ghostty wraps the string as `/bin/bash --noprofile --norc -c "exec -l <our_string>"`
/// (see ThirdParty/ghostty/src/termio/exec.zig). Because Ghostty already prepends `exec`
/// for us, the string we produce must NOT start with `exec` — doing so makes bash run
/// `exec exec ...` which tries to exec a program literally named `exec`.
///
/// All file paths and the session name are POSIX double-quoted so paths containing spaces
/// or shell metacharacters work correctly.
nonisolated enum SurfaceLaunchCommand {
  static func build(
    tmuxBinaryPath: String,
    configPath: String,
    surface: SurfaceID,
    cwd: String
  ) -> String {
    let quotedBinary = posixDoubleQuote(tmuxBinaryPath)
    let quotedConfig = posixDoubleQuote(configPath)
    let quotedSession = posixDoubleQuote(surface.tmuxSessionName)
    let quotedCwd = posixDoubleQuote(cwd)
    return
      "\(quotedBinary) -L cherrylily -f \(quotedConfig) "
      + "new-session -A -s \(quotedSession) -c \(quotedCwd)"
  }

  /// Bundles the extra inputs needed by `buildWithReplay` so the call site stays under
  /// the project-wide function-parameter-count lint cap.
  struct ReplayOptions {
    let scrollbackPath: String
    let userShell: String
    /// Optional ZDOTDIR override so Ghostty's shell integration loads when zsh
    /// starts via the replay path (it normally would be loaded by tmux's
    /// `default-command`, but the replay shell command bypasses that).
    /// Nil means use the user's normal zsh startup.
    let ghosttyZshIntegrationDir: String?

    init(scrollbackPath: String, userShell: String, ghosttyZshIntegrationDir: String? = nil) {
      self.scrollbackPath = scrollbackPath
      self.userShell = userShell
      self.ghosttyZshIntegrationDir = ghosttyZshIntegrationDir
    }
  }

  /// Same as `build` but instructs tmux to run `cat <scrollbackPath>; exec <userShell>`
  /// as the session's command. Used for post-reboot restore — `cat` dumps saved bytes
  /// to the terminal (including ANSI), then `exec` replaces cat with the user's real shell.
  ///
  /// Two layers of POSIX double-quoting:
  /// 1. Each path inside the `cat .../exec ...` line is quoted (so it survives sh's parsing inside tmux)
  /// 2. The whole `cat ...; exec ...` line is quoted (so it survives bash's parsing as tmux's last argv)
  static func buildWithReplay(
    tmuxBinaryPath: String,
    configPath: String,
    surface: SurfaceID,
    cwd: String,
    replay: ReplayOptions
  ) -> String {
    let quotedBinary = posixDoubleQuote(tmuxBinaryPath)
    let quotedConfig = posixDoubleQuote(configPath)
    let quotedSession = posixDoubleQuote(surface.tmuxSessionName)
    let quotedCwd = posixDoubleQuote(cwd)
    // For zsh users with Ghostty integration available, prepend `env ZDOTDIR=...`
    // so the spawned shell loads the integration (and emits OSC 133, which drives
    // the worktree-busy spinner).
    let execShell: String
    if let zdotdir = replay.ghosttyZshIntegrationDir,
       (replay.userShell as NSString).lastPathComponent == "zsh"
    {
      execShell = "env ZDOTDIR=\(posixDoubleQuote(zdotdir)) \(posixDoubleQuote(replay.userShell))"
    } else {
      execShell = posixDoubleQuote(replay.userShell)
    }
    // Inner sh command — paths quoted so spaces work inside tmux's sh
    let innerShellCommand =
      "cat \(posixDoubleQuote(replay.scrollbackPath)); exec \(execShell)"
    // Outer quote — survives bash's parsing as ONE token
    let quotedInner = posixDoubleQuote(innerShellCommand)
    return
      "\(quotedBinary) -L cherrylily -f \(quotedConfig) "
      + "new-session -A -s \(quotedSession) -c \(quotedCwd) \(quotedInner)"
  }

  /// Wraps a string in POSIX double quotes, escaping characters that retain special
  /// meaning inside double quotes: `\`, `"`, `$`, and `` ` ``.
  ///
  /// Order matters — backslash MUST be escaped first, otherwise subsequent escape
  /// additions get themselves doubled.
  private static func posixDoubleQuote(_ input: String) -> String {
    var escaped = input
    escaped = escaped.replacing("\\", with: "\\\\")
    escaped = escaped.replacing("\"", with: "\\\"")
    escaped = escaped.replacing("$", with: "\\$")
    escaped = escaped.replacing("`", with: "\\`")
    return "\"\(escaped)\""
  }
}
