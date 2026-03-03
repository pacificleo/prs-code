import AppKit
import SwiftUI

enum TerminalTabBarColors {
  static var barBackground: Color {
    Color(nsColor: .windowBackgroundColor)
  }

  static var activeTabBackground: Color {
    Color(nsColor: .controlBackgroundColor)
  }

  static var hoveredTabBackground: Color {
    Color(nsColor: .controlBackgroundColor).opacity(0.5)
  }

  static var inactiveTabBackground: Color {
    .clear
  }

  static var activeText: Color {
    Color(nsColor: .labelColor)
  }

  static var inactiveText: Color {
    Color(nsColor: .secondaryLabelColor)
  }

  static var separator: Color {
    Color(nsColor: .separatorColor)
  }

  static var dropIndicator: Color {
    Color.accentColor
  }

  static var dirtyIndicator: Color {
    Color(nsColor: .labelColor).opacity(0.6)
  }
}
