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
    let expected = "/tmp/cl-test/sessions/7C8C2B5E-5D7E-4C7E-9C7E-6C7E7C7E7C7E.bin"
    #expect(paths.scrollbackFile(for: id).path == expected)
  }

  @Test func tmuxSocketNameIsStable() {
    let paths = SessionPaths(root: URL(fileURLWithPath: "/tmp/cl-test"))
    #expect(paths.tmuxSocketName == "cherrylily")
  }
}
