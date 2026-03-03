import SwiftUI

struct SettingsDetailView<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .scenePadding(.top)
      .scenePadding(.horizontal)
      .scenePadding(.bottom)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
