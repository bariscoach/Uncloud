import OSLog
import SwiftUI

/// Export Photos by Date: the photos taken from one day to another, counted as the dates change. A preset sets the
/// dates, and editing a date switches to Custom. The export runs to the end of the To day, and photos already in the
/// backup are skipped.
struct ExportRangeSheet: View {
    @Environment(ExportModel.self) private var model
    /// Both at the start of their day. The export runs to the end of `to`.
    @State private var from: Date
    @State private var to: Date
    @State private var preset: ExportSince.DatePreset = .last30Days
    /// The photos already in the backup, by ID: left out of the count and the export. Nil until read.
    @State private var backedUp: Set<String>?
    @State private var counted: Counted = .counting
    /// Bumped by Try Again, which counts again.
    @State private var attempt = 0
    /// The account's catalog once it has been topped up and checked for this sheet (R12e); nil when it isn't trusted.
    @State private var rangeCatalog: ICloudCatalog?
    @State private var rangeCatalogChecked = false

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Uncloud", category: "export")

    /// What the count found in the range. `.found` holds the items by ID with their ranks.
    private enum Counted: Equatable {
        case counting
        /// `items` are the photos to export (not backed up yet); `backedUp` how many in the range already are.
        case found([String: Int], isAtLeast: Bool, backedUp: Int)
        /// The reason iCloud Photos couldn't be counted.
        case failed(String)
    }

    init() {
        let days = ExportSince.DatePreset.last30Days.days(now: .now) ?? (from: .now, to: .now)
        _from = State(initialValue: days.from)
        _to = State(initialValue: days.to)
    }

    var body: some View {
        FormSheetScaffold("Export Photos by Date", content: {
            Section {
                Picker("Range", selection: $preset) {
                    ForEach(ExportSince.DatePreset.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: preset) { _, new in
                    guard let days = new.days(now: .now) else { return }
                    from = days.from
                    to = days.to
                }
            }

            Section("Photos taken") {
                DatePicker("From", selection: fromBinding, in: ...to, displayedComponents: .date)
                DatePicker("To", selection: toBinding, in: from...today, displayedComponents: .date)
            }

            Section {
                LabeledContent("Photos", value: countText)
            } footer: {
                Text("Photos already in your backup are skipped.")
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
            // Waits for the backed-up photos, so the count never includes them.
            backedUp = await readBackedUp()
        }
        // A new range cancels the count in progress. The short pause keeps a run of picker clicks from counting each one.
        .task(id: CountRequest(from: from, to: to, isReady: backedUp != nil, attempt: attempt)) {
            counted = .counting
            guard let backedUp else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let result = await countPhotos(from: from, to: ExportSince.endOfDay(to), backedUp: backedUp)
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
                    model.exportRange(from: from, to: ExportSince.endOfDay(to), items: items)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canExport)
        }
    }

    /// Editing a date makes the range a custom one, so the preset selection follows the dates no longer.
    private var fromBinding: Binding<Date> {
        Binding(get: { from }, set: { from = $0; preset = .custom })
    }

    private var toBinding: Binding<Date> {
        Binding(get: { to }, set: { to = $0; preset = .custom })
    }

    /// The start of today: the latest day the range can end on.
    private var today: Date {
        Calendar.current.startOfDay(for: .now)
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
            return ExportSince.countText(toExport: items.count, backedUp: backedUp, isAtLeast: isAtLeast)
        }
    }

    private var limitNote: String? {
        if case .found(_, isAtLeast: true, _) = counted {
            return "Only the newest \(ExportSince.iCloudLimit.formatted()) are exported this time."
        }
        return nil
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
    private func iCloudFetcher() async throws -> (any ICloudPageFetching)? {
        guard let appleID = ICloudAccount.appleID else { return nil }
        let bridge = ICloudBridge.shared(appleID: appleID)
        try await bridge.ready()
        return CatalogFeedingFetcher(
            base: ICloudBridgeFetcher(bridge: bridge),
            catalog: ICloudCatalogStore.shared(appleID: appleID)
        )
    }

    /// The account's catalog, topped up and checked once per sheet (R12e), so each date change is a local query.
    /// Nil when the catalog isn't trusted or can't be checked: the walks then run as before.
    private func rangeCatalogIfTrusted() async throws -> ICloudCatalog? {
        if rangeCatalogChecked {
            return rangeCatalog
        }
        guard let appleID = ICloudAccount.appleID, let catalog = ICloudCatalogStore.shared(appleID: appleID) else {
            rangeCatalogChecked = true
            return nil
        }
        let bridge = ICloudBridge.shared(appleID: appleID)
        try await bridge.ready()
        let trusted: Bool
        do {
            trusted = try await CatalogTopUp.trustedAfterTopUp(
                fetcher: ICloudBridgeFetcher(bridge: bridge),
                catalog: catalog,
                recentlyDeleted: ICloudBridgeFetcher(bridge: bridge, album: .recentlyDeleted)
            )
        } catch {
            // A cancelled sheet stops here, and asks again next time; any other failure falls back to the walks.
            try Task.checkCancellation()
            trusted = false
        }
        rangeCatalogChecked = true
        rangeCatalog = trusted ? catalog : nil
        return rangeCatalog
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
                let result: (items: [String: Int], isAtLeast: Bool)
                if let catalog = try await rangeCatalogIfTrusted() {
                    result = try await ExportSince.iCloudItems(takenFrom: from, to: to, catalog: catalog)
                } else {
                    result = try await ExportSince.iCloudItems(takenFrom: from, to: to, fetcher: fetcher)
                }
                return found(result.items, isAtLeast: result.isAtLeast)
            } catch {
                guard !Task.isCancelled else { return .counting }
                Self.logger.error("Export Photos by Date couldn't count iCloud photos: \(error.localizedDescription, privacy: .public)")
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
