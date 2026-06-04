import Foundation
import Testing

@testable import CherryLily

struct GitClientCommonDirTests {
  @Test func returnsAbsoluteCommonDir() async throws {
    let shell = ShellClient(
      run: { _, arguments, _ in
        #expect(arguments.contains("--git-common-dir"))
        return ShellOutput(stdout: "/repo/.git\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginStreamImpl: { _, _, _, _ in AsyncThrowingStream { $0.finish() } }
    )
    let client = GitClient(shell: shell, capabilities: GitCapabilities(shell: shell))
    let url = await client.gitCommonDir(for: URL(fileURLWithPath: "/repo/wt"))
    #expect(url?.path(percentEncoded: false) == "/repo/.git")
  }
}
