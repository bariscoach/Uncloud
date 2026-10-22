import Foundation
import Observation

/// Looks up the place at coordinates. `PlaceResolver` is the app's; tests pass a fake.
protocol PlaceNaming: Sendable {
    func placeNamed(latitude: Double, longitude: Double) async throws -> PlaceResolver.Place
}

extension PlaceResolver: PlaceNaming {
    func placeNamed(latitude: Double, longitude: Double) async throws -> PlaceResolver.Place {
        try await place(latitude: latitude, longitude: longitude, onWait: { _ in })
    }
}

/// The photos in one ~10 km cell of the map. Its photos share a place name.
struct BrowseCell: Identifiable, Equatable, Sendable {
    let key: String
    /// The coordinates of one of the cell's photos. The name is looked up from these, so its cache key is the cell's key.
    let anchorLatitude: Double
    let anchorLongitude: Double
    /// Where the cell's pin goes: the average of its photos.
    let latitude: Double
    let longitude: Double
    /// The photos' paths, sorted.
    let paths: [String]

    var id: String { key }
    var count: Int { paths.count }
}

/// A row of the Places list: the cells that share a name (or a coordinate when they have no name yet), or the photos without a location.
struct BrowseGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// False for a cell whose name isn't known yet (offline, or not looked up): its title is its coordinates.
    let isNamed: Bool
    let isNoLocation: Bool
    var cellKeys: [String] = []
    var paths: [String] = []

    var count: Int { paths.count }
}

/// The pure part of Browse Backup: cells, names and groups. No I/O, so the rules can be tested without a drive.
enum BrowsePlaces {
    static let noLocationID = "no-location"

    /// Groups the located entries into cells, sorted by path within each cell.
    static func cells(from entries: [BrowseEntry]) -> [BrowseCell] {
        struct Builder {
            var anchor: (latitude: Double, longitude: Double)
            var latitudeSum = 0.0
            var longitudeSum = 0.0
            var paths: [String] = []
        }
        var builders: [String: Builder] = [:]
        var order: [String] = []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            guard let latitude = entry.latitude, let longitude = entry.longitude else { continue }
            let key = PlaceResolver.cellKey(latitude: latitude, longitude: longitude)
            if builders[key] == nil {
                builders[key] = Builder(anchor: (latitude, longitude))
                order.append(key)
            }
            builders[key]?.latitudeSum += latitude
            builders[key]?.longitudeSum += longitude
            builders[key]?.paths.append(entry.path)
        }
        return order.compactMap { key in
            guard let builder = builders[key] else { return nil }
            let count = Double(builder.paths.count)
            return BrowseCell(
                key: key,
                anchorLatitude: builder.anchor.latitude,
                anchorLongitude: builder.anchor.longitude,
                latitude: builder.latitudeSum / count,
                longitude: builder.longitudeSum / count,
                paths: builder.paths
            )
        }
    }

    /// The title for a name: "Country › City", "Country" alone, or "Unknown Place" when the coordinates have no address.
    static func title(for place: PlaceResolver.Place) -> String {
        let parts = [place.country, place.city]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "Unknown Place" : parts.joined(separator: " › ")
    }

    /// A cell's coordinates in words, for a place that hasn't been named yet.
    static func coordinatesTitle(for cell: BrowseCell) -> String {
        String(format: "%.2f, %.2f", cell.latitude, cell.longitude)
    }

    /// The Places list: named cells that share a title become one row, sorted by count (largest first). Cells not yet
    /// named each get a row with their coordinates. Photos without a location are one last row.
    static func groups(cells: [BrowseCell], names: [String: PlaceResolver.Place], noLocation: [String]) -> [BrowseGroup] {
        var byID: [String: BrowseGroup] = [:]
        for cell in cells {
            let rowID: String
            let rowTitle: String
            let isNamed: Bool
            if let place = names[cell.key] {
                rowTitle = Self.title(for: place)
                rowID = "place:" + rowTitle
                isNamed = true
            } else {
                rowTitle = coordinatesTitle(for: cell)
                rowID = "cell:" + cell.key
                isNamed = false
            }
            var row = byID[rowID] ?? BrowseGroup(id: rowID, title: rowTitle, isNamed: isNamed, isNoLocation: false)
            row.cellKeys.append(cell.key)
            row.paths.append(contentsOf: cell.paths)
            byID[rowID] = row
        }
        var result = byID.values.map { row -> BrowseGroup in
            var row = row
            row.paths.sort()
            return row
        }
        result.sort { a, b in
            a.count != b.count ? a.count > b.count : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        if !noLocation.isEmpty {
            result.append(BrowseGroup(
                id: noLocationID, title: "No Location", isNamed: true, isNoLocation: true, cellKeys: [], paths: noLocation.sorted()
            ))
        }
        return result
    }

    /// Names the cells that don't have a name yet, one at a time. A failed lookup is left out of the result, so the
    /// caller can show coordinates and try again later. Stops at the first cancellation.
    static func resolveNames(
        for cells: [BrowseCell],
        known: [String: PlaceResolver.Place],
        using namer: any PlaceNaming
    ) async -> (named: [String: PlaceResolver.Place], failed: Set<String>) {
        var named: [String: PlaceResolver.Place] = [:]
        var failed: Set<String> = []
        for cell in cells where known[cell.key] == nil {
            if Task.isCancelled { break }
            do {
                named[cell.key] = try await namer.placeNamed(latitude: cell.anchorLatitude, longitude: cell.anchorLongitude)
            } catch is CancellationError {
                break
            } catch {
                failed.insert(cell.key)
            }
        }
        return (named, failed)
    }
}

/// Browse Backup's state: the drive's index, its places, and the selection. Reads the destination only. Place names
/// come from `PlaceNaming` (the one network use), and are kept for the session.
@MainActor
@Observable
final class BrowseBackup {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case dates
        case map
        case places

        var id: Self { self }
        var title: String {
            switch self {
            case .dates: "Dates"
            case .map: "Map"
            case .places: "Places"
            }
        }
    }

    /// Progress of the index build, for "Reading locations… 12,340 of 48,312".
    struct Progress: Equatable, Sendable {
        var done: Int
        var total: Int
    }

    private(set) var destination: URL?
    private(set) var destinationName = ""
    private(set) var isConnected = false
    private(set) var progress: Progress?
    /// True from the start of an index update until it ends, whether or not it has reported progress yet.
    private(set) var isIndexing = false
    /// Changes when the map should fit all located photos again: when the first photos are located, and when an update ends.
    private(set) var fitGeneration = 0
    /// True while indexing waits for an export to finish.
    private(set) var isPaused = false
    /// Every indexed file by path, located or not.
    private(set) var entries: [String: BrowseEntry] = [:]
    private(set) var cells: [BrowseCell] = [] {
        didSet { cellsByKey = Dictionary(cells.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    @ObservationIgnored private var cellsByKey: [String: BrowseCell] = [:]
    private(set) var noLocationPaths: [String] = []
    private(set) var groups: [BrowseGroup] = []
    /// Place names by cell key, kept across destinations and sessions in memory.
    private(set) var names: [String: PlaceResolver.Place] = [:]
    /// Cells whose lookup failed (offline, usually). They show coordinates until a later request succeeds.
    private(set) var unnamedKeys: Set<String> = []

    /// Dates, Map or Places. Not saved: Browse Backup always opens on Dates.
    var mode: Mode = .dates
    /// Newest or oldest first, for the dates, the places' photos and the map's. Saved across launches.
    var sortOrder: BrowseSortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: BrowseSortOrder.defaultsKey) }
    }
    var query = ""
    var selectedGroupID: String?
    /// The Dates row picked: a year, a month, or `BrowseTimeline.noDateID`.
    var selectedDateID: String? {
        didSet {
            if oldValue != selectedDateID { selectedPaths = [] }
            // A choice the user makes sticks. The automatic choice sets the flag back itself.
            dateSelectionIsAutomatic = false
        }
    }
    /// The years whose months are listed. Kept for the session, not saved.
    var expandedYears: Set<String> = []
    /// The map cells picked for the inspector.
    var mapSelection: Set<String> = []
    /// The photos selected in the grid. The detail pane shows the one when exactly one is selected.
    var selectedPaths: Set<String> = []
    /// The dates in the sort order, built off the main actor after each index change.
    private(set) var timeline = BrowseTimeline()
    private(set) var isBuildingTimeline = false

    @ObservationIgnored let calendar: Calendar
    @ObservationIgnored private let store: BrowseIndexStore
    @ObservationIgnored private let isExportRunning: @MainActor () -> Bool
    @ObservationIgnored private let namer: any PlaceNaming
    @ObservationIgnored private let defaults: UserDefaults
    /// The local iCloud catalog of a destination, for dates and places (R18). Internal so the wiring can be tested.
    @ObservationIgnored let iCloudCatalog: @Sendable (URL) async -> ICloudCatalog?
    @ObservationIgnored private let readMetadata: @Sendable (URL) async -> BrowseMetadata
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    /// The camera reads in progress, by path, so a second request waits for the first.
    @ObservationIgnored private var cameraTasks: [String: Task<String, Never>] = [:]
    @ObservationIgnored private var nameTask: Task<Void, Never>?
    @ObservationIgnored private var pendingNames: Set<String> = []
    @ObservationIgnored private var timelineTask: Task<Void, Never>?
    @ObservationIgnored private var timelineGeneration = 0
    /// True while the selection is the automatic one (the first row of the list), so it follows the index.
    @ObservationIgnored private var dateSelectionIsAutomatic = true
    /// Changes whenever the cells, groups or timeline change, so the grid's memo is dropped.
    @ObservationIgnored private var contentVersion = 0
    @ObservationIgnored private var gridCache: (key: GridKey, paths: [String])?
    @ObservationIgnored private var filterCache: (query: String, version: Int, timeline: BrowseTimeline)?
    @ObservationIgnored private var daySectionCache: (key: SectionKey, sections: [BrowseDaySection])?

    private struct SectionKey: Equatable {
        let monthID: String
        let order: BrowseSortOrder
        let version: Int
    }

    /// What the grid's paths depend on, besides the data itself (which `contentVersion` covers).
    private struct GridKey: Equatable {
        let mode: Mode
        let dateID: String?
        let groupID: String?
        let mapSelection: Set<String>
        let order: BrowseSortOrder
        let version: Int
    }

    init(
        store: BrowseIndexStore = .standard(),
        namer: any PlaceNaming = PlaceResolver(),
        isExportRunning: @escaping @MainActor () -> Bool,
        calendar: Calendar = .autoupdatingCurrent,
        defaults: UserDefaults = .standard,
        iCloudCatalog: @escaping @Sendable (URL) async -> ICloudCatalog? = { _ in nil },
        readMetadata: @escaping @Sendable (URL) async -> BrowseMetadata = { await BrowseMetadata.read(of: $0) }
    ) {
        self.store = store
        self.namer = namer
        self.isExportRunning = isExportRunning
        self.calendar = calendar
        self.defaults = defaults
        self.iCloudCatalog = iCloudCatalog
        self.readMetadata = readMetadata
        sortOrder = BrowseSortOrder(rawValue: defaults.string(forKey: BrowseSortOrder.defaultsKey) ?? "") ?? .newestFirst
    }

    // MARK: - Derived state

    var isEmpty: Bool { entries.isEmpty }

    /// Photos with a location, across all cells.
    var locatedCount: Int { cells.reduce(0) { $0 + $1.count } }

    /// The Places rows that match the search.
    var visibleGroups: [BrowseGroup] {
        query.isEmpty ? groups : groups.filter { $0.title.localizedStandardContains(query) }
    }

    /// The cells the map shows: those in a matching row.
    var visibleCells: [BrowseCell] {
        guard !query.isEmpty else { return cells }
        let keys = Set(visibleGroups.flatMap(\.cellKeys))
        return cells.filter { keys.contains($0.key) }
    }

    /// The timeline the Dates list shows: all of it, or the months that match the search.
    var visibleTimeline: BrowseTimeline {
        guard !query.isEmpty else { return timeline }
        if let filterCache, filterCache.query == query, filterCache.version == contentVersion {
            return filterCache.timeline
        }
        let filtered = timeline.filtered(query, calendar: calendar, locale: .autoupdatingCurrent)
        filterCache = (query, contentVersion, filtered)
        return filtered
    }

    /// The photos in the grid, in the sort order: the selected row in Dates, the selected place in Places, or the
    /// cells picked on the map. Memoized, because the view reads it on every update.
    var gridPaths: [String] {
        let key = GridKey(
            mode: mode, dateID: selectedDateID, groupID: selectedGroupID, mapSelection: mapSelection,
            order: sortOrder, version: contentVersion
        )
        if let gridCache, gridCache.key == key { return gridCache.paths }
        let paths = computeGridPaths()
        gridCache = (key, paths)
        return paths
    }

    private func computeGridPaths() -> [String] {
        switch mode {
        case .dates:
            guard let id = selectedDateID else { return [] }
            return timeline.paths(forRowID: id, order: sortOrder)
        case .places:
            guard let id = selectedGroupID, let group = groups.first(where: { $0.id == id }) else { return [] }
            return BrowseDates.sorted(group.paths, rank: timeline.rank, order: sortOrder)
        case .map:
            let keys = mapSelection
            let paths = cells.filter { keys.contains($0.key) }.flatMap(\.paths)
            return BrowseDates.sorted(paths, rank: timeline.rank, order: sortOrder)
        }
    }

    /// The month selected in Dates, if one is.
    var selectedMonth: BrowseMonth? {
        guard let id = selectedDateID else { return nil }
        return timeline.month(withID: id)
    }

    /// The selected month's photos split by day, in the sort order, each with its named places. Empty unless a month is
    /// selected in Dates. Memoized, because a month can hold thousands of photos.
    var daySections: [BrowseDaySection] {
        guard mode == .dates, let month = selectedMonth else { return [] }
        let key = SectionKey(monthID: month.id, order: sortOrder, version: contentVersion)
        if let daySectionCache, daySectionCache.key == key { return daySectionCache.sections }
        let sections = BrowseDates.days(of: month, entries: entries, calendar: calendar, order: sortOrder).map { section in
            var section = section
            section.placeSummary = namedPlaceSummary(for: section.paths)
            return section
        }
        daySectionCache = (key, sections)
        return sections
    }

    /// The named places of some photos, distinct, in photo order. Unnamed places are left out: a header shows names only.
    private func namedPlaceSummary(for paths: [String]) -> String? {
        var titles: [String] = []
        for path in paths {
            guard let entry = entries[path], let latitude = entry.latitude, let longitude = entry.longitude,
                  let place = names[PlaceResolver.cellKey(latitude: latitude, longitude: longitude)] else { continue }
            let title = BrowsePlaces.title(for: place)
            if title != "Unknown Place", !titles.contains(title) {
                titles.append(title)
            }
        }
        return BrowseDates.placeSummary(titles)
    }

    /// The name shown for a cell: its place, or its coordinates until a name is known.
    func placeTitle(forCellKey key: String) -> String {
        if let place = names[key] {
            return BrowsePlaces.title(for: place)
        }
        guard let cell = cellsByKey[key] else { return key }
        return BrowsePlaces.coordinatesTitle(for: cell)
    }

    /// The place name of a photo, or nil when it has no location or its place isn't known yet.
    func placeTitle(forPath path: String) -> String? {
        guard let entry = entries[path], let latitude = entry.latitude, let longitude = entry.longitude else {
            return nil
        }
        let key = PlaceResolver.cellKey(latitude: latitude, longitude: longitude)
        return placeTitle(forCellKey: key)
    }

    /// What Copy Location puts on the pasteboard: the place and the coordinates. Nil when the photo has no location.
    func locationText(forPath path: String) -> String? {
        guard let entry = entries[path], let latitude = entry.latitude, let longitude = entry.longitude else {
            return nil
        }
        let coordinates = BrowsePhotoDetail.coordinateText(latitude: latitude, longitude: longitude)
        guard let place = placeTitle(forPath: path) else { return coordinates }
        return "\(place), \(coordinates)"
    }

    // MARK: - Index

    /// Points Browse Backup at a destination and starts indexing it when it's connected. Switching destinations
    /// loads that destination's saved index first, so it's browsable at once.
    func update(destination url: URL?, name: String, isConnected connected: Bool) {
        if url?.standardizedFileURL != destination?.standardizedFileURL {
            indexTask?.cancel()
            indexTask = nil
            destination = url
            destinationName = name
            progress = nil
            isPaused = false
            isIndexing = false
            selectedGroupID = nil
            selectedDateID = nil
            dateSelectionIsAutomatic = true
            expandedYears = []
            timeline = BrowseTimeline()
            mapSelection = []
            selectedPaths = []
            entries = url.map { store.load(key: NewPhotosContext.destinationKey(for: $0)) } ?? [:]
            rebuild()
        }
        isConnected = connected
        guard let url, connected else {
            indexTask?.cancel()
            indexTask = nil
            progress = nil
            isIndexing = false
            return
        }
        guard indexTask == nil else { return }
        startIndexing(url)
    }

    private func startIndexing(_ url: URL) {
        let key = NewPhotosContext.destinationKey(for: url)
        let store = store
        let previous = entries
        let isExportRunning = isExportRunning
        let catalogProvider = iCloudCatalog
        isIndexing = true
        indexTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .utility) { () async throws -> [String: BrowseEntry] in
                    // iCloud's dates and places come from the catalog; items it doesn't know are read from the file.
                    var iCloud: [String: BrowseMetadata] = [:]
                    if let catalog = await catalogProvider(url) {
                        iCloud = (try? await BrowseIndexer.iCloudMetadata(in: url, catalog: catalog)) ?? [:]
                    }
                    return try await BrowseIndexer.update(
                        destination: url,
                        previous: previous,
                        iCloudMetadata: iCloud,
                        waitWhilePaused: {
                            var waited = false
                            while await MainActor.run(body: { isExportRunning() }) {
                                waited = true
                                await MainActor.run { self?.setPaused(true) }
                                try await Task.sleep(for: .seconds(2))
                            }
                            if waited { await MainActor.run { self?.setPaused(false) } }
                        },
                        progress: { done, total in
                            Task { @MainActor in self?.setProgress(done: done, total: total, for: url) }
                        },
                        persist: { snapshot in
                            try? store.save(snapshot, key: key)
                            Task { @MainActor in self?.showPartial(snapshot, for: url) }
                        }
                    )
                }.value
                self?.finishIndexing(result, for: url)
            } catch BrowseIndexError.driveUnavailable {
                self?.driveDisappeared(url)
            } catch {
                // Cancelled because the destination changed or the pane went away; the next update starts again.
                self?.indexStopped(url)
            }
        }
    }

    /// The camera of a photo, for the detail pane. A photo indexed from iCloud has no camera until it's asked for: the
    /// file is read once, and the answer is kept in the entry (empty when the file has none, so it isn't read again).
    /// Nil when the photo isn't indexed, or its file can't be read now.
    func camera(for path: String) async -> String? {
        guard let entry = entries[path] else { return nil }
        if let camera = entry.camera { return camera }
        guard entry.source == .iCloud, let destination, let url = BackupFiles.containedURL(for: path, in: destination),
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let task: Task<String, Never>
        if let running = cameraTasks[path] {
            task = running
        } else {
            let readMetadata = readMetadata
            task = Task.detached(priority: .utility) { await readMetadata(url).camera ?? "" }
            cameraTasks[path] = task
        }
        let camera = await task.value
        cameraTasks[path] = nil
        if entries[path]?.camera == nil {
            entries[path]?.camera = camera
        }
        return entries[path]?.camera ?? camera
    }

    private func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    private func setProgress(done: Int, total: Int, for url: URL) {
        guard destination == url else { return }
        progress = Progress(done: done, total: total)
    }

    /// Shows what's indexed so far; the index stays browsable while the rest is read.
    private func showPartial(_ snapshot: [String: BrowseEntry], for url: URL) {
        guard destination == url, indexTask != nil else { return }
        entries = snapshot
        rebuild()
    }

    private func finishIndexing(_ result: [String: BrowseEntry], for url: URL) {
        guard destination == url else { return }
        entries = result
        progress = nil
        isPaused = false
        isIndexing = false
        indexTask = nil
        rebuild()
        fitGeneration += 1
    }

    private func driveDisappeared(_ url: URL) {
        guard destination == url else { return }
        isConnected = false
        progress = nil
        isIndexing = false
        indexTask = nil
    }

    private func indexStopped(_ url: URL) {
        guard destination == url else { return }
        progress = nil
        isPaused = false
        isIndexing = false
        indexTask = nil
    }

    /// Rebuilds the places and the dates from `entries`. The dates are built in the background, unless `synchronously`.
    private func rebuild(synchronously: Bool = false) {
        let hadLocated = !cells.isEmpty
        let entryList = Array(entries.values)
        cells = BrowsePlaces.cells(from: entryList)
        noLocationPaths = entryList.filter { !$0.hasLocation }.map(\.path).sorted()
        rebuildGroups()
        timelineGeneration += 1
        let generation = timelineGeneration
        timelineTask?.cancel()
        if synchronously {
            timelineTask = nil
            isBuildingTimeline = false
            applyTimeline(BrowseDates.timeline(from: entryList, calendar: calendar))
        } else {
            isBuildingTimeline = true
            let calendar = calendar
            timelineTask = Task { [weak self] in
                let built = await Task.detached(priority: .userInitiated) {
                    BrowseDates.timeline(from: entryList, calendar: calendar)
                }.value
                // A newer build has started since, so this one is stale.
                guard let self, generation == self.timelineGeneration else { return }
                self.applyTimeline(built)
            }
        }
        if !hadLocated && !cells.isEmpty {
            fitGeneration += 1
        }
    }

    private func rebuildGroups() {
        groups = BrowsePlaces.groups(cells: cells, names: names, noLocation: noLocationPaths)
        contentVersion += 1
    }

    /// Sets the built dates. While the user hasn't picked a row, the selection is the first row, so it follows the index.
    private func applyTimeline(_ built: BrowseTimeline) {
        timeline = built
        isBuildingTimeline = false
        contentVersion += 1
        let stillThere = selectedDateID.map { timeline.hasRow($0) } ?? false
        if dateSelectionIsAutomatic || !stillThere {
            selectedDateID = timeline.firstRowID(sortOrder)
            dateSelectionIsAutomatic = true
            if let id = selectedDateID, let year = timeline.yearID(containing: id) {
                expandedYears.insert(year)
            }
        }
    }

    // MARK: - Names

    /// Names the cells with these keys that aren't named yet, in the background, one lookup at a time. Cells that
    /// failed before are tried again, so the views can call this whenever they appear.
    func requestNames(for keys: Set<String>) {
        let wanted = cells.filter { keys.contains($0.key) && (names[$0.key] == nil) && !pendingNames.contains($0.key) }
        guard !wanted.isEmpty else { return }
        pendingNames.formUnion(wanted.map(\.key))
        let known = names
        let previous = nameTask
        let namer = namer
        nameTask = Task { [weak self] in
            await previous?.value
            let result = await BrowsePlaces.resolveNames(for: wanted, known: known, using: namer)
            guard let self else { return }
            for (key, place) in result.named {
                names[key] = place
                unnamedKeys.remove(key)
            }
            unnamedKeys.formUnion(result.failed)
            pendingNames.subtract(wanted.map(\.key))
            rebuildGroups()
        }
    }

    /// Names the places of the selected month's photos, so its day headers can show them. Only that month's cells are
    /// looked up, as the map does for the cells on screen.
    func requestNamesForSelectedMonth() {
        guard let month = selectedMonth else { return }
        var keys: Set<String> = []
        for path in month.paths {
            guard let entry = entries[path], let latitude = entry.latitude, let longitude = entry.longitude else { continue }
            keys.insert(PlaceResolver.cellKey(latitude: latitude, longitude: longitude))
        }
        requestNames(for: keys)
    }

    // MARK: - Preview and tests

    /// Replaces the index with these entries, without reading the drive. Used by previews and tests.
    func load(
        entries: [BrowseEntry],
        names: [String: PlaceResolver.Place] = [:],
        destination url: URL,
        destinationName: String = "Backup Drive"
    ) {
        destination = url
        self.entries = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        self.names = names
        self.destinationName = destinationName
        self.isConnected = true
        rebuild(synchronously: true)
        fitGeneration += 1
    }

    /// Sets the names directly, for previews and tests.
    func setNames(_ names: [String: PlaceResolver.Place]) {
        self.names = names
        rebuildGroups()
    }
}
