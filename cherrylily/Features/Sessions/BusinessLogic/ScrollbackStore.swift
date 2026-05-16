import Foundation

/// Reads and writes per-surface scrollback files. Sanitizes captured bytes to strip
/// dangerous OSC sequences before storage.
nonisolated struct ScrollbackStore: Sendable {
  let paths: SessionPaths

  /// Writes scrollback bytes for the given surface, after sanitizing.
  func write(bytes: Data, for id: SurfaceID) throws {
    try paths.ensureDirectoriesExist()
    let cleaned = Self.sanitize(bytes)
    try cleaned.write(to: paths.scrollbackFile(for: id), options: [.atomic])
  }

  /// Reads previously-stored scrollback. Returns nil if the file doesn't exist.
  /// Real I/O errors propagate (callers can surface to user).
  func read(for id: SurfaceID) throws -> Data? {
    let url = paths.scrollbackFile(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }

  /// Removes the stored scrollback for the surface. No-op if missing.
  func delete(for id: SurfaceID) throws {
    let url = paths.scrollbackFile(for: id)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  /// Returns SurfaceIDs corresponding to scrollback files in the sessions directory.
  /// Ignores any file whose name doesn't parse as `<UUID>.bin`.
  func storedSurfaceIDs() throws -> [SurfaceID] {
    let dir = paths.sessionsDirectory
    guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
    let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    return entries.compactMap { url -> SurfaceID? in
      let name = url.lastPathComponent
      guard name.hasSuffix(".bin") else { return nil }
      let stem = String(name.dropLast(".bin".count))
      guard let uuid = UUID(uuidString: stem) else { return nil }
      return SurfaceID(rawValue: uuid)
    }
  }

  /// Strips dangerous OSC sequences (52 = clipboard, 8 = hyperlink, 133 = semantic prompt)
  /// from the byte stream while preserving CSI/SGR (color/cursor) escapes.
  ///
  /// OSC sequences are: ESC ] code ; payload ST  where ST = BEL (0x07) or ESC \ (0x1B 0x5C).
  static func sanitize(_ input: Data) -> Data {
    let bytes = [UInt8](input)
    var out = [UInt8]()
    out.reserveCapacity(bytes.count)
    var cursor = 0
    while cursor < bytes.count {
      // Detect ESC ] (start of OSC)
      if cursor + 1 < bytes.count, bytes[cursor] == 0x1B, bytes[cursor + 1] == 0x5D {
        // Parse the OSC code (digits up to first ';' or terminator)
        var codeEnd = cursor + 2
        var codeBytes = [UInt8]()
        while codeEnd < bytes.count, bytes[codeEnd] >= 0x30, bytes[codeEnd] <= 0x39 {
          codeBytes.append(bytes[codeEnd])
          codeEnd += 1
        }
        let codeStr = String(bytes: codeBytes, encoding: .utf8) ?? ""
        let code = Int(codeStr) ?? -1
        // Find terminator: BEL (0x07) or ESC \ (0x1B 0x5C)
        var terminatorEnd = codeEnd
        while terminatorEnd < bytes.count {
          if bytes[terminatorEnd] == 0x07 {
            terminatorEnd += 1
            break
          }
          if bytes[terminatorEnd] == 0x1B, terminatorEnd + 1 < bytes.count, bytes[terminatorEnd + 1] == 0x5C {
            terminatorEnd += 2
            break
          }
          terminatorEnd += 1
        }
        // If this is a dangerous OSC code, drop the whole sequence; otherwise keep.
        if [52, 8, 133].contains(code) {
          cursor = terminatorEnd
          continue
        }
        // Keep the bytes as-is
        out.append(contentsOf: bytes[cursor..<terminatorEnd])
        cursor = terminatorEnd
        continue
      }
      out.append(bytes[cursor])
      cursor += 1
    }
    return Data(out)
  }
}
