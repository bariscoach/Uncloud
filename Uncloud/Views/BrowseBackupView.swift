import SwiftUI

/// Browse Backup: the photos on the destination drive, by where they were taken. It reads the drive only, plus place
/// names, which are the one network use and are cached. The Map and Places views share the photo grid and detail pane.
struct BrowseBackupView: View {
    @Environment(ExportModel.self) private var model
    let browse: BrowseBackup
    /// False for previews, which set the model's index themselves and must not have it replaced by the folder on screen.
    var syncsDestination = true

    var body: some View {
        Group {
            if browse.destination == nil {
                noFolder
            } else if !browse.isConnected {
                notConnected(browse)
            } else if browse.isEmpty && !browse.isIndexing {
                nothingToBrowse
            } else if let destination = browse.destination {
                loaded(browse, destination: destination)
            }
        }
        .navigationSubtitle(browse.destinationName)
        .searchable(text: Bindable(browse).query, placement: .toolbar, prompt: browse.mode == .dates ? "Search months" : "Search places")
        .toolbar {
            ToolbarItem(placement: .principal) {
                modePicker(browse)
            }
            ToolbarItem {
                sortMenu(browse)
            }
        }
        .onAppear { sync() }
        .onChange(of: model.destination?.url) { _, _ in sync() }
        .onChange(of: model.destinationIssue) { _, _ in sync() }
        .onChange(of: model.isExporting) { _, _ in sync() }
    }

    /// Points the model at the chosen destination. A destination that's connected starts indexing.
    private func sync() {
        guard syncsDestination else { return }
        let destination = model.destination
        browse.update(
            destination: destination?.url,
            name: destination?.displayName ?? "",
            isConnected: destination != nil && model.destinationIssue == nil
        )
    }

    // MARK: - Toolbar

    private func modePicker(_ browse: BrowseBackup) -> some View {
        Picker("View", selection: Bindable(browse).mode) {
            ForEach(BrowseBackup.Mode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .help("Show the photos by date, on a map, or as a list of places")
        .accessibilityLabel("View")
    }

    private func sortMenu(_ browse: BrowseBackup) -> some View {
        Menu {
            Picker("Sort", selection: Bindable(browse).sortOrder) {
                ForEach(BrowseSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .labelStyle(.iconOnly)
        .help("Sort photos by date")
        .accessibilityLabel("Sort")
        .accessibilityValue(browse.sortOrder.title)
    }

    // MARK: - States

    private var noFolder: some View {
        ContentUnavailableView {
            Label("No Backup Folder", systemImage: "externaldrive")
        } description: {
            Text("Choose a backup folder to browse your photos by date and place.")
        } actions: {
            Button("Choose Backup Folder…") {
                model.beginChoosingDestination()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func notConnected(_ browse: BrowseBackup) -> some View {
        ContentUnavailableView {
            Label("Drive Not Connected", systemImage: "externaldrive.badge.xmark")
        } description: {
            Text("Connect “\(browse.destinationName)” to browse your backup.")
        }
    }

    private var nothingToBrowse: some View {
        ContentUnavailableView {
            Label("Nothing to Browse Yet", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Export some photos, then see where they were taken.")
        } actions: {
            Button("Go to Backup") {
                model.pane = .backup
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Loaded

    @ViewBuilder
    private func loaded(_ browse: BrowseBackup, destination: URL) -> some View {
        Group {
            switch browse.mode {
            case .dates:
                datesLayout(browse, destination: destination)
            case .map:
                mapLayout(browse, destination: destination)
            case .places:
                placesLayout(browse, destination: destination)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if browse.isIndexing {
                IndexingBanner(progress: browse.progress, isPaused: browse.isPaused)
            }
        }
        .onChange(of: browse.mode) { _, _ in
            requestNames(browse)
        }
        .onChange(of: browse.cells.count) { _, _ in
            requestNames(browse)
        }
        .onChange(of: browse.selectedDateID) { _, _ in
            requestNames(browse)
        }
        .onAppear {
            requestNames(browse)
        }
    }

    /// Looks up the place names the visible view shows: every cell in Places, or the selected month's for the day headers.
    private func requestNames(_ browse: BrowseBackup) {
        switch browse.mode {
        case .places:
            browse.requestNames(for: Set(browse.cells.map(\.key)))
        case .dates:
            browse.requestNamesForSelectedMonth()
        case .map:
            break
        }
    }

    // MARK: - Map

    private func mapLayout(_ browse: BrowseBackup, destination: URL) -> some View {
        BrowseMapView(
            cells: browse.visibleCells,
            title: { browse.placeTitle(forCellKey: $0) },
            selection: Bindable(browse).mapSelection,
            fitGeneration: browse.fitGeneration,
            onVisibleCells: { browse.requestNames(for: $0) }
        )
        .overlay {
            if browse.cells.isEmpty {
                noLocatedPhotos(browse)
            }
        }
        .inspector(isPresented: inspectorIsShown(browse)) {
            inspector(browse, destination: destination)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
    }

    private func inspectorIsShown(_ browse: BrowseBackup) -> Binding<Bool> {
        Binding(
            get: { !browse.mapSelection.isEmpty },
            set: { shown in
                if !shown {
                    browse.mapSelection = []
                    browse.selectedPaths = []
                }
            }
        )
    }

    /// The panel for the pins picked on the map: the place's name, then its photos and the selected photo's details.
    private func inspector(_ browse: BrowseBackup, destination: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text(inspectorTitle(browse))
                    .font(.headline)
                    .lineLimit(2)
                Text(Plural.photos(browse.gridPaths.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Space.l)
            photos(browse, destination: destination)
        }
    }

    private func inspectorTitle(_ browse: BrowseBackup) -> String {
        if browse.mapSelection.count == 1, let key = browse.mapSelection.first {
            return browse.placeTitle(forCellKey: key)
        }
        return "\(browse.mapSelection.count) places"
    }

    private func noLocatedPhotos(_ browse: BrowseBackup) -> some View {
        Group {
            if browse.isIndexing {
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text(readingText(browse))
                        .monospacedDigit()
                }
            } else {
                ContentUnavailableView {
                    Label("No Photo Locations", systemImage: "map")
                } description: {
                    Text("None of these photos has a location. Find them under No Location in Places.")
                }
            }
        }
        .background(.background)
    }

    // MARK: - Places

    private func placesLayout(_ browse: BrowseBackup, destination: URL) -> some View {
        HStack(spacing: 0) {
            List(selection: Bindable(browse).selectedGroupID) {
                ForEach(browse.visibleGroups) { group in
                    PlaceRow(group: group)
                        .tag(group.id)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            .overlay {
                if browse.groups.isEmpty {
                    noLocatedPhotos(browse)
                }
            }
            Divider()
            photos(browse, destination: destination)
        }
    }

    // MARK: - Dates

    private func datesLayout(_ browse: BrowseBackup, destination: URL) -> some View {
        HStack(spacing: 0) {
            datesList(browse)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            Divider()
            photos(browse, destination: destination)
        }
    }

    /// The years, each expandable into its months, then No Date. The selected row is scrolled to when the pane opens
    /// and when the order changes.
    private func datesList(_ browse: BrowseBackup) -> some View {
        let timeline = browse.visibleTimeline
        let years = timeline.years(browse.sortOrder)
        let locale = Locale.autoupdatingCurrent
        return ScrollViewReader { proxy in
            List(selection: Bindable(browse).selectedDateID) {
                ForEach(years) { year in
                    DisclosureGroup(isExpanded: expansion(ofYear: year.id, in: browse)) {
                        ForEach(year.months) { month in
                            DateRow(
                                title: BrowseDates.monthTitle(month, calendar: browse.calendar, locale: locale),
                                count: month.count,
                                accessibilityTitle: BrowseDates.fullMonthTitle(month, calendar: browse.calendar, locale: locale)
                            )
                            .tag(month.id)
                        }
                    } label: {
                        DateRow(title: BrowseDates.yearTitle(year.year), count: year.count)
                            .tag(year.id)
                    }
                }
                if !timeline.noDate.isEmpty {
                    DateRow(title: "No Date", count: timeline.noDate.count, symbol: "calendar.badge.exclamationmark")
                        .tag(BrowseTimeline.noDateID)
                }
            }
            .listStyle(.sidebar)
            .overlay {
                // Only while there's nothing to show yet: a rebuild during indexing keeps the list up.
                if browse.timeline.isEmpty && (browse.isBuildingTimeline || browse.isIndexing) {
                    readingPlaceholder(browse)
                } else if years.isEmpty && timeline.noDate.isEmpty && !browse.query.isEmpty {
                    ContentUnavailableView.search(text: browse.query)
                }
            }
            .onAppear { reveal(browse.selectedDateID, with: proxy) }
            .onChange(of: browse.sortOrder) { _, _ in reveal(browse.selectedDateID, with: proxy) }
        }
    }

    /// A search shows every matching year expanded. Otherwise the year's disclosure is the user's, for the session.
    private func expansion(ofYear yearID: String, in browse: BrowseBackup) -> Binding<Bool> {
        Binding(
            get: { !browse.query.isEmpty || browse.expandedYears.contains(yearID) },
            set: { expanded in
                if expanded {
                    browse.expandedYears.insert(yearID)
                } else {
                    browse.expandedYears.remove(yearID)
                }
            }
        )
    }

    private func reveal(_ rowID: String?, with proxy: ScrollViewProxy) {
        guard let rowID else { return }
        proxy.scrollTo(rowID, anchor: .center)
    }

    // MARK: - Photos

    /// The grid of the selected photos, with the detail pane under it when one photo is selected.
    @ViewBuilder
    private func photos(_ browse: BrowseBackup, destination: URL) -> some View {
        let paths = browse.gridPaths
        if paths.isEmpty {
            ContentUnavailableView {
                Label(browse.mode == .dates ? "Select a Month" : "Select a Place", systemImage: "photo.on.rectangle")
            } description: {
                Text(placeholderText(for: browse.mode))
            }
        } else {
            BrowsePhotoGrid(
                paths: paths,
                destination: destination,
                selection: Bindable(browse).selectedPaths,
                locationText: { browse.locationText(forPath: $0) },
                sections: dateSections(browse)
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                detail(browse)
            }
        }
    }

    /// The headers of the grid in Dates: the days of a selected month, or the months of a selected year. Nil for a flat
    /// grid (No Date, and Places and Map).
    private func dateSections(_ browse: BrowseBackup) -> [BrowsePhotoSection]? {
        guard browse.mode == .dates, let id = browse.selectedDateID, id != BrowseTimeline.noDateID else { return nil }
        let locale = Locale.autoupdatingCurrent
        if id.hasPrefix("month:") {
            return browse.daySections.map { section in
                BrowsePhotoSection(
                    id: section.id,
                    title: BrowseDates.dayTitle(section, calendar: browse.calendar, locale: locale),
                    subtitle: section.placeSummary,
                    paths: section.paths
                )
            }
        }
        guard let year = browse.timeline.years.first(where: { $0.id == id }) else { return nil }
        return BrowseDates.monthSections(of: year, order: browse.sortOrder).map { month in
            BrowsePhotoSection(
                id: month.id,
                title: BrowseDates.monthTitle(month, calendar: browse.calendar, locale: locale),
                subtitle: Plural.photos(month.count),
                paths: month.paths
            )
        }
    }

    private func placeholderText(for mode: BrowseBackup.Mode) -> String {
        switch mode {
        case .dates: "Select a month to see its photos."
        case .map: "Click a pin to see its photos."
        case .places: "Select a place to see its photos."
        }
    }

    @ViewBuilder
    private func detail(_ browse: BrowseBackup) -> some View {
        if browse.selectedPaths.count == 1, let path = browse.selectedPaths.first, let entry = browse.entries[path] {
            BrowsePhotoDetail(entry: entry, placeTitle: browse.placeTitle(forPath: path), loadCamera: {
                await browse.camera(for: path)
            })
                .padding(Tokens.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }

    /// The spinner while the dates are built or the index is first read, in place of the list.
    private func readingPlaceholder(_ browse: BrowseBackup) -> some View {
        ContentUnavailableView {
            ProgressView()
        } description: {
            Text(readingText(browse))
                .monospacedDigit()
        }
        .background(.background)
    }

    private func readingText(_ browse: BrowseBackup) -> String {
        guard let progress = browse.progress else { return "Opening your backup…" }
        return "Reading photos… \(progress.done.formatted()) of \(progress.total.formatted())"
    }
}

/// The index build's progress, along the top of the view. It stays up until the index is complete. It's a
/// `StatusBanner`, the same banner Clean Up iCloud uses.
struct IndexingBanner: View {
    let progress: BrowseBackup.Progress?
    let isPaused: Bool

    var body: some View {
        StatusBanner(
            symbol: nil,
            tint: .accentColor,
            title: text,
            progress: progress.map { min(1, Double($0.done) / Double(max($0.total, 1))) }
        ) {
            // No count yet: a spinner says it's still working.
            if progress == nil && !isPaused {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var text: String {
        if isPaused {
            return "Paused while an export runs"
        }
        guard let progress else { return "Opening your backup…" }
        return "Reading photos… \(progress.done.formatted()) of \(progress.total.formatted())"
    }
}

/// A row of the Dates list: a year, a month or No Date, with its photo count.
private struct DateRow: View {
    let title: String
    let count: Int
    var accessibilityTitle: String?
    var symbol: String?

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            if let symbol {
                Label(title, systemImage: symbol)
                    .foregroundStyle(.secondary)
            } else {
                Text(title)
                    .lineLimit(1)
            }
            Spacer(minLength: Tokens.Space.s)
            Text(count.formatted())
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(accessibilityTitle ?? title), \(Plural.photos(count))")
    }
}

/// A row of the Places list: the place's name and its photo count. A place that's still being named shows its coordinates.
private struct PlaceRow: View {
    let group: BrowseGroup

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            if group.isNoLocation {
                Label(group.title, systemImage: "location.slash")
                    .foregroundStyle(.secondary)
            } else {
                Text(group.title)
                    .foregroundStyle(group.isNamed ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Tokens.Space.s)
            Text(group.count.formatted())
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.title), \(group.count) photos")
    }
}
