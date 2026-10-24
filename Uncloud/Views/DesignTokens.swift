import AppKit
import SwiftUI

/// The app's design tokens. Views use these instead of literal sizes, radii or hues, so one edit restyles every pane.
enum Tokens {
    /// Corner radii. One step up per nesting level: chips inside cards inside the hero.
    enum Radius {
        static let s: CGFloat = 6      // chips, small tags, IconTile up to 24 pt
        static let m: CGFloat = 10     // cards, banners, list-row backgrounds
        static let l: CGFloat = 14     // the Backup hero, floating banners
        /// IconTile corner as a fraction of its side, as in System Settings.
        static let tileRatio: CGFloat = 0.225
    }

    /// Spacing on a 4 pt grid.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
        /// Between Form sections when a custom gap is needed.
        static let section: CGFloat = 24
    }

    /// IconTile side lengths.
    enum Tile {
        static let section: CGFloat = 24
        static let feature: CGFloat = 32   // benefit rows, How It Works steps
        static let hero: CGFloat = 44
    }

    /// Sheet sizes and padding.
    enum Sheet {
        static let padding: CGFloat = 20
        static let narrow: CGFloat = 420   // Sign In, delete and recover confirmations
        static let regular: CGFloat = 520  // Check Drive, Session Detail
        static let wide: CGFloat = 560     // History
        /// The buttons along a sheet's bottom edge.
        static let footerControlSize: ControlSize = .regular
    }

    /// The Backup hero's look.
    enum Hero {
        /// How much of the status colour washes the hero's background.
        static let wash: Double = 0.06
    }

    /// Text styles. Hero titles are semibold; helper text and metadata are quieter.
    enum Font {
        static let heroTitle = SwiftUI.Font.title.weight(.semibold)
        static let heroSubtitle = SwiftUI.Font.body
        static let help = SwiftUI.Font.callout
        static let meta = SwiftUI.Font.caption
    }

    /// Motion. Every new animation goes through `animation(_:)` so Reduce Motion turns it off.
    enum Motion {
        static let standard: Animation = .smooth(duration: 0.25)

        /// The standard animation, or nil (no animation) when Reduce Motion is on.
        static func animation(_ reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : standard
        }
    }

    /// Fixed hues for places and features. Each hue means one thing everywhere. Only `library`, `iCloud` and
    /// `drive` remain, for Getting Started illustrations. Colour no longer marks sections or places.
    enum Tint {
        static let library = Color.pink        // photos (also "Photos on This Mac" in the footer)
        static let iCloud = Color.blue         // anything iCloud: footer, Delete from iCloud row
        static let drive = Color.teal          // Backup row, Save To
    }

    /// Status colours. Always paired with a symbol, never colour alone.
    enum Status {
        static let success = Color.green
        static let warning = Color.orange
        static let danger = Color.red
        static let neutral = Color.secondary
    }
}

/// The accent colour choices for comparing renders. `indigo` is the shipping AccentColor asset and the default.
/// Each variant is also the tint, so prominent buttons, progress bars, toggles and selections follow it.
enum AccentVariant: String, CaseIterable, Sendable {
    case indigo
    case sky
    case purple

    var color: Color {
        switch self {
        case .indigo: Color(red: 0.310, green: 0.208, blue: 0.788)
        case .sky: Color("AccentSky")
        case .purple: Color("AccentPurple")
        }
    }

    /// Read from `-UncloudAccentVariant sky` on the command line, or the same user default. Nil keeps the system accent.
    /// Debug and design use only. The shipped AccentColor is the sky blue chosen for the app; `indigo` names the previous colour.
    static var override: AccentVariant? {
        UserDefaults.standard.string(forKey: "UncloudAccentVariant").flatMap(AccentVariant.init(rawValue:))
    }
}

/// The accent variant in effect, for views that need the colour itself rather than the tint: a tile or a
/// status tone. Nil means no variant is set, so `Color.accentColor` applies.
private struct AccentVariantColorKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var uncloudAccent: Color? {
        get { self[AccentVariantColorKey.self] }
        set { self[AccentVariantColorKey.self] = newValue }
    }
}

extension View {
    /// Applies an accent variant as the tint and as the colour views read from the environment. Nil changes nothing.
    @ViewBuilder
    func accentVariant(_ variant: AccentVariant?) -> some View {
        if let variant {
            tint(variant.color).environment(\.uncloudAccent, variant.color)
        } else {
            self
        }
    }
}
