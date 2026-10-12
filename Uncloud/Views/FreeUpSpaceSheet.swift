import SwiftUI

/// Removes items from the photo library that are verified in the backup. Nothing happens without two confirmations.
struct FreeUpSpaceSheet: View {
    @Bindable var cleanup: LibraryCleanup
    @Environment(ExportModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    explanation
                }

                Section("Options") {
                    Picker("Only items older than", selection: $cleanup.ageLimit) {
                        ForEach(LibraryCleanup.AgeLimit.allCases) { limit in
                            Text(limit.title).tag(limit)
                        }
                    }
                    Toggle("Keep favorites", isOn: $cleanup.keepFavorites)
                    Toggle("Keep hidden items", isOn: $cleanup.keepHidden)
                }
                .disabled(cleanup.isBusy)

                if hasStatus {
                    Section {
                        status
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                buttons
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 520, height: 580)
        .interactiveDismissDisabled(cleanup.isBusy)
        .confirmationDialog(
            "Remove \(countText(eligibleCount, "item")) from your photo library?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove \(countText(eligibleCount, "Item"))", role: .destructive) {
                cleanup.removeItems()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They’ll be deleted from this Mac and, if iCloud Photos is on, from iCloud and all your devices, and items in a Shared Library are removed for everyone who shares it. You can get them back from Recently Deleted in Photos for 30 days. The copies in “\(model.destination?.displayName ?? "your backup")” are kept.")
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Removing items deletes them from the photo library on this Mac. If iCloud Photos is on, they’re also deleted from iCloud and from all your devices. Items in a Shared Library are removed for everyone who shares it.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text("Removed items stay in Recently Deleted in Photos for 30 days. Only items that are verified in this backup are offered.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                Label("Wait for the export to finish first.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else if !model.hasPhotosAccess {
                Label("Uncloud needs access to your photo library.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

        case .finding:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Looking for items…")
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
                Text("Waiting for you to confirm in the macOS alert…")
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
            Button("Remove \(countText(plan.eligible.count, "Item")) from Library…", role: .destructive) {
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
            Button("Find Items…") {
                cleanup.findItems()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!cleanup.isAllowed)
        }
    }
}

/// What Find Items found, and why other items were skipped.
private struct PlanSummary: View {
    let plan: LibraryCleanup.Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if plan.eligible.isEmpty {
                Label("No items can be removed with these options.", systemImage: "info.circle")
            } else {
                Label {
                    Text("\(countText(plan.eligible.count, "item")) (\(ByteCountFormatter.string(fromByteCount: plan.byteCount, countStyle: .file)) in the backup) \(plan.eligible.count == 1 ? "is" : "are") safely backed up and can be removed.")
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
            reasons.append("\(countText(skipped.notVerified, "item")) not verified in this backup")
        }
        if skipped.edited > 0 {
            reasons.append("\(countText(skipped.edited, "item")) changed in Photos since \(skipped.edited == 1 ? "it was" : "they were") backed up")
        }
        if skipped.favorites > 0 {
            reasons.append(countText(skipped.favorites, "favorite"))
        }
        if skipped.hidden > 0 {
            reasons.append(countText(skipped.hidden, "hidden item"))
        }
        return reasons
    }
}
