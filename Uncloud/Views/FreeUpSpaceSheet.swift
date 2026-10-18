import SwiftUI

/// Removes photos from the photo library that are verified in the backup. Nothing happens without two confirmations.
struct FreeUpSpaceSheet: View {
    @Bindable var cleanup: LibraryCleanup
    @Environment(ExportModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRemoval = false

    var body: some View {
        FormSheetScaffold("Free Up Space", minHeight: 580, content: {
            Section {
                explanation
            }

            Section("Options") {
                Picker("Only photos older than", selection: $cleanup.ageLimit) {
                    ForEach(LibraryCleanup.AgeLimit.allCases) { limit in
                        Text(limit.title).tag(limit)
                    }
                }
                Toggle("Keep favorites", isOn: $cleanup.keepFavorites)
                Toggle("Keep hidden photos", isOn: $cleanup.keepHidden)
            }
            .disabled(cleanup.isBusy)

            if hasStatus {
                Section {
                    status
                }
            }
        }, buttons: {
            buttons
        })
        .interactiveDismissDisabled(cleanup.isBusy)
        .confirmationDialog(
            "Remove \(countText(eligibleCount, "Photo")) from This Mac?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove \(countText(eligibleCount, "Photo"))", role: .destructive) {
                cleanup.removeItems()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They’re deleted from Photos on this Mac and, if iCloud Photos is on, from all your devices. Shared Library photos are removed for everyone. They stay in Recently Deleted in Photos for 30 days. Your backup in “\(model.destination?.displayName ?? "your backup")” is kept.")
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Removes photos from Photos on this Mac. If iCloud Photos is on, they’re removed from all your devices, and Shared Library photos for everyone.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HelpText("Removed photos stay in Recently Deleted in Photos for 30 days. Only photos verified in your backup are offered.")
        }
    }

    private var eligibleCount: Int {
        if case let .found(plan) = cleanup.state {
            return plan.eligible.count
        }
        return 0
    }

    private var hasStatus: Bool {
        if case .ready = cleanup.state {
            return model.isExporting || !model.hasPhotosAccess
        }
        return true
    }

    @ViewBuilder
    private var status: some View {
        switch cleanup.state {
        case .ready:
            if model.isExporting {
                HelpText("Available when the export finishes.")
            } else if !model.hasPhotosAccess {
                HelpText("Uncloud needs access to Photos.")
            }

        case .finding:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Looking for photos…")
                    .foregroundStyle(.secondary)
            }

        case let .checking(done, total):
            VStack(alignment: .leading, spacing: 8) {
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                    Text("Checking \(done.formatted()) of \(total.formatted()) files…")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("Getting ready…")
                        .foregroundStyle(.secondary)
                }
            }

        case let .found(plan):
            PlanSummary(plan: plan)

        case .removing:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Confirm in the dialog to continue…")
                    .foregroundStyle(.secondary)
            }

        case let .finished(message, removedAny):
            Label(message, systemImage: removedAny ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(removedAny ? Color.green : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch cleanup.state {
        case .finding, .checking:
            Button("Cancel") {
                cleanup.cancel()
            }
            .keyboardShortcut(.cancelAction)

        case .removing:
            Button("Done") {}
                .disabled(true)

        case let .found(plan) where !plan.eligible.isEmpty:
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Remove \(countText(plan.eligible.count, "Photo"))…", role: .destructive) {
                isConfirmingRemoval = true
            }
            .disabled(!cleanup.canRemove)

        case .finished:
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

        default:
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Find Photos") {
                cleanup.findItems()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!cleanup.isAllowed)
        }
    }
}

/// What Find Photos found, and why other photos were skipped.
private struct PlanSummary: View {
    let plan: LibraryCleanup.Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if plan.eligible.isEmpty {
                HelpText("No photos match these options.")
            } else {
                Label {
                    Text("\(Plural.photos(plan.eligible.count)) (\(ByteCountFormatter.string(fromByteCount: plan.byteCount, countStyle: .file))) \(plan.eligible.count == 1 ? "is" : "are") safely backed up and can be removed.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                }
            }

            let reasons = skipReasons
            if !reasons.isEmpty {
                Text("Skipped:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(reasons, id: \.self) { reason in
                    Text("• \(reason)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var skipReasons: [String] {
        let skipped = plan.skipped
        var reasons: [String] = []
        if skipped.notVerified > 0 {
            reasons.append("\(countText(skipped.notVerified, "photo")) not verified in your backup")
        }
        if skipped.edited > 0 {
            reasons.append("\(countText(skipped.edited, "photo")) changed in Photos since \(skipped.edited == 1 ? "it was" : "they were") backed up")
        }
        if skipped.favorites > 0 {
            reasons.append(countText(skipped.favorites, "favorite"))
        }
        if skipped.hidden > 0 {
            reasons.append(countText(skipped.hidden, "hidden photo"))
        }
        return reasons
    }
}
