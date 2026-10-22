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

/// The "Uncloud" wordmark (Plus Jakarta Sans ExtraBold outlines, `Wordmark` asset). It is a template image,
/// so it takes the ink colour; it is never a gradient.
struct Wordmark: View {
    var width: CGFloat

    var body: some View {
        Image("Wordmark")
            .resizable()
            .scaledToFit()
            .frame(width: width)
            .foregroundStyle(.primary)
            .accessibilityLabel("Uncloud")
    }
}

/// The lock-up from brand/README.md: the wordmark centred above the app icon. The wordmark is 1.15 × the icon
/// width, with a gap of 12% of the icon.
struct AppLockup: View {
    var iconSize: CGFloat

    var body: some View {
        VStack(spacing: iconSize * 0.12) {
            Wordmark(width: iconSize * 1.15)
            AppLogo(size: iconSize)
        }
    }
}
