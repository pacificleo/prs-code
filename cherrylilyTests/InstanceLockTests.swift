import Foundation
import Testing

@testable import CherryLily

@MainActor
struct InstanceLockTests {
  @Test func acquireWritesPidFile() throws {
    // Use a temp Application Support root so the test never touches the real
    // user lockfile and never collides with a running CherryLily instance.
    let paths = SessionPaths(
      root: URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "cl-instance-test-\(UUID().uuidString)")
    )
    defer { try? FileManager.default.removeItem(at: paths.root) }

    InstanceLock.acquireOrTerminate(paths: paths)

    let lockURL = paths.root.appending(path: ".instance.lock")
    let pidString = try String(contentsOf: lockURL, encoding: .utf8)
    let pid = pid_t(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    #expect(pid == getpid())
  }

  // Note: the "second-instance terminates itself" branch is intentionally not
  // tested — it would call NSApp.terminate(nil) inside the test runner, killing
  // the test process. The pidfile write above is sufficient signal that the
  // first-instance acquire path is wired up; the terminate path is one
  // NSRunningApplication.activate + one NSApp.terminate call so the surface
  // area for a bug is small.
}
