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
    let a = SurfaceID(); let b = SurfaceID()
    try store.write(bytes: Data("a".utf8), for: a)
    try store.write(bytes: Data("b".utf8), for: b)
    #expect(Set(try store.storedSurfaceIDs()) == Set([a, b]))
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
    let asString = String(decoding: cleaned, as: UTF8.self)
    #expect(asString == "safesafe")
  }

  @Test func sanitizeStripsOSC8Hyperlink() {
    // OSC 8 = ESC ] 8 ; params ; URI ST  text  ESC ] 8 ; ; ST
    let dangerous = Data("\u{001b}]8;;https://evil\u{0007}link\u{001b}]8;;\u{0007}".utf8)
    let cleaned = ScrollbackStore.sanitize(dangerous)
    let asString = String(decoding: cleaned, as: UTF8.self)
    #expect(asString == "link")
  }

  @Test func sanitizeStripsOSC133SemanticPrompt() {
    let dangerous = Data("normal\u{001b}]133;A\u{0007}prompt".utf8)
    let cleaned = ScrollbackStore.sanitize(dangerous)
    #expect(String(decoding: cleaned, as: UTF8.self) == "normalprompt")
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
    #expect(String(decoding: cleaned, as: UTF8.self) == "rest")
  }
}
