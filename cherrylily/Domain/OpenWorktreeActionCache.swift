import AppKit
import Foundation

/// Process-lifetime cache for `OpenWorktreeAction` lookups that hit Launch
/// Services and the file system. Without this cache, rendering the toolbar's
/// Open menu (and other action lists) issues `NSWorkspace` calls per app per
/// SwiftUI render — observed to cost multi-second hangs under APFS contention.
enum OpenWorktreeActionCache {
  private static let lock = NSLock()
  private nonisolated(unsafe) static var installed: [String: Bool] = [:]
  private nonisolated(unsafe) static var icons: [String: OpenWorktreeAction.MenuIcon?] = [:]

  static func isInstalled(bundleIdentifier: String) -> Bool {
    lock.lock()
    if let cached = installed[bundleIdentifier] {
      lock.unlock()
      return cached
    }
    lock.unlock()
    let value = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    lock.lock()
    installed[bundleIdentifier] = value
    lock.unlock()
    return value
  }

  @MainActor
  static func menuIcon(forBundleIdentifier bundleIdentifier: String) -> OpenWorktreeAction.MenuIcon? {
    lock.lock()
    if let cached = icons[bundleIdentifier] {
      lock.unlock()
      return cached
    }
    lock.unlock()
    let value: OpenWorktreeAction.MenuIcon?
    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
      let imageData = NSWorkspace.shared.icon(forFile: appURL.path).tiffRepresentation
    {
      value = .app(imageData)
    } else {
      value = nil
    }
    lock.lock()
    icons[bundleIdentifier] = value
    lock.unlock()
    return value
  }
}
