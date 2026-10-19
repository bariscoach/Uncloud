import SwiftUI

/// One renewal choice on the paywall: a full-width radio row with its price and one line of caption (plan §5.2).
/// Reads as one button to VoiceOver, with the selected state as a trait.
struct RenewalOptionRow: View {
    let title: String
    let price: String
    let caption: String
    /// The whole label for VoiceOver, so the choice and its price are heard together.
    let spokenLabel: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.uncloudAccent) private var accent
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Tokens.Space.m) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? (accent ?? .accentColor) : .secondary)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title)
                            .font(.headline)
                        Spacer(minLength: Tokens.Space.s)
                        Text(price)
                            .font(.body.monospacedDigit())
                    }
                    Text(caption)
                        .font(Tokens.Font.meta)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Tokens.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.m, style: .continuous))
            .background(
                (isSelected ? (accent ?? .accentColor).opacity(0.06) : Color.clear),
                in: RoundedRectangle(cornerRadius: Tokens.Radius.m, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.m, style: .continuous)
                    .strokeBorder(
                        isSelected ? (accent ?? .accentColor) : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help(caption)
    }
}
