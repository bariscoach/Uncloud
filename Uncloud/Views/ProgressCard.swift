import SwiftUI

/// Export progress inside the Backup hero: the bar, one counts line, one status line when there is one, and the run
/// controls. The hero's title already says what is happening, so the card doesn't repeat it.
struct ProgressCard: View {
    @Environment(ExportModel.self) private var model
    @Environment(\.uncloudAccent) private var accent
    /// False when the hero above already says what's idle, so the idle status line is left out.
    var showsIdleSummary = true

    var body: some View {
        // Idle, the status line is the hero's job, not this card's.
        let hidesIdleSummary = model.phase == .idle && !showsIdleSummary

        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            // Idle, nothing is running yet, so no bar or counts: the drive row above has the figures.
            if model.phase != .idle {
                if model.phase == .preparing {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(tint)
                        .accessibilityLabel("Preparing export")
                } else {
                    ProgressView(value: model.fractionComplete)
                        .tint(tint)
                        .accessibilityLabel("Export progress")
                }
                countsLine
            }

            if !hidesIdleSummary {
                status
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if model.autoResume != nil {
                HStack {
                    Button("Resume Now") {
                        model.resumeNow()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Resume Now")
                    .accessibilityHint("Starts the export again without waiting.")
                    Button("Don’t Resume") {
                        model.cancelAutoResume()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Don’t Resume")
                    .accessibilityHint("Stops waiting. You can resume the export yourself later.")
                    Spacer()
                }
            } else if model.offersResumeExport {
                // The one obvious action for an interrupted run, with a quieter way to start over.
                HStack {
                    Button("Resume Export") {
                        model.startOrResume()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)
                    Button("Start Over") {
                        model.startNewExport()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canStart)
                    Spacer()
                }
            } else if model.canPause || model.phase == .paused || model.canCancel {
                HStack {
                    if model.canPause || model.phase == .paused {
                        Button {
                            if model.phase == .paused {
                                model.startOrResume()
                            } else {
                                model.pause()
                            }
                        } label: {
                            Label(model.phase == .paused ? "Resume" : "Pause",
                                  systemImage: model.phase == .paused ? "play.fill" : "pause.fill")
                        }
                        .disabled(model.phase != .paused && !model.canPause)
                    }
                    if model.canCancel {
                        Button {
                            model.cancel()
                        } label: {
                            Label("Cancel Export", systemImage: "xmark")
                        }
                    }
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, Tokens.Space.xs)
    }

    /// Accent while running, grey when paused, green when complete and orange when something failed.
    private var tint: Color {
        switch model.phase {
        case .paused:
            .secondary
        case .completed where model.failedCount == 0:
            .green
        case .completed, .failed:
            .orange
        default:
            accent ?? .accentColor
        }
    }

    /// "4,120 of 9,800 photos · About 2 hours left", on one line.
    private var countsLine: some View {
        Text("\(model.processedCount.formatted()) of ^[\(model.totalCount) photo](inflect: true)")
            + Text(timeRemaining.map { " · \($0)" } ?? "")
    }

    private var timeRemaining: String? {
        guard model.phase == .running, let estimate = model.estimatedTimeRemaining else { return nil }
        if estimate < .seconds(60) {
            return "Less than a minute left"
        }
        let formatted = estimate.formatted(.units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 2))
        return "About \(formatted) left"
    }

    /// "120 of 500 photos exported. Resume to pick up where it left off." The counts are left out when unknown.
    private var interruptedText: String {
        guard model.totalCount > 0 else {
            return "Resume to pick up where it left off."
        }
        let about = model.isOnDriveCountApproximate ? "About " : ""
        return "\(about)\(model.processedCount.formatted()) of \(model.totalCount.formatted()) photos exported. "
            + "Resume to pick up where it left off."
    }

    /// One status line at most. Phases the hero's title already names (preparing, running, paused, cancelling,
    /// a clean finish) have none.
    @ViewBuilder
    private var status: some View {
        switch model.phase {
        // A drive check's progress is shown by the Drive row above the card, not repeated here.
        case .idle:
            if model.hasIncompleteRun {
                Text(interruptedText)
                    .foregroundStyle(.secondary)
            } else if let newPhotos = model.newPhotosStatus {
                NewPhotosStatusLabel(status: newPhotos)
            } else if model.totalCount > 0, model.processedCount == model.totalCount {
                Label("Everything is backed up.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        case .preparing, .running, .paused, .cancelling, .completed:
            if model.phase == .completed, model.failedCount > 0 {
                Label("^[\(model.failedCount) photo](inflect: true) couldn’t be exported. Details are in History.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        case .cancelled where model.isFinishingUp:
            Label("Finishing up…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .cancelled:
            Label("You can resume it later.", systemImage: "xmark")
                .foregroundStyle(.secondary)
        case .failed:
            if let pending = model.autoResume {
                AutoResumeStatus(pending: pending, destinationName: model.destination?.displayName)
            } else if case let .failed(message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }
}

/// "Apple is limiting downloads. Resumes at 22:40 (in 14 min)." for an export that waits to resume. The countdown
/// updates every minute.
struct AutoResumeStatus: View {
    let pending: AutoResume
    let destinationName: String?

    var body: some View {
        TimelineView(.everyMinute) { context in
            let text = Self.text(for: pending, destinationName: destinationName, now: context.date)
            Label(text, systemImage: "clock")
                .foregroundStyle(.orange)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
        }
    }

    nonisolated static func text(for pending: AutoResume, destinationName: String?, now: Date) -> String {
        let reason = pending.reason.hasSuffix(".") ? pending.reason : pending.reason + "."
        if pending.isWaitingForDestination {
            let name = destinationName.map { "“\($0)”" } ?? "your backup drive"
            return "\(reason) Resumes when \(name) is connected."
        }
        let remaining = pending.resumeAt.timeIntervalSince(now)
        guard remaining > 30 else {
            return "\(reason) Resuming…"
        }
        let minutes = Int((remaining / 60).rounded(.up))
        let countdown = Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
        return "\(reason) Resumes at \(ExportModel.resumeTimeText(pending.resumeAt)) (in \(countdown))."
    }
}
