import SwiftUI

/// The landing page: shown whenever no source is ready, including the first launch. One centred
/// column: the icon, the headline, the iCloud promise, the two ways to connect, then the benefits strip.
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
                .padding(.horizontal, 16)
                .padding(.vertical, 32)
            }
            // Only scrolls when the window is too short for the column, so it stays still at the default size.
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var column: some View {
        VStack(spacing: 40) {
            VStack(spacing: 28) {
                VStack(spacing: 20) {
                    hero
                    actions
                }
                BenefitsCarousel()
            }
            footer
        }
        .frame(maxWidth: 480)
    }

    private var hero: some View {
        VStack(spacing: 8) {
            AppLogo(size: 112)
                .padding(.bottom, 12)
                .accessibilityHidden(true)
            Text("iCloud Photos, Straight to Your Drive")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Full-size originals stream from iCloud onto your external drive. Nothing is saved on your Mac first.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
        }
    }

    /// Sign In is the one primary action and the default button. The Photos library is a quiet link beneath it.
    private var actions: some View {
        VStack(spacing: 12) {
            Button("Sign In with Apple ID…") {
                model.source = .iCloud
                model.isShowingICloudSignIn = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            VStack(spacing: 4) {
                Button("Use the Photos Library on This Mac") {
                    model.source = .photosLibrary
                    model.connectPhotoLibrary()
                }
                .buttonStyle(.link)

                // Downloads in this mode can pass through the Photos library, unlike the iCloud sign-in above.
                Text("Downloads may pass through the Photos library on this Mac first.")
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
            Text("Your Apple ID password goes only to Apple.")
                .foregroundStyle(.secondary)
            Button("Learn More…") {
                model.introSheet = .gettingStarted
            }
            .buttonStyle(.link)
        }
        .font(.footnote)
    }
}
