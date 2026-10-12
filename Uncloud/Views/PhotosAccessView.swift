import SwiftUI

/// Shown instead of the export controls when photo library access is denied or restricted.
struct PhotosAccessView: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Photo Library Access Needed", systemImage: "exclamationmark.triangle")
        } description: {
            if model.authorization == .restricted {
                Text("Access to the photo library is restricted on this Mac, possibly by a configuration profile. Contact your administrator.")
            } else {
                Text("Uncloud needs permission to read your photo library. Turn it on in System Settings under Privacy & Security.")
            }
        } actions: {
            Button("Open Settings") {
                model.openPhotosPrivacySettings()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// Shown above the progress card when only part of the library is accessible.
struct LimitedAccessNotice: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Limited Access")
                        .font(.headline)
                    Text("Only the items you’ve allowed will be exported. To export your whole library, allow full access in System Settings.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Open Settings") {
                    model.openPhotosPrivacySettings()
                }
            }
            .padding(4)
        }
    }
}
