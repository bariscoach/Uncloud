import SwiftUI

/// The first-run welcome, shown once as a sheet over the main window.
struct WelcomeView: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 72, height: 72)
                .overlay {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Welcome to Uncloud")
                    .font(.title.weight(.semibold))
                Text("Copy your whole photo library to any folder or drive.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Get Started") {
                model.introSheet = nil
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 380)
    }
}
