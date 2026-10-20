import SwiftUI

/// Export New Photos from a date: the photos added to the library since the date picked, counted as the date changes.
/// The primary action opens it when the backup already has photos from this source. The date starts at the newest
/// backed-up photo, which the sheet suggests.
struct ExportSinceSheet: View {
    @Environment(ExportModel.self) private var model
    @State private var date = Date.now
    @State private var suggested: Date?
    @State private var isFindingSuggestion = true
    @State private var counted: Counted = .counting
    /// The photos already in the backup, by ID: left out of the count and the export. Nil until read.
    @State private var backedUp: Set<String>?

    /// What the count found since the date. `.found` holds the items by ID with their ranks.
    private enum Counted: Equatable {
        case counting
        /// `items` are the photos to export (not backed up yet); `backedUp` how many since the date already are.
        case found([String: Int], isAtLeast: Bool, backedUp: Int)
        case failed
    }

    var body: some View {
        FormSheetScaffold("Export New Photos", content: {
            Section {
                DatePicker(prompt, selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.stepperField)
            } footer: {
                Text(suggestionText)
            }

            Section {
                LabeledContent("Photos", value: countText)
            } footer: {
                if let note = limitNote {
                    Text(note)
                }
            }
        }, buttons: {
            buttons
        })
        .task {
            date = watermarkDate ?? Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
            let known = await readBackedUp()
            backedUp = known
            suggested = await findSuggestion(known: known)
            isFindingSuggestion = false
            if let suggested {
                date = suggested
            }
        }
        // A new date cancels the count in progress. The short pause keeps a run of stepper clicks from counting each one.
        // Waits for the backed-up photos, so the count never includes them.
        .task(id: CountRequest(date: date, isReady: backedUp != nil)) {
            counted = .counting
            guard let backedUp else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let result = await countPhotos(since: date, backedUp: backedUp)
            guard !Task.isCancelled else { return }
            counted = result
        }
    }

    private var buttons: some View {
        Group {
            Button("Cancel") {
                model.isChoosingExportSince = false
            }
            .keyboardShortcut(.cancelAction)

            Button("Export") {
                if case let .found(items, _, _) = counted {
                    model.exportSince(date, items: items)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canExport)
        }
    }

    private var canExport: Bool {
        if case let .found(items, _, _) = counted { return !items.isEmpty }
        return false
    }

    /// Photos on This Mac have no added date, so the sheet speaks of when a photo was taken.
    private var isICloud: Bool {
        model.source == .iCloud
    }

    private var prompt: String {
        isICloud ? "Export photos added to your library since:" : "Export photos taken since:"
    }

    private var suggestionText: String {
        if isFindingSuggestion {
            return "Finding your newest backed-up photo…"
        }
        guard let suggested else {
            return "Couldn’t find a backed-up photo to suggest a date from."
        }
        let when = suggested.formatted(date: .abbreviated, time: .shortened)
        return isICloud
            ? "Suggested: your newest backed-up photo was added \(when)."
            : "Suggested: your newest backed-up photo was taken \(when)."
    }

    private var countText: String {
        switch counted {
        case .counting:
            return "Counting…"
        case .failed:
            return "Couldn’t count the photos."
        case let .found(items, isAtLeast, backedUp):
            if isAtLeast {
                return "More than \(ExportSince.iCloudLimit.formatted()) photos"
            }
            switch (items.count, backedUp) {
            case (0, 0): return "No photos since then"
            case (0, _): return "All already backed up"
            case (1, _): return "1 new photo"
            default: return "\(items.count.formatted()) new photos"
            }
        }
    }

    private var limitNote: String? {
        if case .found(_, isAtLeast: true, _) = counted {
            return "Only the newest \(ExportSince.iCloudLimit.formatted()) are exported this time."
        }
        return nil
    }

    /// The date the New Photos watermark recorded for the newest photo of the last complete export, if any.
    private var watermarkDate: Date? {
        guard let context = model.newPhotosContext else { return nil }
        return model.newPhotos.store.watermark(for: context)?.newestAddedDate
    }

    /// The photos already in the backup, from the manifest (no drive scan), read off the main actor.
    private func readBackedUp() async -> Set<String> {
        guard let destination = model.destination?.url else { return [] }
        let layout = model.layout
        let source = model.source
        return await Task.detached(priority: .utility) {
            source == .iCloud
                ? ICloudExportEngine.knownItems(in: destination, layout: layout)
                : ExportManifest.exportedIDs(in: destination)
        }.value
    }

    /// The date of the newest backed-up photo. Nil when none can be found.
    private func findSuggestion(known: Set<String>) async -> Date? {
        switch model.source {
        case .iCloud:
            guard let appleID = ICloudAccount.appleID else { return nil }
            return try? await ExportSince.iCloudSuggestedDate(
                known: known,
                fetcher: ICloudBridgeFetcher(bridge: .shared(appleID: appleID))
            )
        case .photosLibrary:
            return await Task.detached(priority: .utility) {
                ExportSince.photosLibrarySuggestedDate(exported: known)
            }.value
        }
    }

    /// The photos since `date` that aren't backed up yet. A cancelled count throws, and the caller then keeps nothing.
    private func countPhotos(since date: Date, backedUp: Set<String>) async -> Counted {
        func found(_ all: [String: Int], isAtLeast: Bool) -> Counted {
            let new = all.filter { !backedUp.contains($0.key) }
            return .found(new, isAtLeast: isAtLeast, backedUp: all.count - new.count)
        }
        switch model.source {
        case .iCloud:
            guard let appleID = ICloudAccount.appleID else { return .failed }
            do {
                let result = try await ExportSince.iCloudItems(
                    since: date,
                    fetcher: ICloudBridgeFetcher(bridge: .shared(appleID: appleID))
                )
                return found(result.items, isAtLeast: result.isAtLeast)
            } catch {
                return .failed
            }
        case .photosLibrary:
            let items = await Task.detached(priority: .utility) {
                ExportSince.photosLibraryItems(since: date)
            }.value
            return found(items, isAtLeast: false)
        }
    }
}

/// What the count depends on: the date, and whether the backed-up photos have been read.
private struct CountRequest: Equatable {
    let date: Date
    let isReady: Bool
}
