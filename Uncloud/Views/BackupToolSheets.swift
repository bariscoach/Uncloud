import SwiftUI

/// The last outcome of a Verify, Find Duplicates or Free Up Space run, shown on its card in the Tools pane. Kept for
/// this session only (owner decision D4).
struct ToolResult: Equatable {
    let date: Date
    /// Without a final period: the pane adds it.
    let text: String
    let isProblem: Bool
}

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
