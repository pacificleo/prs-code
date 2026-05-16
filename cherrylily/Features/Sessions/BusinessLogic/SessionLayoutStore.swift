import Foundation

/// Atomically reads and writes the session layout JSON file.
/// Corruption-tolerant: a malformed file is treated as "no layout" rather than throwing,
/// so a bad snapshot doesn't permanently break startup.
nonisolated struct SessionLayoutStore {
  let paths: SessionPaths

  init(paths: SessionPaths) {
    self.paths = paths
  }

  /// Loads the layout file. Returns nil if the file is missing OR corrupted.
  func load() throws -> SessionLayout? {
    let url = paths.layoutFile
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(SessionLayout.self, from: data)
    } catch {
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
