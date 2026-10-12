import SwiftUI

/// A coloured rounded square with a white symbol, as used by System Settings. Decorative: the
/// label next to it carries the meaning, so VoiceOver skips it.
struct IconTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint)
            .frame(width: 28, height: 28)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
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
