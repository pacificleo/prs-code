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

  /// Captures the scrollback of a session's first pane. Output is raw bytes (ANSI/escape
  /// sequences included). The caller is expected to run `ScrollbackStore.sanitize(_:)`
  /// before persisting.
  ///
  /// Streams stdout via `readabilityHandler` so multi-megabyte captures don't deadlock
  /// (see NOTE on `runSync`).
  func capturePane(sessionName: String, scrollbackLimit: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      Task.detached {
        do {
          let result = try captureSync(
            sessionName: sessionName,
            scrollbackLimit: scrollbackLimit
          )
          continuation.resume(returning: result)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func captureSync(sessionName: String, scrollbackLimit: Int) throws -> Data {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = [
      "-L", socketName,
      "capture-pane",
      "-p",                     // print to stdout
      "-e",                     // include escape sequences
      "-S", "-\(scrollbackLimit)",
      "-t", "\(sessionName):0.0",
    ]
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    // Drain stdout incrementally so the kernel buffer doesn't fill and deadlock the writer.
    let buffer = LockedDataBuffer()
    outPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      if !chunk.isEmpty {
        buffer.append(chunk)
      }
    }

    try process.run()
    process.waitUntilExit()
    outPipe.fileHandleForReading.readabilityHandler = nil
    // Drain any final bytes that arrived between the last handler invocation and exit
    let tail = outPipe.fileHandleForReading.readDataToEndOfFile()
    buffer.append(tail)
    let result = buffer.snapshot()

    let stderr = String(
      bytes: errPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? ""

    guard process.terminationStatus == 0 else {
      throw TmuxClientError.commandFailed(
        stderr: stderr,
        exitCode: process.terminationStatus
      )
    }
    return result
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

  /// Re-sources the given tmux.conf into a running server so server-wide options
  /// (mouse, bindings, status, set-titles, etc.) take effect live. No-op if the
  /// server isn't running yet — the next `new-session` will read the file fresh.
  /// Tolerates "no server running" / "error connecting" so it's safe to call
  /// unconditionally at app launch right after `TmuxConfigWriter.writeIfChanged`.
  ///
  /// Note: window-scope options baked at window-creation time (e.g. the exact
  /// `history-limit` value of an existing window) are NOT affected. Only newly
  /// created windows/sessions see those.
  func sourceFile(at url: URL) async throws {
    let result = try await run(["source-file", url.path])
    if !result.success {
      if Self.isCleanupTolerated(result.stderr) {
        return
      }
      throw TmuxClientError.commandFailed(stderr: result.stderr, exitCode: result.exitCode)
    }
  }

  /// Cheap health check — returns true when the tmux server responds to `ls`,
  /// including the "no server running" case (which we treat as "alive-for-our-purposes"
  /// because we lazily start the server on first `new-session`). Returns false only
  /// when a non-tolerated error fires (process spawn failed, weird stderr, etc.).
  func ping() async -> Bool {
    do {
      _ = try await listSessionNames()
      return true
    } catch {
      return false
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

  // NOTE(phase-3): The current `waitUntilExit()` then `readDataToEndOfFile()` order
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
    let stdout = String(bytes: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(bytes: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
  }
}

enum TmuxClientError: Error, Equatable {
  case commandFailed(stderr: String, exitCode: Int32)
}

/// Thread-safe append-only byte buffer used to collect `readabilityHandler` chunks.
/// The handler closure is `@Sendable`; a class with internal locking is the simplest
/// way to share mutable state across it without tripping Swift 6 concurrency checks.
private final class LockedDataBuffer: @unchecked Sendable {
  private let lock = NSLock()
  nonisolated(unsafe) private var data = Data()

  nonisolated func append(_ chunk: Data) {
    lock.lock()
    data.append(chunk)
    lock.unlock()
  }

  nonisolated func snapshot() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}
