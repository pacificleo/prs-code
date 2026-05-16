import Foundation
import Testing

@testable import CherryLily

struct ScrollbackStoreTests {
  private static func makeTempPaths() -> SessionPaths {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "cl-scrollback-test-\(UUID().uuidString)")
    return SessionPaths(root: temp)
  }

  @Test func writeThenReadRoundtrip() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = ScrollbackStore(paths: paths)
    let id = SurfaceID()
    let bytes = Data("hello \u{001b}[31mred\u{001b}[0m world".utf8)
    try store.write(bytes: bytes, for: id)
    #expect(try store.read(for: id) == bytes)
  }

  @Test func readReturnsNilWhenMissing() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = ScrollbackStore(paths: paths)
    #expect(try store.read(for: SurfaceID()) == nil)
  }

  @Test func deleteRemovesFile() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = ScrollbackStore(paths: paths)
    let id = SurfaceID()
    try store.write(bytes: Data("x".utf8), for: id)
    try store.delete(for: id)
    #expect(try store.read(for: id) == nil)
  }

  @Test func storedSurfaceIDsListsAllFiles() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = ScrollbackStore(paths: paths)
    let firstID = SurfaceID(); let secondID = SurfaceID()
    try store.write(bytes: Data("a".utf8), for: firstID)
    try store.write(bytes: Data("b".utf8), for: secondID)
    #expect(Set(try store.storedSurfaceIDs()) == Set([firstID, secondID]))
  }

  @Test func storedSurfaceIDsIgnoresNonUUIDFiles() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    try Data().write(to: paths.sessionsDirectory.appending(path: "garbage.txt"))
    let store = ScrollbackStore(paths: paths)
    #expect(try store.storedSurfaceIDs() == [])
  }

  @Test func sanitizeStripsOSC52Clipboard() {
    // OSC 52 = ESC ] 52 ; … ST  (clipboard write)
    let dangerous = Data("safe\u{001b}]52;c;dGVzdA==\u{0007}safe".utf8)
    let cleaned = ScrollbackStore.sanitize(dangerous)
    #expect(!cleaned.contains([0x1B, 0x5D, 0x35, 0x32]))   // ESC ] 5 2
    let asString = String(bytes: cleaned, encoding: .utf8) ?? ""
    #expect(asString == "safesafe")
  }

  @Test func sanitizeStripsOSC8Hyperlink() {
    // OSC 8 = ESC ] 8 ; params ; URI ST  text  ESC ] 8 ; ; ST
    let dangerous = Data("\u{001b}]8;;https://evil\u{0007}link\u{001b}]8;;\u{0007}".utf8)
    let cleaned = ScrollbackStore.sanitize(dangerous)
    let asString = String(bytes: cleaned, encoding: .utf8) ?? ""
    #expect(asString == "link")
  }

  @Test func sanitizeStripsOSC133SemanticPrompt() {
    let dangerous = Data("normal\u{001b}]133;A\u{0007}prompt".utf8)
    let cleaned = ScrollbackStore.sanitize(dangerous)
    #expect(String(bytes: cleaned, encoding: .utf8) == "normalprompt")
  }

  @Test func sanitizePreservesColorEscapes() {
    // SGR sequence: ESC [ 31 m  (red) — this should pass through unchanged
    let safe = Data("\u{001b}[31mred\u{001b}[0m".utf8)
    let cleaned = ScrollbackStore.sanitize(safe)
    #expect(cleaned == safe)
  }

  @Test func sanitizeHandlesSTAsBackslash() {
    // OSC sequences can be terminated with ST = ESC \ (instead of BEL)
    let dangerous = Data("\u{001b}]52;c;dGVzdA==\u{001b}\u{005c}rest".utf8)
    let cleaned = ScrollbackStore.sanitize(dangerous)
    #expect(String(bytes: cleaned, encoding: .utf8) == "rest")
  }

  @Test func sanitizePreservesOSC1337NotConfusedWith133() {
    // OSC 1337 is iTerm2's image protocol — common in the wild. The digit-greedy
    // parse must read all 4 digits as 1337 and NOT match the OSC 133 strip filter
    // on the substring "133". Regression-pin this so a future "optimize the parser"
    // refactor can't silently start matching prefixes.
    let input = Data("\u{001b}]1337;File=name=foo\u{0007}after".utf8)
    let cleaned = ScrollbackStore.sanitize(input)
    #expect(String(bytes: cleaned, encoding: .utf8) == "\u{001b}]1337;File=name=foo\u{0007}after")
  }

  @Test func sanitizeDropsUnterminatedDangerousOSCToEOF() {
    // A truncated tmux capture-pane could produce a dangerous OSC with no terminator.
    // The parser must drop everything from the OSC start through end-of-input rather
    // than accidentally preserving the dangerous payload because no BEL/ESC-\\ was found.
    let input = Data("keep\u{001b}]52;c;dGVzdA".utf8)  // no BEL, no ESC \
    let cleaned = ScrollbackStore.sanitize(input)
    #expect(String(bytes: cleaned, encoding: .utf8) == "keep")
  }
}
