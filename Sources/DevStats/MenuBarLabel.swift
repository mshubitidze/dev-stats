import SwiftUI

/// The menu bar shows a single image or text, so the logos and numbers are rendered together
/// into one template image that macOS tints for light and dark menu bars.
struct MenuBarLabel: View {
  let model: StatsModel

  var body: some View {
    Image(nsImage: rendered)
      .accessibilityLabel(model.accessibilityLabel)
  }

  private var rendered: NSImage {
    let renderer = ImageRenderer(content: content)
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    let image = renderer.nsImage ?? NSImage()
    image.isTemplate = true
    return image
  }

  private var content: some View {
    HStack(spacing: 10) {
      item(Image(systemName: "apple.logo"), model.macMemory)
      item(Image(nsImage: Logo.ubuntu).resizable(), model.devboxMemory)
      if let claude = model.bestClaudeSession {
        item(Image(nsImage: Logo.claude).resizable(), percent(claude))
      }
    }
    .font(.system(size: 13).monospacedDigit())
    .foregroundStyle(.black)
    .fixedSize()
  }

  private func item(_ logo: Image, _ value: String) -> some View {
    HStack(spacing: 3) {
      logo.aspectRatio(contentMode: .fit).frame(width: 13, height: 13)
      Text(value)
    }
  }
}
