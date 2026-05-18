import Foundation

/// Filesystem paths used by the session-persistence subsystem.
/// Construct with the user's Application Support root in production; tests pass `/tmp` paths.
nonisolated struct SessionPaths: Sendable {
  let root: URL
  /// tmux socket name (passed to `tmux -L`). Defaults to `"cherrylily"` in
  /// production so the user's running app shares one socket. Tests override
  /// with a unique `cl-test-…` name so they never touch the production socket
  /// and can safely `killServer()` in teardown.
  let tmuxSocketName: String

  /// Default production root: `~/Library/Application Support/CherryLily/`.
  static var defaultRoot: URL {
    let appSupport = try? FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let fallback = URL(fileURLWithPath: NSHomeDirectory())
      .appending(path: "Library/Application Support")
    let resolved = (appSupport ?? fallback)
      .appending(path: "CherryLily")
    return resolved
  }

  init(root: URL, tmuxSocketName: String = "cherrylily") {
    self.root = root
    self.tmuxSocketName = tmuxSocketName
  }

  init() {
    self.init(root: Self.defaultRoot)
  }

  var layoutFile: URL { root.appending(path: "layout.json") }
  var tmuxConfigFile: URL { root.appending(path: "tmux.conf") }
  var sessionsDirectory: URL { root.appending(path: "sessions") }

  func scrollbackFile(for id: SurfaceID) -> URL {
    sessionsDirectory.appending(path: "\(id.rawValue.uuidString.lowercased()).bin")
  }

  /// Ensures all required directories exist. Idempotent.
  func ensureDirectoriesExist() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
  }
}
