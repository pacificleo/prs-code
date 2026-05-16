import Foundation

/// Typed wrapper around the subset of tmux subprocess invocations the persistence
/// system needs in Phase 1: list, create, kill sessions, kill server.
///
/// Phase 3 will add capture-pane and attach machinery; this type stays focused on
/// session-management primitives.
nonisolated struct TmuxClient: Sendable {
  let executableURL: URL
  /// Socket name passed via `tmux -L`. Isolates our sessions from the user's normal tmux.
  let socketName: String

  init(executableURL: URL, socketName: String) {
    self.executableURL = executableURL
    self.socketName = socketName
  }

  // MARK: - Cleanup-tolerance markers

  /// Stderr substrings that mean "no live server / socket / session" — i.e. the
  /// thing we wanted to remove already isn't there. Cleanup-style commands treat
  /// these as success rather than throwing.
  private static let cleanupToleratedSubstrings: [String] = [
    "no server running",
    "error connecting",
    "no such file or directory",
    "can't find session",
  ]

  private static func isCleanupTolerated(_ stderr: String) -> Bool {
    let lower = stderr.lowercased()
    return cleanupToleratedSubstrings.contains { lower.contains($0) }
  }

  /// Lists session names on our socket. Returns empty when no server is running
  /// (tmux exits with non-zero in that case — we treat it as "no sessions").
  func listSessionNames() async throws -> [String] {
    let result = try await run(["ls", "-F", "#{session_name}"])
    if !result.success {
      // tmux exits 1 with "no server running" / "error connecting" on stderr — treat as empty
      if Self.isCleanupTolerated(result.stderr) {
        return []
      }
      throw TmuxClientError.commandFailed(stderr: result.stderr, exitCode: result.exitCode)
    }
    return result.stdout
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .filter { !$0.isEmpty }
  }

  /// Creates a detached session. Optional working directory passed via `-c`.
  func createSession(named name: String, workingDirectory: URL?) async throws {
    var args = ["new-session", "-d", "-s", name]
    if let workingDirectory {
      args.append(contentsOf: ["-c", workingDirectory.path])
    }
    let result = try await run(args)
    guard result.success else {
      throw TmuxClientError.commandFailed(stderr: result.stderr, exitCode: result.exitCode)
    }
  }

  /// Kills the named session. Tolerates "session not found" — used in cleanup.
  func killSession(named name: String) async throws {
    let result = try await run(["kill-session", "-t", name])
    if !result.success {
      // tmux reports several variants when the target doesn't exist:
      //   - "can't find session ..."         (server up, name unknown)
      //   - "no server running on ..."       (server explicitly absent)
      //   - "error connecting to ..."        (no socket file at all)
      //   - "no such file or directory"      (socket dir missing)
      if Self.isCleanupTolerated(result.stderr) {
        return
      }
      throw TmuxClientError.commandFailed(stderr: result.stderr, exitCode: result.exitCode)
    }
  }

  /// Kills the entire server, dropping all sessions. Tolerates "no server running".
  func killServer() throws {
    // Synchronous because used in defer blocks; uses runSync helper.
    let result = try runSync(["kill-server"])
    if !result.success {
      if Self.isCleanupTolerated(result.stderr) {
        return
      }
      throw TmuxClientError.commandFailed(stderr: result.stderr, exitCode: result.exitCode)
    }
  }

  // MARK: - Process plumbing

  private struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var success: Bool { exitCode == 0 }
  }

  private func run(_ args: [String]) async throws -> ProcessResult {
    try await withCheckedThrowingContinuation { continuation in
      Task.detached {
        do {
          continuation.resume(returning: try runSync(args))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  // FIXME(phase-3): The current `waitUntilExit()` then `readDataToEndOfFile()` order
  // deadlocks when stdout/stderr exceeds the pipe buffer (~64KB on macOS). Phase 1
  // commands (tmux ls / kill-session / kill-server) produce tiny outputs so this is
  // safe today. Phase 3's capture-pane will produce large outputs and must restructure
  // to read pipes concurrently with waiting (e.g. via readabilityHandler).
  private func runSync(_ args: [String]) throws -> ProcessResult {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["-L", socketName] + args
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    process.waitUntilExit()
    let stdout = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
  }
}

enum TmuxClientError: Error, Equatable {
  case commandFailed(stderr: String, exitCode: Int32)
}
