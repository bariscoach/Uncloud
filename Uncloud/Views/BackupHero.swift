import SwiftUI

/// What the top of the Backup pane says, worked out from the model's state. Pure, so it is unit-tested.
/// The first matching row wins, so an interrupted run shows as interrupted even when new photos are waiting.
struct BackupHeroContent: Equatable {
    enum Kind: Equatable {
        case exporting, waiting, interrupted, needsFolder, finishedWithProblems, stopped, cancelled
        case complete, newPhotos, upToDate, notBackedUp, ready
    }

    enum Tone: Equatable {
        case accent, success, warning, danger, neutral

        /// The tile and background colour. `accent` is the variant in effect, or the system accent when none is set.
        func color(accent: Color) -> Color {
            switch self {
            case .accent: accent
            case .success: Tokens.Status.success
            case .warning: Tokens.Status.warning
            case .danger: Tokens.Status.danger
            // `.secondary` isn't a fill, so the neutral tile is grey.
            case .neutral: Color.gray
            }
        }
    }

    let kind: Kind
    let symbol: String
    let title: String
    let subtitle: String?
    let tone: Tone

    /// Works out the hero from plain values, so every row of the table can be tested without a model.
    /// `notBackedUpCount` is the exact count of photos not backed up (nil when unknown or approximate); it matters only
    /// when New Photos finds nothing, since photos that were never exported are missed by it.
    static func make(
        phase: ExportModel.Phase,
        hasDestination: Bool,
        hasAutoResume: Bool,
        offersResumeExport: Bool,
        failedCount: Int,
        newPhotos: NewPhotosStatus?,
        lastExport: Date?,
        readySummary: String?,
        fraction: Double? = nil,
        resumeAt: Date? = nil,
        isWaitingForDestination: Bool = false,
        notBackedUpCount: Int? = nil,
        source: LibrarySource = .iCloud,
        now: Date
    ) -> BackupHeroContent {
        switch phase {
        case .preparing:
            return BackupHeroContent(kind: .exporting, symbol: "arrow.down.circle", title: "Getting ready…", subtitle: nil, tone: .accent)
        case .running:
            let title = fraction.map { "Exporting… \(Int($0 * 100))%" } ?? "Exporting…"
            return BackupHeroContent(kind: .exporting, symbol: "arrow.down.circle", title: title, subtitle: nil, tone: .accent)
        case .paused:
            return BackupHeroContent(kind: .exporting, symbol: "pause.circle", title: "Export paused", subtitle: nil, tone: .neutral)
        case .cancelling:
            return BackupHeroContent(kind: .exporting, symbol: "xmark.circle", title: "Stopping…", subtitle: nil, tone: .neutral)
        case .idle, .completed, .cancelled, .failed:
            break
        }

        if hasAutoResume {
            let subtitle: String?
            if isWaitingForDestination {
                subtitle = "Connect your backup drive to continue."
            } else if let resumeAt {
                subtitle = "Resumes at \(ExportModel.resumeTimeText(resumeAt))."
            } else {
                subtitle = nil
            }
            return BackupHeroContent(kind: .waiting, symbol: "clock", title: "Waiting to resume", subtitle: subtitle, tone: .warning)
        }
        if offersResumeExport {
            return BackupHeroContent(kind: .interrupted, symbol: "arrow.clockwise.circle", title: "Your last export didn’t finish", subtitle: nil, tone: .warning)
        }
        if !hasDestination {
            return BackupHeroContent(
                kind: .needsFolder, symbol: "externaldrive.badge.plus", title: "Choose a backup folder",
                subtitle: "Pick a folder on your external drive.", tone: .accent
            )
        }
        if phase == .completed, failedCount > 0 {
            return BackupHeroContent(kind: .finishedWithProblems, symbol: "exclamationmark.triangle", title: "Some photos weren’t exported", subtitle: nil, tone: .warning)
        }
        if case .failed = phase {
            return BackupHeroContent(kind: .stopped, symbol: "xmark.octagon", title: "Export stopped", subtitle: nil, tone: .danger)
        }
        if phase == .cancelled {
            return BackupHeroContent(kind: .cancelled, symbol: "xmark.circle", title: "Export cancelled", subtitle: nil, tone: .neutral)
        }
        if let newPhotos {
            let day = NewPhotosText.dayPhrase(newPhotos.since, now: now)
            if newPhotos.count > 0 || newPhotos.isAtLeast {
                let when = day.isRelative ? day.text : "on \(day.text)"
                return BackupHeroContent(
                    kind: .newPhotos, symbol: "photo.badge.plus", title: NewPhotosText.countPhrase(newPhotos),
                    subtitle: "Since your last export \(when).", tone: .accent
                )
            }
            if let notBackedUpCount, notBackedUpCount > 0 {
                let title = notBackedUpCount == 1 ? "1 photo isn’t backed up" : "\(notBackedUpCount.formatted()) photos aren’t backed up"
                let subtitle = source == .iCloud
                    ? "Older photos that weren’t exported. Check Whole Library exports them."
                    : "Older photos that weren’t exported. Export All Photos picks them up."
                return BackupHeroContent(kind: .notBackedUp, symbol: "exclamationmark.circle", title: title, subtitle: subtitle, tone: .warning)
            }
            return BackupHeroContent(kind: .upToDate, symbol: "checkmark.circle", title: "Your backup is up to date", subtitle: "Last export \(day.text).", tone: .success)
        }
        if phase == .completed {
            let subtitle = lastExport.map { "Last export \(NewPhotosText.dayPhrase($0, now: now).text)." }
            return BackupHeroContent(kind: .complete, symbol: "checkmark.circle", title: "Export complete", subtitle: subtitle, tone: .success)
        }
        return BackupHeroContent(
            kind: .ready, symbol: "arrow.down.circle", title: "Ready to export",
            subtitle: readySummary.map { $0.prefix(1).uppercased() + $0.dropFirst() }, tone: .accent
        )
    }
}

/// The tile, title and subtitle of the hero, for one content value. Separate from the controls, so every state can be
/// rendered on its own.
struct BackupHeroHeader: View {
    let content: BackupHeroContent
    @Environment(\.uncloudAccent) private var accent

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Space.m) {
            IconTile(symbol: content.symbol, tint: content.tone.color(accent: accent ?? .accentColor), size: Tokens.Tile.hero)
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text(content.title)
                    .font(Tokens.Font.heroTitle)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = content.subtitle {
                    Text(subtitle)
                        .font(Tokens.Font.heroSubtitle)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        // VoiceOver reads the title and subtitle as one heading.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The top of the Backup pane: what's going on, in one line, with the one thing to do about it.
/// Its progress card and primary button are the same controls the pane used to show further down.
struct BackupHero: View {
    @Environment(ExportModel.self) private var model
    @Environment(\.uncloudAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let total: Int?

    var body: some View {
        let content = BackupHeroContent.make(
            phase: model.phase,
            hasDestination: model.destination != nil,
            hasAutoResume: model.autoResume != nil,
            offersResumeExport: model.offersResumeExport,
            failedCount: model.failedCount,
            newPhotos: model.newPhotosStatus,
            lastExport: model.lastBackupDate,
            readySummary: model.onDriveSummaryText,
            fraction: model.fractionComplete,
            resumeAt: model.autoResume?.resumeAt,
            isWaitingForDestination: model.autoResume?.isWaitingForDestination == true,
            notBackedUpCount: model.newOnlyNotBackedUpCount,
            source: model.source,
            now: .now
        )
        let tint = content.tone.color(accent: accent ?? .accentColor)

        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            // Exactly the condition the pane used for its primary button: no button while a run is going, waiting, or
            // offering Resume Export, which the card shows instead.
            if !model.isExporting, model.autoResume == nil, !model.offersResumeExport {
                // Wide: the button sits at the trailing edge, centred on the title block. Narrow: it goes under the
                // subtitle. ViewThatFits picks the first layout that fits the row's width.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: Tokens.Space.m) {
                        BackupHeroHeader(content: content)
                        actionButton(for: content)
                    }
                    VStack(alignment: .leading, spacing: Tokens.Space.m) {
                        BackupHeroHeader(content: content)
                        actionButton(for: content)
                    }
                }
            } else {
                BackupHeroHeader(content: content)
            }

            // Idle, the card has nothing to show, so it's left out rather than leaving an empty band in the hero. An
            // interrupted run keeps it, for the counts and Resume Export.
            if model.phase != .idle || content.kind == .interrupted || model.autoResume != nil {
                ProgressCard(showsIdleSummary: content.kind == .interrupted)
            }
        }
        .padding(.vertical, Tokens.Space.s)
        .animation(Tokens.Motion.animation(reduceMotion), value: content.kind)
        .listRowBackground(heroBackground(tint))
    }

    /// The action for the hero's state. Photos that New Photos can't find are checked with Check Whole Library, as in the
    /// menu; elsewhere it's the primary action.
    @ViewBuilder
    private func actionButton(for content: BackupHeroContent) -> some View {
        if content.kind == .notBackedUp, model.source == .iCloud {
            Button("Check Whole Library") {
                model.checkWholeLibrary()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canExportAll || model.destination == nil)
        } else {
            primaryButton(isUpToDate: content.kind == .upToDate)
        }
    }

    /// The primary action. When everything is exported it stays available but stops shouting, which is the only style rule here.
    @ViewBuilder
    private func primaryButton(isUpToDate: Bool) -> some View {
        if isUpToDate {
            exportButton.buttonStyle(.bordered)
        } else {
            exportButton.buttonStyle(.borderedProminent)
        }
    }

    private var exportButton: some View {
        Button(model.primaryExportTitle(total: total)) {
            model.performPrimaryAction()
        }
        .controlSize(.large)
        .disabled(!model.primaryExportEnabled(total: total))
        .help(model.primaryExportHelp(total: total) ?? "")
        .accessibilityHint(model.primaryExportHelp(total: total) ?? "")
    }

    /// A faint wash in the tone's colour behind the hero. On macOS 26 it follows the concentric corner of the row.
    @ViewBuilder
    private func heroBackground(_ tint: Color) -> some View {
        let fill = tint.opacity(Tokens.Hero.wash)
        if #available(macOS 26, *) {
            ConcentricRectangle(corners: .concentric(minimum: .fixed(Tokens.Radius.l)), isUniform: true).fill(fill)
        } else {
            RoundedRectangle(cornerRadius: Tokens.Radius.l, style: .continuous).fill(fill)
        }
    }
}
