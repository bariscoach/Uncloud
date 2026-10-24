import SwiftUI

/// The round account mark: the email's initial, with a warning dot when the caller says something needs attention.
/// Used at 22 pt in the sidebar and 40 pt in the popover and the Account tab. Decorative: the value says it.
struct AccountAvatar: View {
    let summary: AccountSummary
    var size: CGFloat = 22
    /// Adds the warning dot. The account row sets it when the iCloud or Photos source needs action (plan §6.2).
    var showsAttention = false
    @Environment(\.uncloudAccent) private var accent

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill((accent ?? .accentColor).opacity(0.18))
                .frame(width: size, height: size)
                .overlay { content }

            if showsAttention {
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
                .foregroundStyle(accent ?? .accentColor)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: size * 0.7))
                .foregroundStyle(accent ?? .accentColor)
        }
    }
}
