import Foundation

/// Background-polls tmux liveness. Fires `onCrash` after two consecutive ping
/// failures so a single flaky exec doesn't trigger a false alarm.
///
/// Constrained to `@MainActor` because the only owner is `CherryLilyAppDelegate`
/// (itself MainActor), which calls `start()` once at launch and `stop()` once at
/// termination. Pinning to MainActor eliminates any start/stop race on the
/// internal `task` reference without burdening callers.
@MainActor
final class TmuxHealthMonitor {
  let tmuxClient: TmuxClient
  let interval: TimeInterval
  let onCrash: @Sendable () -> Void

  private var task: Task<Void, Never>?

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
