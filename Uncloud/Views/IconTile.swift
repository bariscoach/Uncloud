import SwiftUI

/// A coloured rounded square with a white symbol, as used by System Settings. Decorative: the
/// label next to it carries the meaning, so VoiceOver skips it.
struct IconTile: View {
    let symbol: String
    let tint: Color
    /// The side length of the tile, one of the `Tokens.Tile` sizes. The symbol scales with it.
    var size: CGFloat = Tokens.Tile.section
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let radius = size * Tokens.Radius.tileRatio
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(tint)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.54, weight: .semibold))
                    .foregroundStyle(.white)
            }
            // With Increase Contrast, a thin edge keeps pale tiles (mint, yellow) from melting into the background.
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.35), lineWidth: 1)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Focus-gated actions for the tile grid. Published with `.focusedValue` so the Deselect All
/// command is enabled only while the grid has keyboard focus.
struct GridSelectionActions {
    let selectAll: () -> Void
    let deselectAll: () -> Void
}

struct GridSelectionKey: FocusedValueKey {
    typealias Value = GridSelectionActions
}

extension FocusedValues {
    var gridSelection: GridSelectionActions? {
        get { self[GridSelectionKey.self] }
        set { self[GridSelectionKey.self] = newValue }
    }
}
