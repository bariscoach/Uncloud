import SwiftUI

/// Presents the Verify Backup and Free Up Space sheets from the window's root, so the menu works on every screen.
struct BackupToolSheets: ViewModifier {
    @Environment(BackupTools.self) private var tools
    @Environment(ExportModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var tools = tools

        content
            .sheet(item: $tools.sheet, onDismiss: tools.sheetDismissed) { sheet in
                Group {
                    switch sheet {
                    case .verify:
                        VerifyBackupSheet(verification: tools.verification)
                    case .freeUpSpace:
                        FreeUpSpaceSheet(cleanup: tools.cleanup)
                    }
                }
                .environment(model)
            }
    }
}

extension View {
    func backupToolSheets() -> some View {
        modifier(BackupToolSheets())
    }
}

/// Verify Backup and Free Up Space, as rows in the Backup pane. Free Up Space exists only for the Photos library.
struct BackupToolButtons: View {
    @Environment(BackupTools.self) private var tools
    @Environment(ExportModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                tools.showVerify()
            } label: {
                Label("Verify Backup…", systemImage: "checkmark.shield")
            }
            .disabled(!tools.canOpenVerify)
            Text("Checks every file in your folder against the checksum saved when it was exported.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.source == .photosLibrary {
                Button {
                    tools.showFreeUpSpace()
                } label: {
                    Label("Free Up Space…", systemImage: "externaldrive.badge.minus")
                }
                .disabled(!tools.canOpenFreeUpSpace)
                Text("Removes items from the Photos library on this Mac, only after they are verified in your folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .padding(.vertical, 4)
    }
}
