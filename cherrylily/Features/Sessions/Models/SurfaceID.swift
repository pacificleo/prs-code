import Foundation

/// A stable identifier for a Ghostty surface, persisted across app restarts so
/// the same surface always attaches to the same tmux session.
struct SurfaceID: Codable, Hashable, Sendable {
  let rawValue: UUID

  init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  /// Formatted name used as the tmux session identifier.
  /// Lowercased so it matches `tmux ls` output without case games.
  var tmuxSessionName: String {
    "cl_\(rawValue.uuidString.lowercased())"
  }

  /// Parses a tmux session name created by `tmuxSessionName`.
  /// Returns nil if the name doesn't match the expected `cl_<uuid>` form.
  init?(tmuxSessionName name: String) {
    let prefix = "cl_"
    guard name.hasPrefix(prefix) else { return nil }
    let uuidPart = String(name.dropFirst(prefix.count))
    guard let uuid = UUID(uuidString: uuidPart) else { return nil }
    self.rawValue = uuid
  }
}
