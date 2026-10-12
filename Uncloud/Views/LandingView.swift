import SwiftUI

/// The landing page: shown whenever no source is ready, including the first launch. It says what
/// Uncloud does, shows the three steps, and offers the two ways to connect the photos.
struct LandingView: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                hero

                VStack(spacing: 20) {
                    Text("How It Works")
                        .font(.headline)
                    HowItWorksSteps()
                    Text("Uncloud also resumes after interruptions, verifies your backup, and can back up automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                connectChoices

                PrivacyNote(showsLearnMore: true)
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 16)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            AppLogo(size: 112)
                .accessibilityHidden(true)
            Text("Welcome to Uncloud")
                .font(.largeTitle)
                .multilineTextAlignment(.center)
            Text("Copy your photos and videos out of the cloud, onto a drive you own.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// The two ways to connect. Sign In is the primary action and the default button of the page.
    private var connectChoices: some View {
        VStack(spacing: 16) {
            Text("Connect Your Photos")
                .font(.headline)

            VStack(spacing: 8) {
                Button("Sign In with Apple ID…") {
                    model.source = .iCloud
                    model.isShowingICloudSignIn = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Text("For your iCloud Photos, with originals, Live Photos and RAW files. Recommended.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                Button("Use the Photos Library on This Mac") {
                    model.source = .photosLibrary
                    model.connectPhotoLibrary()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Text("For photos already in the Photos app on this Mac. Adds place folders and Free Up Space.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 440)
    }
}

/// One of the three steps, in the order people do them.
struct HowItWorksStep: Identifiable {
    let id: Int
    let symbol: String
    let tint: Color
    let title: String
    let caption: String

    static let all: [HowItWorksStep] = [
        HowItWorksStep(
            id: 0,
            symbol: "person.crop.circle",
            tint: .blue,
            title: "Sign In",
            caption: "Sign in with your Apple ID, or use the Photos library on this Mac."
        ),
        HowItWorksStep(
            id: 1,
            symbol: "checkmark.square",
            tint: .purple,
            title: "Choose What to Export",
            caption: "Export everything, or select the photos and videos you want in the grid."
        ),
        HowItWorksStep(
            id: 2,
            symbol: "folder",
            tint: .teal,
            title: "Pick a Folder and Export",
            caption: "Choose a folder or drive. Uncloud copies your photos there."
        ),
    ]
}

/// The three steps in a row when there's room, and as rows with the icon on the left when there isn't.
struct HowItWorksSteps: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(HowItWorksStep.all) { step in
                    HowItWorksColumn(step: step)
                        .frame(width: 160)
                }
            }
            VStack(alignment: .leading, spacing: 20) {
                ForEach(HowItWorksStep.all) { step in
                    HowItWorksRow(step: step)
                }
            }
            .frame(maxWidth: 420)
        }
    }
}

private struct HowItWorksColumn: View {
    let step: HowItWorksStep

    var body: some View {
        VStack(spacing: 10) {
            IconTile(symbol: step.symbol, tint: step.tint, size: 44)
            Text(step.title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(step.caption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}

private struct HowItWorksRow: View {
    let step: HowItWorksStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: step.symbol, tint: step.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.headline)
                Text(step.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The privacy reassurance. Used on the landing page and in Getting Started.
struct PrivacyNote: View {
    @Environment(ExportModel.self) private var model
    var showsLearnMore: Bool

    var body: some View {
        VStack(spacing: 8) {
            Label {
                Text("Your photos go straight to your own folder or drive. Your Apple ID password goes only to Apple, through icloudpd, the open-source tool inside Uncloud, and is kept in your Keychain only if you choose.")
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 560)

            if showsLearnMore {
                Button("Learn More…") {
                    model.introSheet = .gettingStarted
                }
                .buttonStyle(.link)
            }
        }
    }
}
