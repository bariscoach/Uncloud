import OSLog
import SwiftUI

/// Export New Photos from a date range: the photos taken from one date to another, counted as the dates change.
/// The primary action opens it when the backup already has photos from this source. It shows when the last export
/// ran and the newest photo it wrote, and starts the range at that photo's date.
struct ExportRangeSheet: View {
    @Environment(ExportModel.self) private var model
    @State private var from = Date.now
    @State private var to = Date.now
    @State private var lastExport: Date?
    @State private var newestPhoto: ExportSince.ExportedPhoto?
    /// The photos already in the backup, by ID: left out of the count and the export. Nil until read.
    @State private var backedUp: Set<String>?
    @State private var counted: Counted = .counting
    /// Bumped by Try Again, which counts again.
    @State private var attempt = 0

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Uncloud", category: "export")

    /// What the count found in the range. `.found` holds the items by ID with their ranks.
    private enum Counted: Equatable {
        case counting
        /// `items` are the photos to export (not backed up yet); `backedUp` how many in the range already are.
        case found([String: Int], isAtLeast: Bool, backedUp: Int)
        /// The reason iCloud Photos couldn't be counted.
        case failed(String)
    }

    var body: some View {
        FormSheetScaffold("Export New Photos", content: {
            if lastExport != nil || newestPhoto != nil {
                Section {
                    if let lastExport {
                        LabeledContent("Last export", value: lastExport.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let newestPhoto {
                        LabeledContent("Newest photo", value: "\(newestPhoto.fileName), taken \(newestPhoto.taken.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }

            Section("Export photos taken") {
                DatePicker("From", selection: $from, in: ...to, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.stepperField)
                HStack {
                    DatePicker("To", selection: $to, in: from...Date(), displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.stepperField)
                    Button("Now") {
                        to = .now
                    }
                }
            }

            Section {
                LabeledContent("Photos", value: countText)
            } footer: {
                if case let .failed(reason) = counted {
                    Text("Couldn’t reach iCloud Photos. \(reason)")
                    Button("Try Again") {
                        attempt += 1
                    }
                }
                if let note = limitNote {
                    Text(note)
                }
            }
        }, buttons: {
            buttons
        })
        .task {
            to = .now
            from = watermarkDate ?? Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
            lastExport = await readLastExport()
            newestPhoto = await readNewestPhoto()
            let known = await readBackedUp()
            let suggested = await findSuggestion(known: known)
            if let start = newestPhoto?.taken ?? suggested {
                from = min(start, to)
            }
            // Set last, so the count starts once the range is final.
            backedUp = known
        }
        // A new range cancels the count in progress. The short pause keeps a run of stepper clicks from counting each one.
        // Waits for the backed-up photos, so the count never includes them.
        .task(id: CountRequest(from: from, to: to, isReady: backedUp != nil, attempt: attempt)) {
            counted = .counting
            guard let backedUp else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let result = await countPhotos(from: from, to: to, backedUp: backedUp)
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
                    model.exportRange(from: from, to: to, items: items)
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
            if items.isEmpty {
                guard backedUp > 0 else { return "No photos taken in this range" }
                let photos = Self.photos(backedUp)
                return "All \(photos) \(backedUp == 1 ? "is" : "are") already backed up"
            }
            let text = "\(Self.photos(items.count)) not backed up yet"
            return backedUp > 0 ? "\(text) · \(backedUp.formatted()) already backed up" : text
        }
    }

    private var limitNote: String? {
        if case .found(_, isAtLeast: true, _) = counted {
            return "Only the newest \(ExportSince.iCloudLimit.formatted()) are exported this time."
        }
        return nil
    }

    /// "1 photo" or "312 photos".
    private static func photos(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "photo" : "photos")"
    }

    /// The date the New Photos watermark recorded for the newest photo of the last complete export, if any.
    private var watermarkDate: Date? {
        guard let context = model.newPhotosContext else { return nil }
        return model.newPhotos.store.watermark(for: context)?.newestAddedDate
    }

    /// The last export's end, from the destination's session files. Nil when none, or the drive isn't connected.
    private func readLastExport() async -> Date? {
        guard let destination = model.destination?.url else { return nil }
        return await Task.detached(priority: .utility) {
            ExportSince.lastExport(in: SessionStore(destination: destination))
        }.value
    }

    /// The newest photo the backup wrote, from the manifest and the files' dates. Nil when none can be read.
    private func readNewestPhoto() async -> ExportSince.ExportedPhoto? {
        guard let destination = model.destination?.url else { return nil }
        return await Task.detached(priority: .utility) {
            ExportSince.newestExportedPhoto(in: destination)
        }.value
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

    /// The iCloud fetcher for the sheet's walks. Waits for the bridge to sign in first: the first walk after launch
    /// used to fail while the bridge wasn't ready. Nil without an Apple ID.
    private func iCloudFetcher() async throws -> ICloudBridgeFetcher? {
        guard let appleID = ICloudAccount.appleID else { return nil }
        let bridge = ICloudBridge.shared(appleID: appleID)
        try await bridge.ready()
        return ICloudBridgeFetcher(bridge: bridge)
    }

    /// The date of the newest backed-up photo, for the start of the range. Nil when none can be found.
    private func findSuggestion(known: Set<String>) async -> Date? {
        switch model.source {
        case .iCloud:
            do {
                guard let fetcher = try await iCloudFetcher() else { return nil }
                return try await ExportSince.iCloudSuggestedDate(known: known, fetcher: fetcher)
            } catch {
                guard !Task.isCancelled else { return nil }
                Self.logger.error("Export New Photos couldn't find the newest backed-up photo: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        case .photosLibrary:
            return await Task.detached(priority: .utility) {
                ExportSince.photosLibrarySuggestedDate(exported: known)
            }.value
        }
    }

    /// The photos taken in the range that aren't backed up yet. A cancelled count throws, and the caller then keeps nothing.
    private func countPhotos(from: Date, to: Date, backedUp: Set<String>) async -> Counted {
        func found(_ all: [String: Int], isAtLeast: Bool) -> Counted {
            let new = all.filter { !backedUp.contains($0.key) }
            return .found(new, isAtLeast: isAtLeast, backedUp: all.count - new.count)
        }
        switch model.source {
        case .iCloud:
            do {
                guard let fetcher = try await iCloudFetcher() else {
                    return .failed("Sign in to iCloud Photos first.")
                }
                let result = try await ExportSince.iCloudItems(takenFrom: from, to: to, fetcher: fetcher)
                return found(result.items, isAtLeast: result.isAtLeast)
            } catch {
                guard !Task.isCancelled else { return .counting }
                Self.logger.error("Export New Photos couldn't count iCloud photos: \(error.localizedDescription, privacy: .public)")
                return .failed(error.localizedDescription)
            }
        case .photosLibrary:
            let items = await Task.detached(priority: .utility) {
                ExportSince.photosLibraryItems(takenFrom: from, to: to)
            }.value
            return found(items, isAtLeast: false)
        }
    }
}

/// What the count depends on: the range, whether the backed-up photos have been read, and Try Again.
private struct CountRequest: Equatable {
    let from: Date
    let to: Date
    let isReady: Bool
    let attempt: Int
}
