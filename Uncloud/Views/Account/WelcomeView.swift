import SwiftUI

/// The first page a signed-out user sees: what Uncloud does, what Uncloud Plus adds, and the two ways in (plan F.1).
struct WelcomeView: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.uncloudAccent) private var accent

    var body: some View {
        AccountPage {
            VStack(spacing: 0) {
                hero
                    .padding(.bottom, Tokens.Space.xxxl)
                features
                    .padding(.bottom, Tokens.Space.xxl)
                Text(PlanCopy.welcomePlanLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, Tokens.Space.m)
                buttons
                    .padding(.bottom, Tokens.Space.xxl)
                footer
            }
            .frame(maxWidth: 640)
        }
        .background(alignment: .top) {
            // A faint wash of the accent colour at the top, so the first page has a little colour without decoration.
            LinearGradient(
                colors: [(accent ?? .accentColor).opacity(Tokens.Hero.wash), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 280)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
    }

    private var hero: some View {
        VStack(spacing: Tokens.Space.m) {
            AppLogo(size: 88)
                .accessibilityHidden(true)
            VStack(spacing: Tokens.Space.s) {
                Text("Take Your Photos Home")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("Export full-quality originals from iCloud to your own drive, then keep your backup safe, tidy and easy to browse.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
        }
    }

    /// Two columns in the order of the Export pane and the Backup tools. Export is first and carries the Free badge.
    private var features: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: Tokens.Space.xxl, alignment: .top), GridItem(.flexible(), alignment: .top)],
            alignment: .leading,
            spacing: Tokens.Space.l
        ) {
            FeatureRow(
                title: "Export",
                symbol: "photo.on.rectangle.angled",
                summary: "Copy full-quality originals from iCloud Photos or Photos on this Mac to any drive.",
                badge: "Free"
            )
            ForEach(PaidFeature.allCases) { feature in
                FeatureRow(title: feature.title, symbol: feature.symbol, summary: feature.summary)
            }
        }
    }

    /// Create Account is the one prominent action and the default button. Sign In is the bordered alternative.
    private var buttons: some View {
        VStack(spacing: Tokens.Space.m) {
            if account.error == .signedOut, let message = account.error?.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Tokens.Status.warning)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Tokens.Space.s)
            }
            HStack(spacing: Tokens.Space.m) {
                Button {
                    account.show(.signUp)
                } label: {
                    Text("Create Account")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button {
                    account.show(.signIn)
                } label: {
                    Text("Sign In")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }

    private var footer: some View {
        Label("Your photos go straight from Apple to your drive, never through Uncloud.", systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}
