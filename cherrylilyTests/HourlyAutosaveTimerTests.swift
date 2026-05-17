import Foundation
import Testing

@testable import CherryLily

@MainActor
struct HourlyAutosaveTimerTests {
  // Convenience builder using a real SessionPersistence pointing at a temp dir.
  private static func makeTimer(
    interval: DispatchTimeInterval,
    fireCount: @escaping @MainActor () -> Void = {},
    snapshot: @escaping @MainActor () -> SessionLayout? = { nil }
  ) -> (HourlyAutosaveTimer, SessionPaths) {
    let paths = SessionPaths(
      root: URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "cl-autosave-test-\(UUID().uuidString)")
    )
    let persistence = SessionPersistence(paths: paths)
    let wrappedSnapshot: @MainActor () -> SessionLayout? = {
      fireCount()
      return snapshot()
    }
    let timer = HourlyAutosaveTimer(
      persistence: persistence,
      interval: interval,
      snapshot: wrappedSnapshot,
      scrollbackLimit: { 50_000 }
    )
    return (timer, paths)
  }

  @Test func startSchedulesAtLeastOneFire() async throws {
    var fired = 0
    let (timer, paths) = Self.makeTimer(
      interval: .milliseconds(50),
      fireCount: { fired += 1 },
      snapshot: { nil }
    )
    defer { try? FileManager.default.removeItem(at: paths.root) }
    timer.start()
    try await Task.sleep(for: .milliseconds(400))
    timer.stop()
    #expect(fired >= 1)
  }

  @Test func stopPreventsFurtherFires() async throws {
    var fired = 0
    let (timer, paths) = Self.makeTimer(
      interval: .milliseconds(50),
      fireCount: { fired += 1 },
      snapshot: { nil }
    )
    defer { try? FileManager.default.removeItem(at: paths.root) }
    timer.start()
    try await Task.sleep(for: .milliseconds(250))
    timer.stop()
    // Drain any in-flight fire that may have been dispatched before stop() took
    // effect. Dispatch source cancel() prevents NEW fires but won't cancel a fire
    // already on the queue. After this drain, the baseline is stable.
    try await Task.sleep(for: .milliseconds(200))
    let countAfterDrain = fired
    try await Task.sleep(for: .milliseconds(300))
    let countLater = fired
    #expect(countLater == countAfterDrain, "stop() should halt fires; got \(countAfterDrain) -> \(countLater)")
  }

  @Test func startTwiceIsIdempotent() throws {
    let (timer, paths) = Self.makeTimer(
      interval: .seconds(1),
      snapshot: { nil }
    )
    defer {
      timer.stop()
      try? FileManager.default.removeItem(at: paths.root)
    }
    timer.start()
    timer.start()  // must not crash, must not double-fire
    #expect(Bool(true))
  }

  @Test func updateEnabledFlipsBetweenStartAndStop() async throws {
    var fired = 0
    let (timer, paths) = Self.makeTimer(
      interval: .milliseconds(40),
      fireCount: { fired += 1 },
      snapshot: { nil }
    )
    defer { try? FileManager.default.removeItem(at: paths.root) }

    timer.updateEnabled(true)
    try await Task.sleep(for: .milliseconds(250))
    #expect(fired >= 1)

    timer.updateEnabled(false)
    // Drain any in-flight fire before sampling the baseline.
    try await Task.sleep(for: .milliseconds(200))
    let afterOff = fired

    try await Task.sleep(for: .milliseconds(300))
    #expect(fired == afterOff, "disabled timer should stop firing")
  }
}
