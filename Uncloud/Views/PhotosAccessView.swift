import SwiftUI

/// Shown instead of the export controls when photo library access is denied or restricted.
struct PhotosAccessView: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Allow Access to Photos", systemImage: "exclamationmark.triangle")
        } description: {
            if model.authorization == .restricted {
                Text("Access to Photos is restricted on this Mac, possibly by your organization. Contact your administrator.")
            } else {
                Text("Uncloud needs access to Photos to export your library. Turn it on in System Settings › Privacy & Security › Photos.")
            }
        } actions: {
            Button("Open System Settings") {
                model.openPhotosPrivacySettings()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// Shown above the progress card when only part of the library is accessible. A plain row, not a box.
struct LimitedAccessNotice: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.m) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text("Limited Access")
                    .font(.headline)
                Text("Only the photos you’ve allowed are exported. To export everything, allow full access in System Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Tokens.Space.m)
            Button("Open System Settings") {
                model.openPhotosPrivacySettings()
            }
        }
    }
}
