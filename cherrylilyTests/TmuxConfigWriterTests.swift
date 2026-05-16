import Foundation
import Testing

@testable import CherryLily

struct TmuxConfigWriterTests {
  private static func makeTempPaths() -> SessionPaths {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "cl-tmuxconf-test-\(UUID().uuidString)")
    return SessionPaths(root: temp)
  }

  @Test func writesConfigToTmuxConfigFile() throws {
    let paths = Self.makeTempPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let writer = TmuxConfigWriter(paths: paths)
    try writer.writeIfChanged(scrollbackLimit: 12345, userShell: "/bin/zsh")

    let written = try String(contentsOf: paths.tmuxConfigFile, encoding: .utf8)
    #expect(written.contains("set -g history-limit 12345"))
  }

  @Test func writeIfChangedSkipsWriteWhenContentMatches() throws {
    let paths = Self.makeTempPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let writer = TmuxConfigWriter(paths: paths)

    try writer.writeIfChanged(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    let firstMtime = try FileManager.default.attributesOfItem(
      atPath: paths.tmuxConfigFile.path
    )[.modificationDate] as? Date
    #expect(firstMtime != nil)

    // Wait a tick so a write would visibly change mtime.
    Thread.sleep(forTimeInterval: 0.05)

    try writer.writeIfChanged(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    let secondMtime = try FileManager.default.attributesOfItem(
      atPath: paths.tmuxConfigFile.path
    )[.modificationDate] as? Date

    #expect(firstMtime == secondMtime, "writeIfChanged should not rewrite identical content")
  }

  @Test func writeIfChangedRewritesWhenScrollbackLimitChanges() throws {
    let paths = Self.makeTempPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let writer = TmuxConfigWriter(paths: paths)

    try writer.writeIfChanged(scrollbackLimit: 10_000, userShell: "/bin/zsh")
    try writer.writeIfChanged(scrollbackLimit: 50_000, userShell: "/bin/zsh")

    let written = try String(contentsOf: paths.tmuxConfigFile, encoding: .utf8)
    #expect(written.contains("set -g history-limit 50000"))
    #expect(!written.contains("set -g history-limit 10000"))
  }

  @Test func writeIfChangedCreatesParentDirectoryIfMissing() throws {
    let paths = Self.makeTempPaths()
    // Note: do NOT call ensureDirectoriesExist — the writer must create the dir itself
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let writer = TmuxConfigWriter(paths: paths)

    try writer.writeIfChanged(scrollbackLimit: 50_000, userShell: "/bin/zsh")
    #expect(FileManager.default.fileExists(atPath: paths.tmuxConfigFile.path))
  }
}
