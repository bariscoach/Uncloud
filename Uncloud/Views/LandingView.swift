import SwiftUI

/// The landing page: shown whenever no source is ready, including the first launch, and in the Backup pane until
/// one is. One centred column: the icon, the task headline, the two ways to connect, then the privacy line.
struct LandingView: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    column
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                .padding(.horizontal, Tokens.Space.l)
                .padding(.vertical, Tokens.Space.xxxl)
            }
            // Only scrolls when the window is too short for the column, so it stays still at the default size.
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var column: some View {
        VStack(spacing: Tokens.Space.xxxl) {
            VStack(spacing: Tokens.Space.xxl) {
                VStack(spacing: Tokens.Space.xl) {
                    hero
                    actions
                }
            }
            footer
        }
        .frame(maxWidth: 480)
    }

    private var hero: some View {
        VStack(spacing: Tokens.Space.s) {
            AppLogo(size: 64)
                .padding(.bottom, Tokens.Space.m)
                .accessibilityHidden(true)
            Text("Connect Your Photos")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Choose where Uncloud exports from. You can change it later in the File menu.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
        }
    }

    /// Sign In is the one primary action and the default button. The Photos library is a quiet link beneath it.
    private var actions: some View {
        VStack(spacing: Tokens.Space.m) {
            Button("Sign In to iCloud…") {
                model.source = .iCloud
                model.isShowingICloudSignIn = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            VStack(spacing: Tokens.Space.xs) {
                Button("Use Photos on This Mac") {
                    model.source = .photosLibrary
                    model.connectPhotoLibrary()
                }
                .buttonStyle(.link)

                // Downloads in this mode can pass through the Photos library, unlike the iCloud sign-in above.
                Text("Photos stored only in iCloud may download to this Mac first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One quiet line on privacy, with a way into Getting Started for the full story.
    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .accessibilityHidden(true)
            Text("Your password goes only to Apple.")
                .foregroundStyle(.secondary)
            Button("How It Works") {
                model.introSheet = .gettingStarted
            }
            .buttonStyle(.link)
        }
        .font(.footnote)
    }
}
