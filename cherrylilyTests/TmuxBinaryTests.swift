import Foundation
import Testing

@testable import CherryLily

struct TmuxBinaryTests {
  @Test func resolvedPathIsInsideAppBundle() {
    let url = TmuxBinary.bundledURL
    #expect(url.lastPathComponent == "tmux-cherrylily")
    // Resolution must produce a path inside a `Contents/MacOS` directory.
    // In tests the bundle is the test runner; in production it's CherryLily.app.
    let parent = url.deletingLastPathComponent().path
    #expect(parent.hasSuffix("/Contents/MacOS") || parent.hasSuffix("/MacOS"))
  }

  @Test func executableExistsAfterAppBundleBuild() throws {
    // Skip cleanly when the binary isn't present (unit-only test runs).
    // When it is present (integration runs after `make build-app`), the executable bit
    // must be set — that's what the Embed Executables phase guarantees.
    try #require(TmuxBinary.isAvailable)
    #expect(FileManager.default.isExecutableFile(atPath: TmuxBinary.bundledURL.path))
  }
}
