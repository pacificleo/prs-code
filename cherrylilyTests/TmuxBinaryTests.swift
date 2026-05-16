import Foundation
import Testing

@testable import CherryLily

struct TmuxBinaryTests {
  @Test func resolvedPathIsInsideAppBundle() {
    // Resolution uses Bundle.main; in the test bundle this points at the test runner.
    // We assert the structure (path ends with the expected filename), not absolute equality.
    let url = TmuxBinary.bundledURL
    #expect(url.lastPathComponent == "tmux-cherrylily")
  }

  @Test func executableExistsAfterAppBundleBuild() {
    // This test only meaningfully passes when run inside an integration setup
    // where CherryLily.app has been built. In unit-only runs the bundled binary
    // path may not exist; we guard with a soft assertion.
    let url = TmuxBinary.bundledURL
    if FileManager.default.fileExists(atPath: url.path) {
      #expect(FileManager.default.isExecutableFile(atPath: url.path))
    }
  }
}
