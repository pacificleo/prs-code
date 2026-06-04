import Foundation
import Testing

@testable import CherryLily

struct GitClientHeadSHATests {
  @Test func headSHAReturnsTrimmedRevParseOutput() async throws {
    let shell = ShellClient(
      run: { _, arguments, _ in
        #expect(arguments.contains("rev-parse"))
        #expect(arguments.contains("HEAD"))
        return ShellOutput(stdout: "abc123def456\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginStreamImpl: { _, _, _, _ in AsyncThrowingStream { $0.finish() } }
    )
    let client = GitClient(shell: shell, capabilities: GitCapabilities(shell: shell))

    let sha = await client.headSHA(for: URL(fileURLWithPath: "/tmp/wt"))

    #expect(sha == "abc123def456")
  }

  @Test func headSHAReturnsNilOnFailure() async throws {
    let shell = ShellClient(
      run: { _, _, _ in throw ShellClientError(command: "git", stdout: "", stderr: "boom", exitCode: 128) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginStreamImpl: { _, _, _, _ in AsyncThrowingStream { $0.finish() } }
    )
    let client = GitClient(shell: shell, capabilities: GitCapabilities(shell: shell))

    let sha = await client.headSHA(for: URL(fileURLWithPath: "/tmp/wt"))

    #expect(sha == nil)
  }
}
