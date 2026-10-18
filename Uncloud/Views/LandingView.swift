import SwiftUI

/// The landing page: shown whenever no source is ready, including the first launch. One centred
/// column: the icon, the headline, the two ways to connect, three static benefit lines, then the privacy line.
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
                highlights
            }
            footer
        }
        .frame(maxWidth: 480)
    }

    private var hero: some View {
        VStack(spacing: Tokens.Space.s) {
            AppLogo(size: 96)
                .padding(.bottom, Tokens.Space.m)
                .accessibilityHidden(true)
            Text("Your Photos, on Your Own Drive")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Full-size originals go from iCloud straight to your external drive, without filling up your Mac.")
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
                Text("Photos may download to this Mac first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Three static lines, in place of the old auto-advancing carousel. Nothing on this page moves on its own.
    private var highlights: some View {
        VStack(spacing: Tokens.Space.s) {
            Label("Full-quality originals", systemImage: "camera.aperture")
            Label("Organized by month or album", systemImage: "rectangle.3.group")
            Label("Verified, and automatic when your drive connects", systemImage: "checkmark.shield")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .contain)
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
