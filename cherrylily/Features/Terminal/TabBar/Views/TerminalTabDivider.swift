import SwiftUI

struct TerminalTabDivider: View {
  var body: some View {
    Rectangle()
      .frame(width: 1)
      .frame(height: TerminalTabBarMetrics.tabHeight)
      .foregroundStyle(TerminalTabBarColors.separator)
  }
}
