import SwiftUI

/// The round account mark: the email's initial, with a warning dot when something needs attention (plan §1.1).
/// Used at 22 pt in the sidebar and 40 pt in the popover and the Account tab. Decorative: the value says it.
struct AccountAvatar: View {
    let summary: AccountSummary
    var size: CGFloat = 22
    /// Overrides `summary.needsAttention` when set. The account row uses it to add the iCloud or Photos dot (plan §6.2).
    var showsAttention: Bool? = nil
    @Environment(\.uncloudAccent) private var accent

    private var isPlus: Bool {
        summary.badge == "Uncloud Plus"
    }

    private var tint: Color {
        isPlus ? (accent ?? .accentColor) : .secondary
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(isPlus ? AnyShapeStyle((accent ?? .accentColor).opacity(0.18)) : AnyShapeStyle(.quaternary))
                .frame(width: size, height: size)
                .overlay { content }

            if showsAttention ?? summary.needsAttention {
                ZStack {
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 10, height: 10)
                    Circle()
                        .fill(Tokens.Status.warning)
                        .frame(width: 7, height: 7)
                }
                .offset(x: 2, y: -2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if summary.state == .loading {
            Image(systemName: "person.crop.circle")
                .font(.system(size: size * 0.6))
                .foregroundStyle(.secondary)
        } else if let initial = summary.initial {
            Text(initial)
                .font(.system(size: size <= 22 ? 11 : 18, weight: .semibold))
                .foregroundStyle(tint)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: size * 0.7))
                .foregroundStyle(tint)
        }
    }
}

/// The plan name as a capsule: "Free" in a quiet fill, "Uncloud Plus" in the accent. The text carries the meaning.
struct PlanBadge: View {
    let text: String
    @Environment(\.uncloudAccent) private var accent

    private var isPaid: Bool {
        text != "Free"
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isPaid ? (accent ?? .accentColor) : .secondary)
            .padding(.horizontal, Tokens.Space.s)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(isPaid ? AnyShapeStyle((accent ?? .accentColor).opacity(0.12)) : AnyShapeStyle(.quaternary))
            )
    }
}

/// A status line with its symbol and tone. Warnings carry the symbol, so colour is never the only signal.
struct PlanStatusText: View {
    let line: AccountSummary.StatusLine

    var body: some View {
        let color: Color = line.tone == .warning ? Tokens.Status.warning : .secondary
        Group {
            if let symbol = line.symbol {
                Label {
                    Text(line.text)
                } icon: {
                    Image(systemName: symbol)
                        .accessibilityHidden(true)
                }
            } else {
                Text(line.text)
            }
        }
        .font(.callout)
        .foregroundStyle(color)
        .fixedSize(horizontal: false, vertical: true)
    }
}
