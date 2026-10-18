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
        .searchable(text: Bindable(browse).query, placement: .toolbar, prompt: "Filter places")
        .toolbar {
            ToolbarItem(placement: .principal) {
                modePicker(browse)
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
        .help("Show the photos on a map or as a list of places")
        .accessibilityLabel("View")
    }

    // MARK: - States

    private var noFolder: some View {
        ContentUnavailableView {
            Label("No Backup Folder", systemImage: "externaldrive")
        } description: {
            Text("Choose a backup folder to browse it.")
        } actions: {
            Button("Choose Folder…") {
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
            Label("Nothing to Browse Yet", systemImage: "map")
        } description: {
            Text("Export some photos to this folder, then come back to see where they were taken.")
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
        .onChange(of: browse.mode) { _, mode in
            if mode == .places {
                browse.requestNames(for: Set(browse.cells.map(\.key)))
            }
        }
        .onChange(of: browse.cells.count) { _, _ in
            if browse.mode == .places {
                browse.requestNames(for: Set(browse.cells.map(\.key)))
            }
        }
        .onAppear {
            if browse.mode == .places {
                browse.requestNames(for: Set(browse.cells.map(\.key)))
            }
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
                Text("\(browse.gridPaths.count) photos")
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
                    Label("No Photos Have a Location", systemImage: "map")
                } description: {
                    Text("None of the photos on this drive has a location. Photos taken with location off are listed under No Location in Places.")
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

    // MARK: - Photos

    /// The grid of the selected photos, with the detail pane under it when one photo is selected.
    @ViewBuilder
    private func photos(_ browse: BrowseBackup, destination: URL) -> some View {
        let paths = browse.gridPaths
        if paths.isEmpty {
            ContentUnavailableView {
                Label("Choose a Place", systemImage: "photo.on.rectangle")
            } description: {
                Text(browse.mode == .map ? "Click a pin to see its photos." : "Select a place to see its photos.")
            }
        } else {
            BrowsePhotoGrid(
                paths: paths,
                destination: destination,
                selection: Bindable(browse).selectedPaths,
                locationText: { browse.locationText(forPath: $0) }
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                detail(browse)
            }
        }
    }

    @ViewBuilder
    private func detail(_ browse: BrowseBackup) -> some View {
        if browse.selectedPaths.count == 1, let path = browse.selectedPaths.first, let entry = browse.entries[path] {
            BrowsePhotoDetail(entry: entry, placeTitle: browse.placeTitle(forPath: path))
                .padding(Tokens.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }

    private func readingText(_ browse: BrowseBackup) -> String {
        guard let progress = browse.progress else { return "Checking the backup…" }
        return "Reading locations… \(progress.done.formatted()) of \(progress.total.formatted())"
    }
}

/// The index build's progress, along the top of the view. It stays up until the index is complete.
struct IndexingBanner: View {
    let progress: BrowseBackup.Progress?
    let isPaused: Bool

    var body: some View {
        HStack(spacing: Tokens.Space.m) {
            if let progress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(maxWidth: 160)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(text)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Space.l)
        .padding(.vertical, Tokens.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        if isPaused {
            return "Paused while an export runs"
        }
        guard let progress else { return "Checking the backup…" }
        return "Reading locations… \(progress.done.formatted()) of \(progress.total.formatted())"
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
