import Foundation

/// Composes the tmux invocation string passed to Ghostty's `surface_config.command`.
///
/// The resulting string is interpreted by `/bin/sh` (Ghostty spawns commands through the
/// user's shell). All file paths and the session name are POSIX double-quoted so paths
/// containing spaces or shell metacharacters work correctly.
///
/// `exec` replaces the spawned shell process with tmux, so closing tmux closes the surface.
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
      "exec \(quotedBinary) -L cherrylily -f \(quotedConfig) "
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
