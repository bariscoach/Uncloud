import SwiftUI

/// The detail sheet for one export chain: an overview, one section per attempt, and the failed items of
/// every attempt (up to 50). Opened from a row in Export History.
struct ExportSessionDetailView: View {
    let chain: ExportHistoryChain

    @Environment(\.dismiss) private var dismiss
    @State private var showsFailures = false

    /// Failures listed in the sheet. The rest are counted, not listed.
    private static let failureLimit = 50

    var body: some View {
        VStack(spacing: 0) {
            Form {
                overview
                ForEach(Array(chain.attempts.enumerated()), id: \.element.id) { index, session in
                    attemptSection(session, number: index + 1)
                }
                if !allFailures.isEmpty {
                    failuresSection
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(Tokens.Sheet.padding)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 620)
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
            LabeledContent("Items") {
                Text(chain.countsText)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }
            if let attempts = chain.attemptsText {
                LabeledContent("Attempts") {
                    Text(attempts)
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
            LabeledContent("Outcome") {
                Text(Self.resultText(session))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(session.exportsFromPhotos ? "Exported" : "Downloaded") {
                Text(session.counts.exported.formatted()).monospacedDigit()
            }
            if session.counts.skipped > 0 {
                LabeledContent("Already there") {
                    Text(session.counts.skipped.formatted()).monospacedDigit()
                }
            }
            if session.counts.failed > 0 {
                LabeledContent("Failed") {
                    Text(session.counts.failed.formatted()).monospacedDigit()
                }
            }
            if session.counts.bytesWritten > 0 {
                LabeledContent("Size") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(session.counts.bytesWritten), countStyle: .file))
                        .monospacedDigit()
                }
            }
            LabeledContent("Source") {
                Text(session.source?.title ?? "Unknown")
            }
            LabeledContent("Layout") {
                Text(session.layout?.title ?? "Unknown")
            }
            if let check = session.driveCheck {
                LabeledContent("Drive Check") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(check.onDrive.formatted()) already on this drive · \(check.toGo.formatted()) to go")
                            .monospacedDigit()
                        Text(Self.checkProblemsText(check))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.trailing)
                }
            }
            if let continuation = session.continuation {
                LabeledContent("Continued") {
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
            LabeledContent("Uncloud Version") {
                Text(session.appVersion)
                    .monospacedDigit()
            }
        } header: {
            Text(attemptTitle(session, number: number))
        }
    }

    /// Failures from every attempt, oldest first, capped at `failureLimit`.
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
                Text("\(failures.count.formatted()) \(failures.count == 1 ? "item" : "items") couldn’t be \((chain.latest.source ?? .iCloud).copiedVerb)")
            }
        } header: {
            Text("Failed Items (\(failures.count.formatted()))")
        }
    }

    /// "Attempt 2 · Automatic resume · 15:10" for an attempt that is waiting or ran after a resume.
    private func attemptTitle(_ session: ExportSession, number: Int) -> String {
        var parts = ["Attempt \(number)", Self.triggerText(session.trigger)]
        if let resume = session.autoResume {
            parts.append(resume.resumeAt.formatted(date: .omitted, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    private static func triggerText(_ trigger: ExportSession.Trigger) -> String {
        switch trigger {
        case .manual: "Started by hand"
        case .exportAll: "Export All"
        case .automaticBackup: "Automatic backup"
        case .autoResume: "Automatic resume"
        case .resume: "Resumed by hand"
        }
    }

    /// "Completed with 3 failures", "Stopped: Apple is limiting downloads", and so on, per attempt.
    private static func resultText(_ session: ExportSession) -> String {
        switch session.result.status {
        case .running: "Running"
        case .completed: "Completed"
        case .completedWithFailures:
            "Completed with \(session.counts.failed.formatted()) \(session.counts.failed == 1 ? "failure" : "failures")"
        case .cancelled: "Cancelled"
        case .failed:
            session.result.reason.map { "Stopped: \($0)" } ?? "Stopped"
        case .interrupted: "Interrupted"
        }
    }

    private static func checkProblemsText(_ check: ExportSession.DriveCheckSummary) -> String {
        var parts: [String] = []
        if check.missing > 0 { parts.append("\(check.missing.formatted()) missing") }
        if check.damaged > 0 { parts.append("\(check.damaged.formatted()) damaged") }
        if check.setAside > 0 { parts.append("\(check.setAside.formatted()) set aside") }
        if check.untracked > 0 { parts.append("\(check.untracked.formatted()) not recorded") }
        let checked = check.mode == .full ? "Full check" : "Quick check"
        return parts.isEmpty ? "\(checked): no problems found" : "\(checked): " + parts.joined(separator: " · ")
    }

    /// How an attempt continued, in the source's own verb ("Downloaded only…" for iCloud).
    static func continuationText(_ continuation: ExportSession.Continuation, source: LibrarySource) -> String {
        switch continuation.strategy {
        case .fullWalk: "Checked the whole library"
        case .fromRank:
            if let rank = continuation.startRank {
                "Continued from item \(rank.formatted())"
            } else {
                "Continued where the last export stopped"
            }
        case .selection: "\(source.copiedVerb.prefix(1).uppercased() + source.copiedVerb.dropFirst()) only the selected items"
        }
    }
}

private extension ExportSession {
    /// Whether this attempt exported from the Photos library, which reads "Exported" rather than "Downloaded".
    var exportsFromPhotos: Bool {
        source == .photosLibrary
    }
}
