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

/// Verify Backup, Find Duplicates and Free Up Space, as one row of bordered buttons in the Backup pane. Their
/// explanations are `.help` and accessibility hints. Free Up Space is visible for iCloud too, but disabled there:
/// `BackupTools.canOpenFreeUpSpace` already requires the Photos library.
struct BackupToolButtons: View {
    @Environment(BackupTools.self) private var tools
    @Environment(ExportModel.self) private var model

    private static let verifyHelp = "Checks that every file is intact."
    private static let duplicatesHelp = "Finds photos saved more than once."
    private static let freeUpSpaceHelp = "Removes photos from this Mac that are safely backed up."

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            Button {
                tools.showVerify()
            } label: {
                Label("Verify Backup…", systemImage: "checkmark.shield")
            }
            .disabled(!tools.canOpenVerify)
            .help(Self.verifyHelp)
            .accessibilityHint(Self.verifyHelp)

            Button {
                tools.showDuplicates()
            } label: {
                Label("Find Duplicates…", systemImage: "doc.on.doc")
            }
            .disabled(!tools.canOpenDuplicates)
            .help(Self.duplicatesHelp)
            .accessibilityHint(Self.duplicatesHelp)

            Button {
                tools.showFreeUpSpace()
            } label: {
                Label("Free Up Space…", systemImage: "externaldrive.badge.minus")
            }
            .disabled(!tools.canOpenFreeUpSpace)
            .help(freeUpSpaceHelp)
            .accessibilityHint(freeUpSpaceHelp)
        }
        .buttonStyle(.bordered)
        .padding(.vertical, Tokens.Space.xs)
    }

    private var freeUpSpaceHelp: String {
        model.source == .photosLibrary ? Self.freeUpSpaceHelp : "Only for Photos on This Mac."
    }
}
