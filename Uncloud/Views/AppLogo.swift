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

/// Timing and geometry for the animated logo. Layer positions are measured on the 1024-unit canvas
/// of the icon (scripts/make-icon.swift, variant C), with the origin at the top left.
enum AnimatedLogoTiming {
    /// The sun's centre, as a fraction of the icon's width and height. The rays turn around it.
    static let sunCenter = UnitPoint(x: 540.0 / 1024, y: 554.0 / 1024)
    /// Where the cloud starts, as a fraction of the icon size. The cloud's opaque puffs have their
    /// centre at (313, 322), so this moves that centre onto the sun's centre at (540, 554).
    static let cloudStartOffset = CGSize(width: 227.0 / 1024, height: 232.0 / 1024)

    static let revealDelay = 0.3
    static let revealDuration = 1.2
    /// The motion lines fade in once the reveal has finished.
    static let motionFadeStart = revealDelay + revealDuration
    static let motionFadeDuration = 0.4
    static let turnDuration = 60.0

    /// 0 at the start (cloud over the sun), 1 at rest. Ease-out cubic, close to `.easeOut`.
    static func progress(at t: Double) -> Double {
        let p = min(max((t - revealDelay) / revealDuration, 0), 1)
        return 1 - pow(1 - p, 3)
    }

    static func motion(at t: Double) -> Double {
        min(max((t - motionFadeStart) / motionFadeDuration, 0), 1)
    }

    /// Degrees, one full turn every `turnDuration` seconds.
    static func rotation(at t: Double) -> Double {
        (t / turnDuration).truncatingRemainder(dividingBy: 1) * 360
    }
}

/// One frame of the animated logo: the layers stacked on the icon's canvas and masked by the tile.
/// `progress` runs from 0 (cloud over the sun, dim glow) to 1 (the resting icon). `rotation` turns the
/// rays around the sun, and `motion` fades the motion lines in.
struct AnimatedAppLogoFrame: View {
    var size: CGFloat
    var progress: Double
    var rotation: Double = 0
    var motion: Double = 1

    var body: some View {
        let p = min(max(progress, 0), 1)
        let offset = AnimatedLogoTiming.cloudStartOffset
        ZStack {
            layer("LogoShadow")
            ZStack {
                layer("LogoTile")
                layer("LogoSun")
                    .opacity(0.75 + 0.25 * p)
                layer("LogoRays")
                    .rotationEffect(.degrees(rotation), anchor: AnimatedLogoTiming.sunCenter)
                layer("LogoMotion")
                    .opacity(motion)
                layer("LogoCloud")
                    .offset(x: (1 - p) * offset.width * size, y: (1 - p) * offset.height * size)
            }
            .mask { layer("LogoTile") }
        }
        .frame(width: size, height: size)
    }

    private func layer(_ name: String) -> some View {
        Image(name)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// The animated Uncloud icon: the cloud drifts off the sun, the sun brightens, the motion lines fade
/// in, and the rays turn slowly. The timeline pauses while the view is off screen. With Reduce Motion
/// on, it shows the final frame with no animation.
struct AnimatedAppLogo: View {
    var size: CGFloat = 96

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?
    @State private var isOnScreen = false

    var body: some View {
        Group {
            if reduceMotion {
                AnimatedAppLogoFrame(size: size, progress: 1, rotation: 0, motion: 1)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isOnScreen)) { context in
                    let t = max(0, context.date.timeIntervalSince(startedAt ?? context.date))
                    AnimatedAppLogoFrame(size: size,
                                         progress: AnimatedLogoTiming.progress(at: t),
                                         rotation: AnimatedLogoTiming.rotation(at: t),
                                         motion: AnimatedLogoTiming.motion(at: t))
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            startedAt = Date()
            isOnScreen = true
        }
        .onDisappear { isOnScreen = false }
        .accessibilityElement(children: .ignore)
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
/// width, with a gap of 12% of the icon. The icon is animated.
struct AppLockup: View {
    var iconSize: CGFloat

    var body: some View {
        VStack(spacing: iconSize * 0.12) {
            Wordmark(width: iconSize * 1.15)
            AnimatedAppLogo(size: iconSize)
        }
    }
}
