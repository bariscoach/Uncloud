import SwiftUI

/// One of the three steps, in the order people do them. Shown in Getting Started, not on the landing page.
struct HowItWorksStep: Identifiable {
    let id: Int
    let symbol: String
    let tint: Color
    let title: String
    let caption: String

    static let all: [HowItWorksStep] = [
        HowItWorksStep(
            id: 0,
            symbol: "person.crop.circle",
            tint: .blue,
            title: "Connect Your Photos",
            caption: "Sign in to iCloud Photos, or use Photos on this Mac."
        ),
        HowItWorksStep(
            id: 1,
            symbol: "folder",
            tint: .teal,
            title: "Choose a Backup Folder",
            caption: "Pick a folder on your external drive, then export."
        ),
        HowItWorksStep(
            id: 2,
            symbol: "checkmark.square",
            tint: .purple,
            title: "Choose Photos",
            caption: "Export everything, or pick the ones you want in Library."
        ),
    ]
}

/// The three steps in a row when there's room, and as rows with the icon on the left when there isn't.
struct HowItWorksSteps: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(HowItWorksStep.all) { step in
                    HowItWorksColumn(step: step)
                        .frame(width: 160)
                }
            }
            VStack(alignment: .leading, spacing: 20) {
                ForEach(HowItWorksStep.all) { step in
                    HowItWorksRow(step: step)
                }
            }
            .frame(maxWidth: 420)
        }
    }
}

/// A step as a compact column: the icon and title on one line, then the caption.
private struct HowItWorksColumn: View {
    let step: HowItWorksStep
    @Environment(\.uncloudAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconTile(symbol: step.symbol, tint: accent ?? .accentColor, size: Tokens.Tile.feature)
                Text(step.title)
                    .font(.headline)
            }
            Text(step.caption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

private struct HowItWorksRow: View {
    let step: HowItWorksStep
    @Environment(\.uncloudAccent) private var accent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: step.symbol, tint: accent ?? .accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.headline)
                Text(step.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
