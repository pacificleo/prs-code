import SwiftUI

struct TerminalTabBackground: View {
  var isActive: Bool
  var isPressing: Bool
  var isDragging: Bool
  var isHovering: Bool

  var body: some View {
    ZStack(alignment: .top) {
      if isActive {
        TerminalTabBarColors.activeTabBackground
      } else if isHovering || isPressing || isDragging {
        TerminalTabBarColors.hoveredTabBackground
      } else {
        TerminalTabBarColors.inactiveTabBackground
      }

      if isActive {
        Rectangle()
          .fill(Color.accentColor)
          .frame(height: TerminalTabBarMetrics.activeIndicatorHeight)
      }

      if !isActive {
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          Rectangle()
            .fill(TerminalTabBarColors.separator)
            .frame(height: 1)
        }
      }
    }
  }
}
