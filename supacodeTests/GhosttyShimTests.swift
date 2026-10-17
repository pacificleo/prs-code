import Foundation
import Testing

struct GhosttyShimTests {
  @Test
  func ghosttyShellShimManagesSSHCache() throws {
    let sourceRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let shimURL = sourceRoot.appendingPathComponent("scripts/ghostty-shim.sh")
    #expect(FileManager.default.fileExists(atPath: shimURL.path))

    try verifyShim(executableURL: shimURL)
  }

  @Test
  func ghosttyCShimManagesSSHCache() throws {
    let sourceRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let cSourceURL = sourceRoot.appendingPathComponent("scripts/ghostty-shim.c")
    #expect(FileManager.default.fileExists(atPath: cSourceURL.path))

    let tmpBinary = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostty-c-shim-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpBinary) }

    // Compile the C source
    let clangProcess = Process()
    clangProcess.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    clangProcess.arguments = ["-O2", cSourceURL.path, "-o", tmpBinary.path]
    try clangProcess.run()
    clangProcess.waitUntilExit()
    #expect(clangProcess.terminationStatus == 0)

    try verifyShim(executableURL: tmpBinary)
  }

  private func verifyShim(executableURL: URL) throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    func runShim(args: [String]) throws -> (status: Int32, stdout: String) {
      let process = Process()
      process.executableURL = executableURL
      process.arguments = args
      var env = ProcessInfo.processInfo.environment
      env["XDG_STATE_HOME"] = tmpDir.path
      process.environment = env
      let pipe = Pipe()
      process.standardOutput = pipe
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let stdout = String(bytes: data, encoding: .utf8) ?? ""
      return (process.terminationStatus, stdout)
    }

    // 1. Initial check: host is not cached (should exit 1)
    let checkInitial = try runShim(args: ["+ssh-cache", "--host=user@example.com"])
    #expect(checkInitial.status == 1)

    // 2. Add host to cache (should exit 0)
    let addResult = try runShim(args: ["+ssh-cache", "--add=user@example.com"])
    #expect(addResult.status == 0)

    // 3. Check again: host is now cached (should exit 0)
    let checkAfterAdd = try runShim(args: ["+ssh-cache", "--host=user@example.com"])
    #expect(checkAfterAdd.status == 0)

    // 4. Check different host: not cached (should exit 1)
    let checkDifferent = try runShim(args: ["+ssh-cache", "--host=other@example.com"])
    #expect(checkDifferent.status == 1)

    // 5. List cache: should contain user@example.com
    let listResult = try runShim(args: ["+ssh-cache"])
    #expect(listResult.status == 0)
    #expect(listResult.stdout.contains("user@example.com|"))
    #expect(listResult.stdout.contains("|xterm-ghostty"))

    // 6. Remove host (should exit 0)
    let removeResult = try runShim(args: ["+ssh-cache", "--remove=user@example.com"])
    #expect(removeResult.status == 0)

    // 7. Check again: host is removed (should exit 1)
    let checkAfterRemove = try runShim(args: ["+ssh-cache", "--host=user@example.com"])
    #expect(checkAfterRemove.status == 1)

    // 8. Clear cache
    _ = try runShim(args: ["+ssh-cache", "--add=foo@example.com"])
    let clearResult = try runShim(args: ["+ssh-cache", "--clear"])
    #expect(clearResult.status == 0)
    let checkAfterClear = try runShim(args: ["+ssh-cache", "--host=foo@example.com"])
    #expect(checkAfterClear.status == 1)

    // 9. Non +ssh-cache command exits 1
    let unknownCmd = try runShim(args: ["unknown-command"])
    #expect(unknownCmd.status == 1)
  }
}
