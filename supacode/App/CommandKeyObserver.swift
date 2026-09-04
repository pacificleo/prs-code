import AppKit
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// Tracks whether the user is currently holding ⌘ or ⌃ so the UI can surface shortcut hints.
@MainActor
@Observable
final class CommandKeyObserver {
  var isPressed: Bool
  /// Slot-aligned Select Tab N chords, resolved here so no tab-bar view body observes the settings file.
  private var tabSelectionHints: [String?]
  private var monitor: Any?
  private var didBecomeActiveObserver: NSObjectProtocol?
  private var didResignActiveObserver: NSObjectProtocol?
  private var holdTask: Task<Void, Never>?

  init() {
    isPressed = false
    tabSelectionHints = Self.resolvedTabSelectionHints()
    monitor = nil
    didBecomeActiveObserver = nil
    didResignActiveObserver = nil
    holdTask = nil
    configureObservers()
  }

  func tabSelectionHint(atSlot index: Int) -> String? {
    guard tabSelectionHints.indices.contains(index) else { return nil }
    return tabSelectionHints[index]
  }

  private func configureObservers() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      MainActor.assumeIsolated {
        self?.handleCommandKeyChange(isDown: Self.shouldShowShortcuts(for: event.modifierFlags))
      }
      return event
    }
    let center = NotificationCenter.default
    didBecomeActiveObserver = center.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleCommandKeyChange(isDown: Self.shouldShowShortcuts(for: NSEvent.modifierFlags))
      }
    }
    didResignActiveObserver = center.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleCommandKeyChange(isDown: false)
      }
    }
  }

  nonisolated static func shouldShowShortcuts(for modifierFlags: NSEvent.ModifierFlags) -> Bool {
    modifierFlags.contains(.command) || modifierFlags.contains(.control)
  }

  private func handleCommandKeyChange(isDown: Bool) {
    holdTask?.cancel()
    holdTask = nil

    if isDown {
      let hints = Self.resolvedTabSelectionHints()
      if hints != tabSelectionHints {
        tabSelectionHints = hints
      }
      
      holdTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        self?.isPressed = true
      }
    } else {
      isPressed = false
    }
  }

  private static func resolvedTabSelectionHints() -> [String?] {
    @Shared(.settingsFile) var settingsFile
    return AppShortcuts.tabSelectionShortcutDisplays(overrides: settingsFile.global.shortcutOverrides)
  }
}
