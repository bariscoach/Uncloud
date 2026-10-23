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

/// Verify Backup, Find Duplicates and Free Up Space, as one row of bordered buttons in the Backup pane. Their
/// explanations are `.help` and accessibility hints. Free Up Space is visible for iCloud too, but disabled there:
/// `BackupTools.canOpenFreeUpSpace` already requires the Photos library.
struct BackupToolButtons: View {
    @Environment(BackupTools.self) private var tools
    @Environment(ExportModel.self) private var model
    @Environment(AccountModel.self) private var account

    private static let verifyHelp = "Checks that every file is intact."
    private static let duplicatesHelp = "Finds photos saved more than once."
    private static let freeUpSpaceHelp = "Removes photos from this Mac that are safely backed up."

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            // A locked tool shows a lock and opens the paywall; once subscribed it runs as before (plan C.3).
            Button {
                account.require(.verifyBackup) { tools.showVerify() }
            } label: {
                Label("Verify Backup…", systemImage: symbol(.verifyBackup, "checkmark.shield"))
            }
            .disabled(!tools.canOpenVerify)
            .help(help(Self.verifyHelp, .verifyBackup))
            .accessibilityHint(help(Self.verifyHelp, .verifyBackup))
            .accessibilityValue(lockedValue(.verifyBackup))

            Button {
                account.require(.findDuplicates) { tools.showDuplicates() }
            } label: {
                Label("Find Duplicates…", systemImage: symbol(.findDuplicates, "doc.on.doc"))
            }
            .disabled(!tools.canOpenDuplicates)
            .help(help(Self.duplicatesHelp, .findDuplicates))
            .accessibilityHint(help(Self.duplicatesHelp, .findDuplicates))
            .accessibilityValue(lockedValue(.findDuplicates))

            // Free Up Space only frees room on this Mac, so it's offered only for Photos on This Mac.
            if model.source == .photosLibrary {
                Button {
                    account.require(.freeUpSpace) { tools.showFreeUpSpace() }
                } label: {
                    Label("Free Up Space…", systemImage: symbol(.freeUpSpace, "internaldrive"))
                }
                .disabled(!tools.canOpenFreeUpSpace)
                .help(help(Self.freeUpSpaceHelp, .freeUpSpace))
                .accessibilityHint(help(Self.freeUpSpaceHelp, .freeUpSpace))
                .accessibilityValue(lockedValue(.freeUpSpace))
            }
        }
        .buttonStyle(.bordered)
        .padding(.vertical, Tokens.Space.xs)
    }

    /// The accessibility value for a tool: "Requires Uncloud Plus" while it's locked, empty once it's allowed.
    private func lockedValue(_ feature: PaidFeature) -> String {
        account.allows(feature) ? "" : "Requires Uncloud Plus"
    }

    /// The tool's own symbol, or a lock while it's locked.
    private func symbol(_ feature: PaidFeature, _ normal: String) -> String {
        account.allows(feature) ? normal : "lock"
    }

    /// The explanation, with "Part of Uncloud Plus." added while the tool is locked.
    private func help(_ text: String, _ feature: PaidFeature) -> String {
        account.allows(feature) ? text : "\(text) Part of Uncloud Plus."
    }
}
