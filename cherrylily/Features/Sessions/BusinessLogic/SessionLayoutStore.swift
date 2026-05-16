import Foundation

private nonisolated let layoutLogger = SupaLogger("SessionLayout")

/// Atomically reads and writes the session layout JSON file.
/// Corruption-tolerant: a malformed file is treated as "no layout" rather than throwing,
/// so a bad snapshot doesn't permanently break startup.
nonisolated struct SessionLayoutStore: Sendable {
  let paths: SessionPaths

  init(paths: SessionPaths) {
    self.paths = paths
  }

  /// Loads the layout file. Returns nil if:
  /// - the file doesn't exist (first launch, or file was deleted)
  /// - the file's JSON is malformed (truncated/corrupt — logged, treated as fresh start)
  ///
  /// Real I/O errors (permissions, disk failure) propagate so the caller can surface them.
  func load() throws -> SessionLayout? {
    let url = paths.layoutFile
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(SessionLayout.self, from: data)
    } catch {
      layoutLogger.warning("layout.json failed to decode, treating as empty: \(error)")
      return nil
    }
  }

  /// Atomically writes the layout file. Uses Foundation's `.atomic` write option,
  /// which writes to a temp file in the same directory and renames.
  func save(_ layout: SessionLayout) throws {
    try paths.ensureDirectoriesExist()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(layout)
    try data.write(to: paths.layoutFile, options: [.atomic])
  }
}
