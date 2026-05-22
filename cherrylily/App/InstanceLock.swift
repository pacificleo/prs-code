import AppKit
import Darwin
import Foundation

private let instanceLockLogger = SupaLogger("InstanceLock")

/// Sandbox-safe single-instance enforcement via an advisory file lock.
///
/// At launch we open `<paths.root>/.instance.lock` and try to take an
/// exclusive non-blocking `flock`. If we get it, we're the first instance and
/// proceed normally; the kernel releases the lock automatically when our
/// process exits, so no explicit teardown is required.
///
/// If the lock is already held, we read the existing PID from the file, try to
/// bring that process to the foreground via `NSRunningApplication.activate`,
/// then call `NSApp.terminate(nil)` so this second launch goes away.
///
/// Why flock and not `NSDistributedNotificationCenter`: distributed
/// notifications are restricted under the App Sandbox, and we want this guard
/// to keep working if/when we tighten entitlements. A file inside our own
/// container is always writable.
enum InstanceLock {
  /// Held lock file descriptor for the lifetime of the first-instance process.
  /// We intentionally never close it — the kernel releases the lock on exit.
  nonisolated(unsafe) private static var heldFileDescriptor: Int32 = -1

  /// Acquires the single-instance lock or terminates this process if another
  /// instance already holds it. Safe to call multiple times; only the first
  /// successful call actually takes a lock.
  ///
  /// Returns normally for the first instance. Calls `NSApp.terminate(nil)` and
  /// does not return for any subsequent instance.
  ///
  /// Callers must skip this under XCTest — the test runner hosts itself inside
  /// the app, so calling here during test bootstrap will fight the user's
  /// running Release build for the lock and call `NSApp.terminate` on the test
  /// process. See `CherryLilyAppDelegate.applicationDidFinishLaunching` for the
  /// production call site and its XCTest guard.
  @MainActor
  static func acquireOrTerminate(paths: SessionPaths = SessionPaths()) {
    let url = paths.root.appending(path: ".instance.lock")
    do {
      try FileManager.default.createDirectory(
        at: paths.root,
        withIntermediateDirectories: true
      )
    } catch {
      // Can't even create the directory — bail out and let launch proceed.
      // Losing multi-instance protection is preferable to blocking launch.
      instanceLockLogger.warning(
        "could not create lock directory at \(paths.root.path): \(error)"
      )
      return
    }

    let fileDescriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
    guard fileDescriptor >= 0 else {
      instanceLockLogger.warning(
        "could not open instance lock file at \(url.path) (errno=\(errno))"
      )
      return
    }

    let lockResult = flock(fileDescriptor, LOCK_EX | LOCK_NB)
    if lockResult == 0 {
      // First instance: write our PID for diagnostic value and keep the fd alive
      // for the rest of the process lifetime.
      writePID(to: fileDescriptor)
      heldFileDescriptor = fileDescriptor
      return
    }

    // Lock held by another CherryLily instance. Find it and bring it to front,
    // then exit cleanly.
    let otherPID = readPID(from: url)
    close(fileDescriptor)
    foreground(pid: otherPID)
    NSApp.terminate(nil)
  }

  private static func writePID(to fileDescriptor: Int32) {
    let pidString = "\(getpid())\n"
    _ = pidString.withCString { pointer in
      // Truncate any stale contents from a previous run before writing — the
      // file may already contain a longer PID string.
      ftruncate(fileDescriptor, 0)
      lseek(fileDescriptor, 0, SEEK_SET)
      return write(fileDescriptor, pointer, strlen(pointer))
    }
  }

  private static func readPID(from url: URL) -> pid_t? {
    guard
      let data = try? Data(contentsOf: url),
      let str = String(data: data, encoding: .utf8),
      let pid = pid_t(str.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    return pid
  }

  @MainActor
  private static func foreground(pid: pid_t?) {
    guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
    app.activate(options: [.activateAllWindows])
  }
}
