import SwiftUI
import AppKit

/// The real JgDo app icon (the same artwork from `AppIcon.appiconset`,
/// resolved via the app's actual icon rather than hardcoding an asset
/// name) — for JgDo's own welcome/informational screens (onboarding,
/// activation, About tab), which previously showed a generic SF Symbol
/// placeholder instead of the real logo.
struct AppLogoView: View {
    var size: CGFloat = 40

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true) // decorative; the screen's own title carries the meaning
    }
}
