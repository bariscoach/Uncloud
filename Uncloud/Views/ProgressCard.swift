import SwiftUI

/// Export progress for the Backup pane: percentage, bar, counts, time left, status, and the run controls.
struct ProgressCard: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Double(Int(model.fractionComplete * 100)) / 100, format: .percent)
                .font(.title.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())

            if model.phase == .preparing {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(tint)
            } else {
                ProgressView(value: model.fractionComplete)
                    .tint(tint)
                    .accessibilityLabel("Export progress")
            }

            HStack {
                Text("\(model.processedCount.formatted()) of ^[\(model.totalCount) item](inflect: true)")
                    .monospacedDigit()
                Spacer()
                if let timeRemaining {
                    Text(timeRemaining)
                }
            }
            .foregroundStyle(.secondary)

            status
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.canPause || model.phase == .paused || model.canCancel {
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
            }
        }
        .padding(.vertical, 4)
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
            .accentColor
        }
    }

    private var timeRemaining: String? {
        guard model.phase == .running, let estimate = model.estimatedTimeRemaining else { return nil }
        if estimate < .seconds(60) {
            return "Less than a minute left"
        }
        let formatted = estimate.formatted(.units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 2))
        return "About \(formatted) left"
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .idle:
            if model.hasIncompleteRun {
                Label("A previous export didn’t finish. Resume to continue where it left off.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else if model.totalCount > 0, model.processedCount == model.totalCount {
                Label("Everything is already exported to this folder.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                Label("Ready to export.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        case .preparing:
            Label("Preparing…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .running:
            Label("Exporting…", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .paused:
            Label("Paused", systemImage: "pause.fill")
                .foregroundStyle(.secondary)
        case .cancelling:
            Label("Cancelling…", systemImage: "xmark")
                .foregroundStyle(.secondary)
        case .completed where model.failedCount > 0:
            Label("Finished, but ^[\(model.failedCount) item](inflect: true) couldn’t be exported. See Activity for details.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .completed:
            Label("Export complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .cancelled:
            Label("Export cancelled. You can resume it later.", systemImage: "xmark")
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }
}
