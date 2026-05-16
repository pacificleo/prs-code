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
