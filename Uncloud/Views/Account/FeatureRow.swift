import SwiftUI

/// One feature on the Welcome page: a tile, a title and one line. Read as a single element by VoiceOver.
struct FeatureRow: View {
    let title: String
    let symbol: String
    let summary: String
    /// Shown after the title, for the one feature that is free ("Free").
    var badge: String?
    @Environment(\.uncloudAccent) private var accent

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.m) {
            IconTile(symbol: symbol, tint: accent ?? .accentColor, size: Tokens.Tile.feature)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Tokens.Space.s) {
                    Text(title)
                        .font(.headline)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(accent ?? .accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((accent ?? .accentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: Tokens.Radius.s, style: .continuous))
                            .accessibilityLabel(badge.lowercased())
                    }
                }
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
