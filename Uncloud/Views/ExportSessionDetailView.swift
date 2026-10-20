import SwiftUI

/// The detail sheet for one export chain: an overview, one section per run, and the photos not exported in
/// every run (up to 50). Opened from a row in History.
struct ExportSessionDetailView: View {
    let chain: ExportHistoryChain

    @Environment(\.dismiss) private var dismiss
    @State private var showsFailures = false

    /// Failures listed in the sheet. The rest are counted, not listed.
    private static let failureLimit = 50

    var body: some View {
        FormSheetScaffold("Export Details", minHeight: 480) {
            overview
            ForEach(Array(chain.attempts.enumerated()), id: \.element.id) { index, session in
                attemptSection(session, number: index + 1)
            }
            if !allFailures.isEmpty {
                failuresSection
            }
        } buttons: {
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var overview: some View {
        Section {
            LabeledContent("Result") {
                Label {
                    Text(chain.badgeText)
                } icon: {
                    Image(systemName: HistoryBadgeStyle.symbol(chain.badge))
                }
                .foregroundStyle(HistoryBadgeStyle.tint(chain.badge))
                .multilineTextAlignment(.trailing)
            }
            LabeledContent("Started") {
                Text(chain.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .monospacedDigit()
            }
            if let duration = ExportHistoryFormat.duration(chain.first.startedAt, chain.endedAt) {
                LabeledContent("Duration") {
                    Text(duration).monospacedDigit()
                }
            }
            LabeledContent("Photos") {
                Text(chain.countsText)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }
            if let runs = chain.attemptsText {
                LabeledContent("Runs") {
                    Text(runs)
                }
            }
        } header: {
            Text("Overview")
        }
    }

    private func attemptSection(_ session: ExportSession, number: Int) -> some View {
        Section {
            LabeledContent("Started") {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .monospacedDigit()
            }
            LabeledContent("Ended") {
                Text(session.endedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Still running")
                    .monospacedDigit()
            }
            LabeledContent("Result") {
                Text(Self.resultText(session))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Exported") {
                Text(session.counts.exported.formatted()).monospacedDigit()
            }
            if session.counts.skipped > 0 {
                LabeledContent("Already backed up") {
                    Text(session.counts.skipped.formatted()).monospacedDigit()
                }
            }
            if session.counts.failed > 0 {
                LabeledContent("Not exported") {
                    Text(session.counts.failed.formatted()).monospacedDigit()
                }
            }
            if session.counts.bytesWritten > 0 {
                LabeledContent("Size") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(session.counts.bytesWritten), countStyle: .file))
                        .monospacedDigit()
                }
            }
            LabeledContent("From") {
                Text(session.source?.title ?? "Unknown")
            }
            LabeledContent("Folders") {
                Text(session.layout?.title ?? "Unknown")
            }
            if let check = session.driveCheck {
                LabeledContent("Drive check") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(check.onDrive.formatted()) backed up · \(check.toGo.formatted()) to go")
                            .monospacedDigit()
                        Text(Self.checkProblemsText(check))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.trailing)
                }
            }
            if let continuation = session.continuation {
                LabeledContent("Picked up") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Self.continuationText(continuation, source: session.source ?? .iCloud))
                        if let reason = continuation.fallbackReason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.trailing)
                }
            }
            LabeledContent("App version") {
                Text(session.appVersion)
                    .monospacedDigit()
            }
        } header: {
            Text(attemptTitle(session, number: number))
        }
    }

    /// Failures from every run, oldest first, capped at `failureLimit`.
    private var allFailures: [ExportSession.Failure] {
        chain.attempts.flatMap(\.failures)
    }

    private var failuresSection: some View {
        let failures = allFailures
        return Section {
            DisclosureGroup(isExpanded: $showsFailures) {
                ForEach(Array(failures.prefix(Self.failureLimit).enumerated()), id: \.offset) { _, failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(failure.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                if failures.count > Self.failureLimit {
                    Text("And \((failures.count - Self.failureLimit).formatted()) more.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                Text("\(Plural.photos(failures.count)) couldn’t be exported")
            }
        } header: {
            Text("Not Exported (\(failures.count.formatted()))")
        }
    }

    /// "Run 2 · Resumed automatically · 15:10" for a run that is waiting or ran after a resume.
    private func attemptTitle(_ session: ExportSession, number: Int) -> String {
        var parts = ["Run \(number)", Self.triggerText(session.trigger)]
        if let resume = session.autoResume {
            parts.append(resume.resumeAt.formatted(date: .omitted, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    private static func triggerText(_ trigger: ExportSession.Trigger) -> String {
        switch trigger {
        case .manual: "Started by you"
        case .exportAll: "Export All"
        case .automaticBackup: "Automatic backup"
        case .autoResume: "Resumed automatically"
        case .resume: "Resumed by you"
        }
    }

    /// "Completed, 3 not exported", "Stopped: Apple is limiting downloads", and so on, per run.
    private static func resultText(_ session: ExportSession) -> String {
        switch session.result.status {
        case .running: "Running"
        case .completed: "Completed"
        case .completedWithFailures:
            "Completed, \(session.counts.failed.formatted()) not exported"
        case .cancelled: "Cancelled"
        case .failed:
            session.result.reason.map { "Stopped: \($0)" } ?? "Stopped"
        case .interrupted: "Didn’t finish"
        }
    }

    private static func checkProblemsText(_ check: ExportSession.DriveCheckSummary) -> String {
        var parts: [String] = []
        if check.missing > 0 { parts.append("\(check.missing.formatted()) missing") }
        if check.damaged > 0 { parts.append("\(check.damaged.formatted()) damaged") }
        if check.setAside > 0 { parts.append("\(check.setAside.formatted()) moved") }
        if check.untracked > 0 { parts.append("\(check.untracked.formatted()) unrecognized") }
        let checked = check.mode == .full ? "Every file" : "Changed folders"
        return parts.isEmpty ? "\(checked): no problems found" : "\(checked): " + parts.joined(separator: " · ")
    }

    /// How a run picked up where the last one stopped. The source doesn't change the wording: every photo is exported.
    static func continuationText(_ continuation: ExportSession.Continuation, source: LibrarySource) -> String {
        switch continuation.strategy {
        case .fullWalk: "Checked the whole library"
        case .fromRank:
            if let rank = continuation.startRank {
                "Continued from photo \(rank.formatted())"
            } else {
                "Continued where the last export stopped"
            }
        case .selection: "Exported only the selected photos"
        case .quick: "Checked for new photos only"
        }
    }
}
