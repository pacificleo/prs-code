import Foundation

private nonisolated let tmuxConfigLogger = SupaLogger("TmuxConfig")

/// Writes the managed tmux.conf to disk.
/// Skips the write when on-disk content already matches what `TmuxConfig.generate`
/// would produce — keeps file mtime stable across no-op invocations.
nonisolated struct TmuxConfigWriter: Sendable {
  let paths: SessionPaths

  func writeIfChanged(scrollbackLimit: Int, userShell: String) throws {
    let desired = TmuxConfig.generate(scrollbackLimit: scrollbackLimit, userShell: userShell)

    if let existing = try? String(contentsOf: paths.tmuxConfigFile, encoding: .utf8),
       existing == desired
    {
      return
    }

    try paths.ensureDirectoriesExist()
    try desired.data(using: .utf8)?.write(to: paths.tmuxConfigFile, options: [.atomic])
    tmuxConfigLogger.debug("wrote tmux.conf with history-limit=\(scrollbackLimit)")
  }
}
