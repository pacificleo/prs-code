import Foundation

/// Periodically calls `SessionPersistence.captureAll` so an unexpected app
/// exit doesn't lose recent terminal contents. Drives the
/// `hourlyAutosaveEnabled` setting — the caller wires settings changes via
/// `updateEnabled(_:)`.
///
/// MainActor-bound because the layout/scrollback closures need to read
/// observable state. The actual capture is kicked off in a non-isolated
/// Task so the timer fire-handler returns promptly.
@MainActor
final class HourlyAutosaveTimer {
  let interval: DispatchTimeInterval

  private let persistence: SessionPersistence
  private let snapshot: @MainActor () -> SessionLayout?
  private let scrollbackLimit: @MainActor () -> Int?
  private let queue: DispatchQueue
  private var timer: DispatchSourceTimer?

  /// `interval` defaults to one hour. Tests pass shorter intervals.
  init(
    persistence: SessionPersistence,
    interval: DispatchTimeInterval = .seconds(3600),
    snapshot: @escaping @MainActor () -> SessionLayout?,
    scrollbackLimit: @escaping @MainActor () -> Int?
  ) {
    self.persistence = persistence
    self.interval = interval
    self.snapshot = snapshot
    self.scrollbackLimit = scrollbackLimit
    self.queue = DispatchQueue(label: "app.supabit.cherrylily.autosave", qos: .utility)
  }

  /// Idempotent: calling start() on an already-running timer is a no-op.
  func start() {
    guard timer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(60))
    // Event handler runs on the autosave dispatch queue (NOT MainActor); we
    // explicitly mark it `@Sendable` so Swift 6 doesn't infer MainActor isolation
    // from the project-wide default. The handler then hops to MainActor via a
    // Task to read the snapshot/scrollback closures.
    let handler: @Sendable () -> Void = { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard let layout = self.snapshot() else { return }
        let limit = self.scrollbackLimit()
        _ = await self.persistence.captureAll(for: layout, scrollbackLimit: limit)
      }
    }
    timer.setEventHandler(handler: handler)
    timer.resume()
    self.timer = timer
  }

  /// Idempotent.
  func stop() {
    timer?.cancel()
    timer = nil
  }

  func updateEnabled(_ enabled: Bool) {
    if enabled {
      start()
    } else {
      stop()
    }
  }
}
