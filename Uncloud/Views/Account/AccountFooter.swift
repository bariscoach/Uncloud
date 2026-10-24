import SwiftUI

/// What the account row and its popover show (plan §6.2 to §6.4). Pure: every rule and string is testable without a view.
struct AccountFooterContent: Equatable {
    /// The row's first line: the Uncloud email, or the Apple ID or source title when accounts are off or signed out.
    let line1: String
    /// The row's second line: the source line, or "Loading…".
    let line2: String
    /// The warning dot: the account needs attention, or the photo source needs action.
    let needsAttention: Bool
    /// The row's accessibility value: the account, then the source, then "needs attention" when the dot shows.
    let accessibilityValue: String
    /// Whether the popover shows the Uncloud account section (hidden when accounts are off or signed out).
    let showsUncloudSection: Bool
    /// The status under "Photos From": "Connected", "Not signed in", "Ready" or "Needs access".
    let sourceStateText: String
    /// True when the status needs action, so it carries a warning symbol as well as colour.
    let sourceStateIsWarning: Bool

    static func make(
        summary: AccountSummary,
        accountMode: AccountMode,
        source: LibrarySource,
        appleID: String?,
        isSourceReady: Bool
    ) -> AccountFooterContent {
        let isLoading = summary.state == .loading
        let hasAccount = accountMode != .off && summary.hasAccount

        // iCloud needs a signed-in Apple ID; Photos on This Mac needs library access.
        let sourceIssue = source == .iCloud ? appleID == nil : !isSourceReady
        let sourceLine: String
        if source == .iCloud {
            sourceLine = appleID == nil ? "iCloud: not signed in" : LibrarySource.iCloud.title
        } else {
            sourceLine = isSourceReady ? LibrarySource.photosLibrary.title : "Photos: needs access"
        }
        let sourceStateText: String
        if source == .iCloud {
            sourceStateText = appleID == nil ? "Not signed in" : "Connected"
        } else {
            sourceStateText = isSourceReady ? "Ready" : "Needs access"
        }

        let line1: String
        if isLoading {
            line1 = "Uncloud"
        } else if hasAccount {
            line1 = summary.email ?? "Uncloud"
        } else if source == .iCloud {
            line1 = appleID ?? LibrarySource.iCloud.title
        } else {
            line1 = LibrarySource.photosLibrary.title
        }

        let line2 = isLoading ? "Loading…" : sourceLine

        let needsAttention = !isLoading && sourceIssue

        var parts: [String] = []
        if hasAccount, !summary.accessibilityValue.isEmpty {
            parts.append(summary.accessibilityValue)
        }
        if source == .iCloud {
            parts.append(appleID.map { "\(LibrarySource.iCloud.title), signed in as \($0)" } ?? "\(LibrarySource.iCloud.title), not signed in")
        } else {
            parts.append("\(LibrarySource.photosLibrary.title), \(isSourceReady ? "ready" : "needs access")")
        }
        if needsAttention, !isLoading {
            parts.append("needs attention")
        }

        return AccountFooterContent(
            line1: line1,
            line2: line2,
            needsAttention: needsAttention,
            accessibilityValue: parts.joined(separator: ", "),
            showsUncloudSection: accountMode != .off && (isLoading || hasAccount),
            sourceStateText: sourceStateText,
            sourceStateIsWarning: sourceIssue
        )
    }

}

/// The account row at the bottom of the sidebar (plan §6.2). Reads the models and passes the values to
/// `AccountFooterRowView`, which the snapshot tests render directly.
struct AccountFooterRow: View {
    @Environment(AccountModel.self) private var account
    @Environment(ExportModel.self) private var model

    var body: some View {
        AccountFooterRowView(
            summary: account.summary,
            accountMode: account.mode,
            source: model.source,
            appleID: model.iCloudAppleID,
            isSourceReady: model.isSourceReady,
            isExporting: model.isExporting || model.isEngineRunning,
            chooseSource: { model.source = $0 },
            signInToICloud: { model.isShowingICloudSignIn = true },
            signOutOfICloud: { model.isConfirmingICloudSignOut = true },
            openPrivacySettings: { model.openPhotosPrivacySettings() }
        )
    }
}

/// The account row and its popover, from values. The popover opens upwards from the row.
struct AccountFooterRowView: View {
    let summary: AccountSummary
    let accountMode: AccountMode
    let source: LibrarySource
    let appleID: String?
    let isSourceReady: Bool
    let isExporting: Bool
    let chooseSource: (LibrarySource) -> Void
    let signInToICloud: () -> Void
    let signOutOfICloud: () -> Void
    let openPrivacySettings: () -> Void
    @State private var isShowingPopover = false

    var body: some View {
        let content = AccountFooterContent.make(
            summary: summary,
            accountMode: accountMode,
            source: source,
            appleID: appleID,
            isSourceReady: isSourceReady
        )

        Button {
            isShowingPopover = true
        } label: {
            HStack(spacing: Tokens.Space.m) {
                AccountAvatar(summary: summary, size: 28, showsAttention: content.needsAttention)
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.line1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(content.line2)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: Tokens.Space.s)
                Image(systemName: "chevron.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(Tokens.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show your Uncloud account and photo source")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Accounts")
        .accessibilityValue(content.accessibilityValue)
        .accessibilityHint("Shows your Uncloud account and photo source.")
        .popover(isPresented: $isShowingPopover, arrowEdge: .top) {
            AccountFooterPopover(
                summary: summary,
                content: content,
                source: source,
                appleID: appleID,
                isSourceReady: isSourceReady,
                isExporting: isExporting,
                chooseSource: chooseSource,
                signInToICloud: {
                    isShowingPopover = false
                    signInToICloud()
                },
                signOutOfICloud: {
                    isShowingPopover = false
                    signOutOfICloud()
                },
                openPrivacySettings: {
                    isShowingPopover = false
                    openPrivacySettings()
                },
                close: { isShowingPopover = false }
            )
        }
    }
}

/// The popover: the Uncloud account section, then the photo source (plan §6.2). 300 pt wide.
struct AccountFooterPopover: View {
    let summary: AccountSummary
    let content: AccountFooterContent
    let source: LibrarySource
    let appleID: String?
    let isSourceReady: Bool
    let isExporting: Bool
    let chooseSource: (LibrarySource) -> Void
    let signInToICloud: () -> Void
    let signOutOfICloud: () -> Void
    let openPrivacySettings: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if content.showsUncloudSection {
                UncloudAccountSection(summary: summary, isExporting: isExporting, close: close)
                Divider()
            }
            PhotosSourceSection(
                source: source,
                appleID: appleID,
                isSourceReady: isSourceReady,
                isExporting: isExporting,
                stateText: content.sourceStateText,
                stateIsWarning: content.sourceStateIsWarning,
                chooseSource: chooseSource,
                signIn: signInToICloud,
                signOut: signOutOfICloud,
                openPrivacySettings: openPrivacySettings
            )
        }
        .frame(width: 300)
    }
}

/// "Photos From": the source radio buttons, and the iCloud or Photos status with its one action (plan §6.2).
struct PhotosSourceSection: View {
    let source: LibrarySource
    let appleID: String?
    let isSourceReady: Bool
    let isExporting: Bool
    let stateText: String
    let stateIsWarning: Bool
    let chooseSource: (LibrarySource) -> Void
    let signIn: () -> Void
    let signOut: () -> Void
    let openPrivacySettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Text("Photos From")
                .font(Tokens.Font.meta.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Photos From", selection: sourceSelection) {
                ForEach(LibrarySource.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(isExporting)
            .help(isExporting ? "Change this after the export finishes." : "Choose where photos come from.")

            status

            sourceAction
        }
        .padding(Tokens.Space.l)
    }

    private var sourceSelection: Binding<LibrarySource> {
        Binding(get: { source }, set: { chooseSource($0) })
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            if source == .iCloud, let appleID {
                Label {
                    Text(appleID)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "icloud")
                        .accessibilityHidden(true)
                }
                .font(.callout)
            }
            Label {
                Text(stateText)
            } icon: {
                if stateIsWarning {
                    Image(systemName: "exclamationmark.triangle")
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: source == .iCloud ? "checkmark.circle" : "photo.on.rectangle")
                        .accessibilityHidden(true)
                }
            }
            .font(.callout)
            .foregroundStyle(stateIsWarning ? Tokens.Status.warning : .secondary)
        }
    }

    @ViewBuilder
    private var sourceAction: some View {
        if source == .iCloud {
            if appleID == nil {
                Button("Sign In to iCloud…", action: signIn)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            } else {
                Button("Sign Out of iCloud…", action: signOut)
                    .buttonStyle(.link)
                    .disabled(isExporting)
                    .help(isExporting ? "Sign out after the export finishes." : "Sign out of iCloud on this Mac.")
            }
        } else if !isSourceReady {
            Button("Open Privacy Settings…", action: openPrivacySettings)
                .buttonStyle(.link)
        }
    }
}
