import Foundation
import Testing

@testable import CherryLily

struct TmuxClientCaptureTests {
  private static var tmuxAvailable: Bool { TmuxBinary.isAvailable }

  private static func makeIsolatedClient() -> TmuxClient {
    let socket = "cl-test-\(UUID().uuidString.prefix(8).lowercased())"
    return TmuxClient(executableURL: TmuxBinary.bundledURL, socketName: socket)
  }

  @Test func capturePaneReturnsScrollbackContents() async throws {
    try #require(Self.tmuxAvailable)
    let client = Self.makeIsolatedClient()
    defer { try? client.killServer() }

    try await client.createSession(named: "capture-test", workingDirectory: nil)

    // Send a recognizable string to the pane and let the shell render it
    try Self.sendKeys(to: client, sessionName: "capture-test", text: "echo hello-capture")
    try await Task.sleep(nanoseconds: 500_000_000)

    let data = try await client.capturePane(
      sessionName: "capture-test",
      scrollbackLimit: 1000
    )
    let text = String(bytes: data, encoding: .utf8) ?? ""
    #expect(text.contains("hello-capture"))
  }

  /// Runs `tmux send-keys -t <session>:0 <text> Enter` via the same socket.
  /// Test-only helper kept local rather than promoted to TmuxClient because the
  /// production code never sends arbitrary keystrokes — only capture-pane needs it.
  private static func sendKeys(
    to client: TmuxClient,
    sessionName: String,
    text: String
  ) throws {
    let process = Process()
    process.executableURL = client.executableURL
    process.arguments = [
      "-L", client.socketName,
      "send-keys",
      "-t", "\(sessionName):0",
      text,
      "Enter",
    ]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
}
