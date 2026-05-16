import Foundation

/// Filesystem paths used by the session-persistence subsystem.
/// Construct with the user's Application Support root in production; tests pass `/tmp` paths.
struct SessionPaths: Sendable {
  let root: URL

  /// Default production root: `~/Library/Application Support/CherryLily/`.
  static var defaultRoot: URL {
    let appSupport = try? FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let resolved = (appSupport ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support"))
      .appending(path: "CherryLily")
    return resolved
  }

  init(root: URL) {
    self.root = root
  }

  init() {
    self.init(root: Self.defaultRoot)
  }

  var layoutFile: URL { root.appending(path: "layout.json") }
  var tmuxConfigFile: URL { root.appending(path: "tmux.conf") }
  var sessionsDirectory: URL { root.appending(path: "sessions") }
  var tmuxSocketName: String { "cherrylily" }

  func scrollbackFile(for id: SurfaceID) -> URL {
    sessionsDirectory.appending(path: "\(id.rawValue.uuidString).bin")
  }

  /// Ensures all required directories exist. Idempotent.
  func ensureDirectoriesExist() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
  }
}
