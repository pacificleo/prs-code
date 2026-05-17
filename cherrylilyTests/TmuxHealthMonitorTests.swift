import Foundation
import Testing

@testable import CherryLily

struct TmuxHealthMonitorTests {
  private static func makeAlwaysFailingClient() -> TmuxClient {
    TmuxClient(
      executableURL: URL(fileURLWithPath: "/nonexistent/tmux"),
      socketName: "cl-test-\(UUID().uuidString)"
    )
  }

  @Test func firesCrashAfterTwoConsecutiveFailures() async {
    let client = Self.makeAlwaysFailingClient()
    let fired = Lock<Bool>(false)
    let monitor = TmuxHealthMonitor(
      tmuxClient: client,
      interval: 0.01,
      onCrash: { fired.set(true) }
    )
    monitor.start()
    // Poll for up to 5 seconds — Swift Testing runs in parallel and the polling
    // task can be starved heavily under load, so we use eventual-consistency
    // rather than a fixed wall-clock budget.
    for _ in 0..<50 {
      if fired.get() { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    monitor.stop()
    #expect(fired.get())
  }

  @Test func stopPreventsFiring() async {
    let client = Self.makeAlwaysFailingClient()
    let fired = Lock<Bool>(false)
    let monitor = TmuxHealthMonitor(
      tmuxClient: client,
      interval: 0.5,
      onCrash: { fired.set(true) }
    )
    monitor.start()
    // Stop well before the first interval elapses so no ping has fired.
    try? await Task.sleep(for: .milliseconds(50))
    monitor.stop()
    // Wait past what would have been multiple intervals to confirm nothing fires.
    try? await Task.sleep(for: .seconds(2))
    #expect(!fired.get())
  }

  @Test func startTwiceIsIdempotent() {
    let client = Self.makeAlwaysFailingClient()
    let monitor = TmuxHealthMonitor(
      tmuxClient: client,
      interval: 1.0,
      onCrash: {}
    )
    monitor.start()
    monitor.start()  // must not crash
    monitor.stop()
    #expect(Bool(true))
  }
}

/// Test-only thread-safe holder for primitive values from inside @Sendable closures.
private final class Lock<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  nonisolated(unsafe) private var value: T
  nonisolated init(_ value: T) { self.value = value }
  nonisolated func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
  nonisolated func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
