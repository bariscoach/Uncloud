import SwiftUI

/// One of the five reasons to use Uncloud. Written as what the app does, not as a comparison with other services.
/// Shown as a list in Getting Started. The landing page doesn't show them.
struct Benefit: Identifiable {
    let title: String
    /// The full sentence, shown in Getting Started.
    let caption: String
    let symbol: String
    let tint: Color

    var id: String { title }

    static let all: [Benefit] = [
        Benefit(
            title: "Full-Quality Originals",
            caption: "Copies your originals, edits, Live Photos and RAW files, exactly as they are.",
            symbol: "camera.aperture",
            tint: .orange
        ),
        Benefit(
            title: "Organized Your Way",
            caption: "Sorts into folders by month or by album. With Photos on this Mac, by place too.",
            symbol: "rectangle.3.group",
            tint: .indigo
        ),
        Benefit(
            title: "Built for Huge Libraries",
            caption: "Handles tens of thousands of photos. Pause, resume, and next time export only what’s new.",
            symbol: "arrow.triangle.2.circlepath",
            tint: .pink
        ),
        Benefit(
            title: "Verified and Automatic",
            caption: "Records every file so Verify Backup can prove it’s intact, and exports on its own when your drive connects.",
            symbol: "checkmark.shield",
            tint: .green
        ),
        Benefit(
            title: "No Detour Through Your Mac",
            caption: "With iCloud Photos, photos stream directly onto your external drive. Nothing is saved on your Mac first.",
            symbol: "externaldrive.fill",
            tint: .teal
        ),
    ]
}

/// One benefit as an icon with its title and caption, for the Getting Started list.
struct BenefitRow: View {
    let benefit: Benefit
    @Environment(\.uncloudAccent) private var accent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: benefit.symbol, tint: accent ?? .accentColor, size: Tokens.Tile.feature)
            VStack(alignment: .leading, spacing: 2) {
                Text(benefit.title)
                    .font(.headline)
                Text(benefit.caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The privacy reassurance. Used in Getting Started.
struct PrivacyNote: View {
    @Environment(ExportModel.self) private var model
    var showsLearnMore: Bool

    var body: some View {
        VStack(spacing: 8) {
            Label {
                Text("Your photos go straight to your own drive. Your password goes only to Apple and is saved in your keychain only if you choose. Uncloud uses icloudpd, an open-source tool, to talk to iCloud.")
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 560)

            if showsLearnMore {
                Button("How It Works") {
                    model.introSheet = .gettingStarted
                }
                .buttonStyle(.link)
            }
        }
    }
}
