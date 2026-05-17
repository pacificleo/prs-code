import Foundation

private nonisolated let layoutLogger = SupaLogger("SessionLayout")

/// Atomically reads and writes the session layout JSON file.
/// Corruption-tolerant: a malformed file is treated as "no layout" rather than throwing,
/// so a bad snapshot doesn't permanently break startup.
nonisolated struct SessionLayoutStore: Sendable {
  let paths: SessionPaths

  /// Loads the layout file. Returns nil if:
  /// - the file doesn't exist (first launch, or file was deleted)
  /// - the file's JSON is malformed (truncated/corrupt — logged, treated as fresh start)
  ///
  /// When the file is malformed, it is renamed to `layout.json.corrupt-<timestamp>`
  /// so the next save can write a fresh `layout.json` and we keep the bad bytes for
  /// post-mortem inspection. Without the rename, the next save would silently
  /// overwrite the only evidence we had of what went wrong.
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
      let timestamp = Int(Date().timeIntervalSince1970)
      let backup = url.appendingPathExtension("corrupt-\(timestamp)")
      do {
        try FileManager.default.moveItem(at: url, to: backup)
        layoutLogger.warning(
          "layout.json failed to decode, moved aside to \(backup.lastPathComponent): \(error)"
        )
      } catch {
        layoutLogger.warning(
          "layout.json failed to decode and could not be moved aside (\(error)); treating as empty"
        )
      }
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
