import SwiftUI

/// The three backup tools, in the order the Tools pane shows them.
enum ToolKind: CaseIterable, Identifiable {
    case verify, duplicates, freeUpSpace

    var id: Self { self }

    /// The paid feature behind the tool: its lock and its symbol.
    var feature: PaidFeature {
        switch self {
        case .verify: .verifyBackup
        case .duplicates: .findDuplicates
        case .freeUpSpace: .freeUpSpace
        }
    }
}

/// What one tool card shows. Built by `ToolsPaneContent`, so the copy, lock and disabled reason are testable without a view.
struct ToolCardContent: Identifiable, Equatable {
    let kind: ToolKind
    let title: String
    let summary: String
    let whenToUse: String
    /// "Last check: today, 91,772 files OK." or "Not run yet.", and the like.
    let lastLine: String
    let lastIsProblem: Bool
    let isLocked: Bool
    let buttonTitle: String
    /// A locked tool's button stays enabled: it opens the paywall.
    let isEnabled: Bool
    /// Shown under the button when the tool is allowed but can't run now.
    let disabledReason: String?

    var id: ToolKind { kind }
}

/// The Tools pane's copy, locks and disabled reasons, as pure data.
enum ToolsPaneContent {
    /// The last result of each tool this session, when it has one.
    struct Results: Equatable {
        var verify: ToolResult?
        var duplicates: ToolResult?
        var freeUpSpace: ToolResult?
    }

    static let footer = "Tools work on the backup folder chosen in Export Settings."

    /// Two cards for iCloud, and a third (Free Up Space) for Photos on This Mac.
    /// - allows: whether a paid feature may be used now (the account's rule).
    /// - canOpen: whether the tools can open at all now (no sheet, no export, a usable folder).
    static func cards(
        source: LibrarySource,
        allows: (PaidFeature) -> Bool,
        canOpen: Bool,
        isExporting: Bool,
        destinationIssue: String?,
        hasPhotosAccess: Bool,
        results: Results,
        savedCheck: BackupVerification.SavedCheck,
        now: Date
    ) -> [ToolCardContent] {
        func card(_ kind: ToolKind) -> ToolCardContent {
            let isLocked = !allows(kind.feature)
            let toolCanOpen = canOpen && (kind != .freeUpSpace || hasPhotosAccess)
            let isEnabled = isLocked || toolCanOpen
            return ToolCardContent(
                kind: kind,
                title: title(kind),
                summary: summary(kind),
                whenToUse: whenToUse(kind),
                lastLine: lastLine(kind, results: results, savedCheck: savedCheck, now: now),
                lastIsProblem: lastResult(kind, results: results)?.isProblem == true,
                isLocked: isLocked,
                buttonTitle: buttonTitle(kind),
                isEnabled: isEnabled,
                disabledReason: isEnabled ? nil : disabledReason(
                    kind, isExporting: isExporting, destinationIssue: destinationIssue, hasPhotosAccess: hasPhotosAccess
                )
            )
        }

        var cards = [card(.verify), card(.duplicates)]
        if source == .photosLibrary {
            cards.append(card(.freeUpSpace))
        }
        return cards
    }

    static func title(_ kind: ToolKind) -> String {
        switch kind {
        case .verify: "Verify Backup"
        case .duplicates: "Find Duplicates"
        case .freeUpSpace: "Free Up Space"
        }
    }

    static func summary(_ kind: ToolKind) -> String {
        switch kind {
        case .verify: "Checks that every photo in your backup opens and matches the original."
        case .duplicates: "Finds photos saved more than once in your backup."
        case .freeUpSpace: "Removes photos from this Mac once they’re safely in your backup."
        }
    }

    static func whenToUse(_ kind: ToolKind) -> String {
        switch kind {
        case .verify: "Use it after moving your backup or if a drive acts up."
        case .duplicates: "Use it to win back space on your drive."
        case .freeUpSpace: "Use it when your Mac is running out of room."
        }
    }

    static func buttonTitle(_ kind: ToolKind) -> String {
        switch kind {
        case .verify: "Verify Backup…"
        case .duplicates: "Find Duplicates…"
        case .freeUpSpace: "Free Up Space…"
        }
    }

    static func disabledReason(
        _ kind: ToolKind,
        isExporting: Bool,
        destinationIssue: String?,
        hasPhotosAccess: Bool
    ) -> String? {
        if isExporting {
            return "Available when the export finishes."
        }
        if let destinationIssue {
            return destinationIssue
        }
        if kind == .freeUpSpace, !hasPhotosAccess {
            return "Needs access to Photos."
        }
        return nil
    }

    /// The line under the summary: the last result, the paused full check (Verify only), or "Not run yet.".
    static func lastLine(
        _ kind: ToolKind,
        results: Results,
        savedCheck: BackupVerification.SavedCheck,
        now: Date
    ) -> String {
        if let result = lastResult(kind, results: results) {
            let label = kind == .verify ? "Last check" : "Last run"
            return "\(label): \(day(result.date, now: now)), \(sentence(result.text))"
        }
        if kind == .verify, case let .resumable(percent, _) = savedCheck {
            return "Paused at \(percent)%. Continue it from the sheet."
        }
        return "Not run yet."
    }

    static func lastResult(_ kind: ToolKind, results: Results) -> ToolResult? {
        switch kind {
        case .verify: results.verify
        case .duplicates: results.duplicates
        case .freeUpSpace: results.freeUpSpace
        }
    }

    /// "today", "yesterday", or the date.
    static func day(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return "today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// The result text with one final period, whether or not the text already ends with one.
    private static func sentence(_ text: String) -> String {
        text.hasSuffix(".") ? text : text + "."
    }
}

/// The Tools pane: a grouped Form with one card per tool, the footer, the empty state and Show in Finder.
/// Each card's button opens the same sheet as the Backup menu, through `account.require`.
struct ToolsPane: View {
    @Environment(ExportModel.self) private var model
    @Environment(BackupTools.self) private var tools
    @Environment(AccountModel.self) private var account

    var body: some View {
        Group {
            if !model.isSourceReady {
                // Until a source is ready, Tools has nothing to act on: the same landing page as first launch.
                LandingView()
            } else if model.destination == nil {
                ContentUnavailableView {
                    Label("No Backup Folder", systemImage: "externaldrive")
                } description: {
                    Text("Choose a backup folder to check it, find duplicates and free up space.")
                } actions: {
                    Button("Choose Folder…") {
                        model.beginChoosingDestination()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ToolsForm(cards: cards, open: open)
            }
        }
        .navigationSubtitle(model.destination?.displayName ?? "")
        .toolbar {
            if model.destination != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.revealDestination()
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .help("Show in Finder")
                }
            }
        }
    }

    private var cards: [ToolCardContent] {
        ToolsPaneContent.cards(
            source: model.source,
            allows: { account.allows($0) },
            canOpen: tools.canOpenVerify,
            isExporting: model.isExporting,
            destinationIssue: model.destinationIssue,
            hasPhotosAccess: model.hasPhotosAccess,
            results: ToolsPaneContent.Results(
                verify: tools.verification.lastResult,
                duplicates: tools.duplicates.lastResult,
                freeUpSpace: tools.cleanup.lastResult
            ),
            savedCheck: tools.verification.savedCheck,
            now: .now
        )
    }

    /// A locked tool opens the paywall; once subscribed it opens its sheet as before (plan C.3).
    private func open(_ kind: ToolKind) {
        switch kind {
        case .verify:
            account.require(.verifyBackup) { tools.showVerify() }
        case .duplicates:
            account.require(.findDuplicates) { tools.showDuplicates() }
        case .freeUpSpace:
            account.require(.freeUpSpace) { tools.showFreeUpSpace() }
        }
    }
}

/// The cards in a grouped Form, one Section each. Takes its cards as data, so snapshots can render any combination.
struct ToolsForm: View {
    let cards: [ToolCardContent]
    let open: (ToolKind) -> Void

    var body: some View {
        Form {
            ForEach(cards) { card in
                Section {
                    ToolCard(content: card) {
                        open(card.kind)
                    }
                } footer: {
                    if card.id == cards.last?.id {
                        Text(ToolsPaneContent.footer)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One tool: its symbol, title, lock, what it does, when to use it, the last result, and one button.
struct ToolCard: View {
    let content: ToolCardContent
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            HStack(alignment: .top, spacing: Tokens.Space.m) {
                IconTile(symbol: content.kind.feature.symbol, tint: .accentColor, size: Tokens.Tile.feature)

                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    HStack(spacing: Tokens.Space.s) {
                        Text(content.title)
                            .font(.headline)
                        Spacer(minLength: Tokens.Space.s)
                        if content.isLocked {
                            Label {
                                Text("Plus")
                            } icon: {
                                LockGlyph()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Text(content.summary)
                    Text(content.whenToUse)
                        .foregroundStyle(.secondary)
                    lastLine
                }
            }

            HStack(spacing: Tokens.Space.s) {
                if let reason = content.disabledReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Tokens.Space.s)
                Button(action: action) {
                    Text(content.buttonTitle)
                }
                .buttonStyle(.bordered)
                .disabled(!content.isEnabled)
                .help(content.summary)
                .accessibilityValue(content.isLocked ? "Requires Uncloud Plus" : "")
            }
        }
        .padding(.vertical, Tokens.Space.xs)
        .accessibilityElement(children: .contain)
    }

    private var lastLine: some View {
        HStack(spacing: Tokens.Space.xs) {
            if content.lastIsProblem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tokens.Status.warning)
                    .accessibilityHidden(true)
            }
            Text(content.lastLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
