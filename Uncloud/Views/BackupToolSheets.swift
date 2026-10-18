import SwiftUI

/// Presents the Verify Backup, Find Duplicates and Free Up Space sheets from the window's root, so the menu works on every screen.
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
                    case .duplicates:
                        FindDuplicatesSheet(cleanup: tools.duplicates)
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

/// Verify Backup, Find Duplicates and Free Up Space, as rows in the Backup pane. Free Up Space exists only for the Photos library.
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

            Button {
                tools.showDuplicates()
            } label: {
                Label("Find Duplicates…", systemImage: "doc.on.doc")
            }
            .disabled(!tools.canOpenDuplicates)
            Text("Finds items saved more than once in your folder, so you can move the extra copies to the Trash.")
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
