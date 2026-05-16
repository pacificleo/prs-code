import Foundation
import Testing

@testable import CherryLily

struct TmuxClientTests {
  private static var tmuxAvailable: Bool { TmuxBinary.isAvailable }

  /// Each test uses a unique socket name to avoid touching real CherryLily sessions.
  private static func makeIsolatedClient() -> TmuxClient {
    let socket = "cl-test-\(UUID().uuidString.prefix(8).lowercased())"
    return TmuxClient(executableURL: TmuxBinary.bundledURL, socketName: socket)
  }

  @Test func listSessionsReturnsEmptyWhenNoneExist() async throws {
    try #require(Self.tmuxAvailable)
    let client = Self.makeIsolatedClient()
    defer { try? client.killServer() }
    let names = try await client.listSessionNames()
    #expect(names.isEmpty)
  }

  @Test func sessionAfterCreationAppearsInList() async throws {
    try #require(Self.tmuxAvailable)
    let client = Self.makeIsolatedClient()
    defer { try? client.killServer() }
    try await client.createSession(named: "test-session", workingDirectory: nil)
    let names = try await client.listSessionNames()
    #expect(names.contains("test-session"))
  }

  @Test func killSessionRemovesIt() async throws {
    try #require(Self.tmuxAvailable)
    let client = Self.makeIsolatedClient()
    defer { try? client.killServer() }
    try await client.createSession(named: "kill-me", workingDirectory: nil)
    try await client.killSession(named: "kill-me")
    let names = try await client.listSessionNames()
    #expect(!names.contains("kill-me"))
  }

  @Test func killSessionOnUnknownNameDoesNotThrow() async throws {
    try #require(Self.tmuxAvailable)
    let client = Self.makeIsolatedClient()
    defer { try? client.killServer() }
    // Should be tolerant — we use this in cleanup paths
    try await client.killSession(named: "does-not-exist")
  }
}
