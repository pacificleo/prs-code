import SwiftUI

struct WindowCommands: Commands {
  let ghosttyShortcuts: GhosttyShortcutManager
  @FocusedValue(\.closeSurfaceAction) private var closeSurfaceAction

  var body: some Commands {
    let closeSurfaceHotkey = ghosttyShortcuts.keyboardShortcut(for: "close_surface")
    let isCloseSurfaceOverlapping = closeSurfaceHotkey?.key == "w" && closeSurfaceHotkey?.modifiers == .command

    CommandGroup(replacing: .saveItem) {
      Button("Close Window", systemImage: "xmark") {
        NSApplication.shared.keyWindow?.performClose(nil)
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: !isCloseSurfaceOverlapping || closeSurfaceAction == nil ? .init("w") : nil
        )
      )
    }
  }
}

struct KeyboardShortcutModifier: ViewModifier {
  let shortcut: KeyboardShortcut?

  func body(content: Content) -> some View {
    if let shortcut {
      content.keyboardShortcut(shortcut)
    } else {
      content
    }
  }
}
