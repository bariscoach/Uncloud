import SwiftUI

/// One feature on the Welcome page: a tile, a title and one line. Read as a single element by VoiceOver.
struct FeatureRow: View {
    let title: String
    let symbol: String
    let summary: String
    @Environment(\.uncloudAccent) private var accent

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.m) {
            IconTile(symbol: symbol, tint: accent ?? .accentColor, size: Tokens.Tile.feature)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
