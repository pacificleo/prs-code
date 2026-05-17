import Foundation

/// Background-polls tmux liveness. Fires `onCrash` after two consecutive ping
/// failures so a single flaky exec doesn't trigger a false alarm.
///
/// `Sendable` because `tmuxClient` and `onCrash` are Sendable; the underlying
/// Task does its work off-main and only invokes the callback off-main as well.
/// The caller is responsible for hopping to MainActor in the callback if needed.
final class TmuxHealthMonitor: Sendable {
  let tmuxClient: TmuxClient
  let interval: TimeInterval
  let onCrash: @Sendable () -> Void

  // nonisolated(unsafe) is acceptable because all writes happen on the polling task
  // and the only external accessor (stop()) just sets it to nil — no concurrent reads.
  private nonisolated(unsafe) var task: Task<Void, Never>?

  init(
    tmuxClient: TmuxClient,
    interval: TimeInterval = 10,
    onCrash: @escaping @Sendable () -> Void
  ) {
    self.tmuxClient = tmuxClient
    self.interval = interval
    self.onCrash = onCrash
  }

  /// Idempotent. Starts a polling Task that fires onCrash after two consecutive
  /// ping failures, then stops itself.
  func start() {
    guard task == nil else { return }
    task = Task { [tmuxClient, interval, onCrash] in
      var consecutiveFailures = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        if Task.isCancelled { return }
        let alive = await tmuxClient.ping()
        if alive {
          consecutiveFailures = 0
          continue
        }
        consecutiveFailures += 1
        if consecutiveFailures >= 2 {
          onCrash()
          return
        }
      }
    }
  }

  /// Idempotent.
  func stop() {
    task?.cancel()
    task = nil
  }
}
