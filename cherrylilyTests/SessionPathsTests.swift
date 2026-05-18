import Foundation
import Testing

@testable import CherryLily

struct SessionPathsTests {
  @Test func layoutFileLivesUnderRoot() {
    let root = URL(fileURLWithPath: "/tmp/cl-test")
    let paths = SessionPaths(root: root)
    #expect(paths.layoutFile.path == "/tmp/cl-test/layout.json")
  }

  @Test func tmuxConfigFileLivesUnderRoot() {
    let root = URL(fileURLWithPath: "/tmp/cl-test")
    let paths = SessionPaths(root: root)
    #expect(paths.tmuxConfigFile.path == "/tmp/cl-test/tmux.conf")
  }

  @Test func scrollbackFileForSurfaceComposesUUID() {
    let root = URL(fileURLWithPath: "/tmp/cl-test")
    let paths = SessionPaths(root: root)
    let id = SurfaceID(rawValue: UUID(uuidString: "7C8C2B5E-5D7E-4C7E-9C7E-6C7E7C7E7C7E")!)
    let expected = "/tmp/cl-test/sessions/7c8c2b5e-5d7e-4c7e-9c7e-6c7e7c7e7c7e.bin"
    #expect(paths.scrollbackFile(for: id).path == expected)
  }

  @Test func tmuxSocketNameIsStable() {
    let paths = SessionPaths(root: URL(fileURLWithPath: "/tmp/cl-test"))
    #expect(paths.tmuxSocketName == "cherrylily")
  }

  @Test func tmuxSocketNameCanBeOverriddenForTests() {
    // Production binds to a single "cherrylily" socket so a relaunch reattaches
    // to the same sessions. Tests override with a unique per-test name so they
    // can safely killServer() in teardown without touching the user's running
    // CherryLily socket.
    let paths = SessionPaths(
      root: URL(fileURLWithPath: "/tmp/cl-test"),
      tmuxSocketName: "cl-test-abc123"
    )
    #expect(paths.tmuxSocketName == "cl-test-abc123")
  }

  @Test func ensureDirectoriesExistCreatesRootAndSessionsAndIsIdempotent() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "cl-paths-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = SessionPaths(root: root)

    try paths.ensureDirectoriesExist()
    #expect(FileManager.default.fileExists(atPath: paths.root.path))
    #expect(FileManager.default.fileExists(atPath: paths.sessionsDirectory.path))

    // Second call must not throw — withIntermediateDirectories: true makes mkdir idempotent.
    try paths.ensureDirectoriesExist()
    #expect(FileManager.default.fileExists(atPath: paths.sessionsDirectory.path))
  }
}
