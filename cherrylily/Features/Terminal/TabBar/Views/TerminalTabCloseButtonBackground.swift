import SwiftUI

struct TerminalTabCloseButtonBackground: View {
  let isPressing: Bool
  let isHoveringClose: Bool

  var body: some View {
    Circle()
      .fill(backgroundColor)
  }

  private var backgroundColor: Color {
    if isPressing {
      return TerminalTabBarColors.hoveredTabBackground
    }
    if isHoveringClose {
      return TerminalTabBarColors.hoveredTabBackground
    }
    return .clear
  }
}
