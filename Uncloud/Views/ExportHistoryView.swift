import SwiftUI

/// The Export History section for the Backup pane: one row per export chain, newest first. Selecting a row
/// opens `ExportSessionDetailView`. Meant to sit directly in the pane's grouped `Form`.
struct ExportHistoryView: View {
    let chains: [ExportHistoryChain]
    /// Shown instead of the rows while the destination's drive isn't connected.
    let unavailableText: String?
    /// Reveals the sessions folder in Finder.
    let showInFinder: () -> Void

    @State private var selected: ExportHistoryChain?

    var body: some View {
        Section {
            if let unavailableText {
                Label(unavailableText, systemImage: "externaldrive.badge.xmark")
                    .foregroundStyle(.secondary)
            } else if chains.isEmpty {
                Label("No exports to this drive yet.", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(chains) { chain in
                    Button {
                        selected = chain
                    } label: {
                        ExportHistoryRow(chain: chain)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows each attempt in this export.")
                }
            }
        } header: {
            SectionTitle(title: "Export History", symbol: "clock.arrow.circlepath", tint: .indigo)
        } footer: {
            if unavailableText == nil {
                Button("Show History in Finder", action: showInFinder)
                    .accessibilityHint("Opens the export history files on this drive.")
            }
        }
        .sheet(item: $selected) { chain in
            ExportSessionDetailView(chain: chain)
        }
    }
}

/// One export chain as a history row: when it started, its result, what it exported, and its tags.
private struct ExportHistoryRow: View {
    let chain: ExportHistoryChain

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ExportHistoryFormat.when(chain.startedAt).prefix(1).uppercased() + ExportHistoryFormat.when(chain.startedAt).dropFirst())
                        .font(.body.weight(.semibold))
                    Spacer()
                    if let duration = ExportHistoryFormat.duration(chain.first.startedAt, chain.endedAt) {
                        Text(duration)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Label {
                    Text(chain.badgeText)
                } icon: {
                    Image(systemName: HistoryBadgeStyle.symbol(chain.badge))
                }
                .font(.callout)
                .foregroundStyle(HistoryBadgeStyle.tint(chain.badge))

                Text(chain.countsText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                tags
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var tags: some View {
        let tagTexts = ExportHistoryFormat.tags(for: chain)
        if !tagTexts.isEmpty {
            HStack(spacing: 6) {
                ForEach(tagTexts, id: \.self) { text in
                    // A display-only tag: plain text on a quiet system fill, not a control.
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }

    private var accessibilityText: String {
        var parts = [ExportHistoryFormat.when(chain.startedAt), chain.badgeText, chain.countsText]
        if let duration = ExportHistoryFormat.duration(chain.first.startedAt, chain.endedAt) {
            parts.append("took \(duration)")
        }
        parts += ExportHistoryFormat.tags(for: chain)
        return parts.joined(separator: ", ")
    }
}

/// Symbols and colours for a chain's result, shared by the history row and the detail sheet.
enum HistoryBadgeStyle {
    static func symbol(_ badge: ExportHistoryChain.Badge) -> String {
        switch badge {
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .completedWithFailures: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .stopped: "exclamationmark.octagon.fill"
        case .interrupted: "pause.circle"
        case .resuming: "clock"
        }
    }

    static func tint(_ badge: ExportHistoryChain.Badge) -> Color {
        switch badge {
        case .running, .resuming: .accentColor
        case .completed: .green
        case .completedWithFailures, .interrupted: .orange
        case .cancelled: .secondary
        case .stopped: .red
        }
    }
}

/// Date, time and duration wording for Export History.
enum ExportHistoryFormat {
    /// "Today at 14:03", "Yesterday at 22:14", otherwise "Oct 3, 2026, 2:03 PM". Starts lowercase for the
    /// relative forms, so callers can capitalise or embed it.
    static func when(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) {
            return "today at \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "1 hr 4 min", or nil while the run has no end.
    static func duration(_ start: Date, _ end: Date?) -> String? {
        guard let end else { return nil }
        let seconds = max(0, end.timeIntervalSince(start))
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    /// "Automatic" and "Resumed 3 times" tags, and a note for a file a newer Uncloud wrote.
    static func tags(for chain: ExportHistoryChain) -> [String] {
        var tags: [String] = []
        if chain.isAutomatic {
            tags.append("Automatic")
        }
        let resumes = chain.attempts.count - 1
        if resumes > 0 {
            tags.append(resumes == 1 ? "Resumed 1 time" : "Resumed \(resumes) times")
        }
        if chain.isReadOnly {
            tags.append("From a newer Uncloud")
        }
        return tags
    }
}
