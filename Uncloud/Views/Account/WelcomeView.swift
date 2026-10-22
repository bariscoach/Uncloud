import SwiftUI

/// The first page a signed-out user sees: what Uncloud does, what Uncloud Plus adds, and the one way in (plan F.1).
struct WelcomeView: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.uncloudAccent) private var accent

    var body: some View {
        AccountPage {
            VStack(spacing: 0) {
                hero
                    .padding(.bottom, account.notice == .accountDeleted ? Tokens.Space.m : Tokens.Space.xxxl)
                if account.notice == .accountDeleted {
                    Text("Your Uncloud account was deleted.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, Tokens.Space.xxxl)
                }
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
            AppLockup(iconSize: 88)
                .accessibilityHidden(true)
            VStack(spacing: Tokens.Space.s) {
                Text("Take Your Photos Home")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("Export full-quality originals from iCloud Photos to your own drive, without filling up your Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
        }
    }

    /// Three rows: the free feature first, then the two Plus groups.
    private var features: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            FeatureRow(
                title: "Export",
                symbol: "photo.on.rectangle.angled",
                summary: "Full-quality originals from iCloud Photos or Photos on this Mac, to any drive.",
                badge: "Free"
            )
            FeatureRow(
                title: "Stay Up to Date",
                symbol: "clock.arrow.circlepath",
                summary: "Automatic backups, and reminders when new photos are waiting.",
                badge: "Plus"
            )
            FeatureRow(
                title: "Keep It Tidy",
                symbol: "sparkles",
                summary: "Browse, verify and find duplicates in your backup. Free up space on this Mac and in iCloud.",
                badge: "Plus"
            )
        }
        .frame(maxWidth: 440)
    }

    /// One button names the method and is the default, so Return starts it. A caption says what happens next.
    private var buttons: some View {
        VStack(spacing: Tokens.Space.m) {
            if account.error == .signedOut, let message = account.error?.message {
                Label {
                    Text(message)
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Tokens.Status.warning)
                }
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Tokens.Space.s)
            }
            Button {
                account.show(.signUp)
            } label: {
                Text("Continue with Email")
                    .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Text("New or returning, Uncloud emails you a sign-in code. No password needed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var footer: some View {
        Label("Your photos go straight from Apple to your drive, never through Uncloud.", systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}
