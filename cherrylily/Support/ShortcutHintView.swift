import SwiftUI

struct ShortcutHintView: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(.caption2)
      .foregroundStyle(color)
  }
}

/// A shortcut hint shown only while the ⌘ key is held. Reading `CommandKeyObserver`
/// inside this leaf means a ⌘ press re-renders only the hint, not the (often
/// expensive) enclosing view.
struct CommandKeyShortcutHint: View {
  let text: String?
  var color: Color = .secondary
  @Environment(CommandKeyObserver.self) private var commandKeyObserver

  var body: some View {
    if commandKeyObserver.isPressed, let text {
      ShortcutHintView(text: text, color: color)
    }
  }
}
