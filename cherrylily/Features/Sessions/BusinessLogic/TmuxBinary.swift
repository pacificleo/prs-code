import Foundation

/// Resolves the location of the tmux executable bundled inside CherryLily.app.
enum TmuxBinary {
  /// Path to the bundled tmux binary inside the running app's MacOS directory.
  /// In tests this resolves to a path inside the test runner; the file may not exist there.
  static var bundledURL: URL {
    let exe = Bundle.main.executableURL
      ?? Bundle.main.bundleURL.appending(path: "Contents/MacOS/CherryLily")
    return exe.deletingLastPathComponent().appending(path: "tmux-cherrylily")
  }

  /// Returns true if the bundled binary exists and is executable. Used as a precondition
  /// before launching tmux-backed surfaces.
  static var isAvailable: Bool {
    let url = bundledURL
    return FileManager.default.isExecutableFile(atPath: url.path)
  }
}
