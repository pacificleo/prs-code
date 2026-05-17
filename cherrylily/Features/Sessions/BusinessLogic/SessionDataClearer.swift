import Foundation

private nonisolated let clearerLogger = SupaLogger("Sessions")

/// Deletes saved session state — `layout.json` and all scrollback files — without
/// touching live tmux sessions or the managed `tmux.conf`.
///
/// Live state is intentionally preserved: CherryLily is the user's terminal, so
/// killing tmux sessions would destroy their open work. After clear, the next
/// `applicationWillTerminate` will write a fresh layout from current state.
nonisolated struct SessionDataClearer: Sendable {
  let paths: SessionPaths

  func clearSavedData() {
    let fileManager = FileManager.default

    if fileManager.fileExists(atPath: paths.layoutFile.path) {
      do {
        try fileManager.removeItem(at: paths.layoutFile)
      } catch {
        clearerLogger.warning("failed to delete layout.json: \(error)")
      }
    }

    do {
      let contents = try fileManager.contentsOfDirectory(at: paths.sessionsDirectory, includingPropertiesForKeys: nil)
      for url in contents where url.pathExtension == "bin" {
        do {
          try fileManager.removeItem(at: url)
        } catch {
          clearerLogger.warning("failed to delete \(url.lastPathComponent): \(error)")
        }
      }
    } catch {
      // sessions directory may not exist — that's fine, nothing to clear
      if (error as NSError).code != NSFileReadNoSuchFileError {
        clearerLogger.warning("failed to enumerate sessions directory: \(error)")
      }
    }
  }
}
