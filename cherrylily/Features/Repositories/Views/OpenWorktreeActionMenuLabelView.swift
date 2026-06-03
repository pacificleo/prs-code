import AppKit
import SwiftUI

struct OpenWorktreeActionMenuLabelView: View {
  let action: OpenWorktreeAction
  let shortcutHint: String?

  // Decoding + lockFocus/draw resizing an NSImage is expensive to do on every
  // toolbar render. Memoize by the icon's raw bytes (content-addressed) so a
  // given app icon is decoded and rasterized once.
  private static let iconCache = NSCache<NSData, NSImage>()
  private static let iconSize = CGSize(width: 16, height: 16)

  private static func resizedIcon(for imageData: Data) -> NSImage {
    let key = imageData as NSData
    if let cached = iconCache.object(forKey: key) {
      return cached
    }
    let image = NSImage(data: imageData) ?? NSImage()
    let newImage = NSImage(size: iconSize)
    newImage.lockFocus()
    image.draw(
      in: NSRect(origin: .zero, size: iconSize),
      from: NSRect(origin: .zero, size: image.size),
      operation: .sourceOver,
      fraction: 1.0
    )
    newImage.unlockFocus()
    iconCache.setObject(newImage, forKey: key)
    return newImage
  }

  var body: some View {
    HStack(spacing: 6) {
      if let icon = action.menuIcon {
        switch icon {
        case .app(let imageData):
          Image(nsImage: Self.resizedIcon(for: imageData))
            .renderingMode(.original)
            .accessibilityHidden(true)
        case .symbol(let name):
          Image(systemName: name)
            .foregroundStyle(.primary)
            .accessibilityHidden(true)
        }
      }
      if let shortcutHint {
        HStack(spacing: 2) {
          Text(action.labelTitle)
            .font(.body)
          Text("(\(shortcutHint))")
            .font(.body)
            .foregroundStyle(.secondary)
        }
      } else {
        Text(action.labelTitle)
          .font(.body)
      }
    }
  }
}
