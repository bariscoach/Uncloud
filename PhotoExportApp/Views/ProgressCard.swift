import SwiftUI

struct ProgressCard: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        GroupBox {
            VStack(spacing: 12) {
                Text(Double(Int(model.fractionComplete * 100)) / 100, format: .percent)
                    .font(.largeTitle.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                if model.phase == .preparing {
                    ProgressView()
                        .progressViewStyle(.linear)
                } else {
                    ProgressView(value: model.fractionComplete)
                }

                HStack {
                    Text("\(model.processedCount) of ^[\(model.totalCount) item](inflect: true)")
                        .monospacedDigit()
                    Spacer()
                    if let timeRemaining {
                        Text(timeRemaining)
                    }
                }
                .font(.body)
                .foregroundStyle(.secondary)

                status
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
        }
        .accessibilityElement(children: .combine)
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
            if model.authorization == .notDetermined {
                Label("You’ll be asked for access to your photo library when you start.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else if model.hasIncompleteRun {
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
