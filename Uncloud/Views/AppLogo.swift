import SwiftUI
import AppKit

/// The Uncloud app icon at a given size, for in-app and landing-page use. Reads the icon from
/// the app's AppIcon asset, so it always matches the Dock icon.
struct AppLogo: View {
    var size: CGFloat = 96

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel("Uncloud")
    }
}
