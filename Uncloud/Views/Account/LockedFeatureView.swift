import SwiftUI

/// What a locked pane shows in place of its content: the feature, one line about it, and the way to Uncloud Plus.
/// Choosing the button opens the paywall. Nothing here is hidden; the pane is only replaced (plan C.3, F.5b).
struct LockedFeatureView: View {
    let feature: PaidFeature
    @Environment(AccountModel.self) private var account

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(feature.title)
            } icon: {
                Image(systemName: feature.symbol)
            }
        } description: {
            VStack(spacing: Tokens.Space.s) {
                Text("\(feature.summary) It’s part of Uncloud Plus, \(PlanCopy.yearlyPricePlusTax).")
                    .fixedSize(horizontal: false, vertical: true)
                if let note = feature.lockedNote {
                    Text(note)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.center)
        } actions: {
            Button {
                account.require(feature) {}
            } label: {
                Label("Get Uncloud Plus…", systemImage: "lock.open")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small lock for a locked row, tool or segment. Decorative: the row's accessibility value says it's locked.
struct LockGlyph: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}
