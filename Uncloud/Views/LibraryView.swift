import AppKit
import SwiftUI

/// The Library pane: the whole library as a grid to choose from, or the state that replaces it.
struct LibraryView: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        Group {
            if model.isSourceReady, let browser = model.browser {
                LibraryBrowserView(browser: browser)
            } else if model.source == .photosLibrary, model.isPhotosAccessBlocked {
                PhotosAccessView()
            } else {
                LandingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            if model.isSourceReady, let browser = model.browser {
                LibraryToolbar(browser: browser)
            }
        }
    }
}

/// The toolbar of the Library pane: the selection count, Select menu, export progress and the primary button.
private struct LibraryToolbar: ToolbarContent {
    @Environment(ExportModel.self) private var model
    let browser: LibraryBrowser

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Text(countText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)

            Menu("Select") {
                Button("Select All") {
                    model.selection.selectAll()
                }
                .disabled(browser.count == nil)
                Button("Deselect All") {
                    model.selection.deselectAll()
                }
                .disabled(model.selection.isNothing)
            }
            .help("Select or deselect every item")

            if model.isExporting {
                // Clicking the progress ring opens the Backup pane, where the export is shown in full.
                Button {
                    model.pane = .backup
                } label: {
                    ProgressView(value: model.fractionComplete)
                        .progressViewStyle(.circular)
                }
                .help("Show export progress")
                .accessibilityLabel("Export progress, \(Int(model.fractionComplete * 100)) percent")
            }

            Button(model.primaryExportTitle(total: total)) {
                model.performPrimaryAction()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.primaryExportEnabled(total: total))
        }
    }

    private var total: Int? { browser.count }

    private var countText: String {
        guard let total else { return "" }
        let selected = model.selection.selectedCount(total: total)
        let count = model.selection.isEverything
            ? "All \(total.formatted()) items selected"
            : "\(selected.formatted()) of \(total.formatted()) selected"
        // The estimated size, such as "· about 412 GB", once anything is selected.
        guard selected > 0, let size = model.storageEstimateText else { return count }
        return "\(count) · \(size)"
    }

}

/// Shows the grid once the count is known, and the loading, sign-in and failure states before that.
private struct LibraryBrowserView: View {
    @Environment(ExportModel.self) private var model
    let browser: LibraryBrowser
    @FocusState private var focusedIndex: Int?
    /// The last tile clicked, the start of a shift-click range.
    @State private var anchor: Int?
    @State private var rangeTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch browser.state {
            case .signInRequired:
                ContentUnavailableView {
                    Label("Sign In Again", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("Your iCloud sign-in has expired.")
                } actions: {
                    Button("Sign In…") {
                        model.isShowingICloudSignIn = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            case let .failed(message):
                ContentUnavailableView {
                    Label("Couldn’t Open Your Library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    if message == ICloudFailure.setupIncomplete.message {
                        // Apple presents its terms only in its own interfaces; the user accepts them there.
                        Button("Open Apple Account Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("Open iCloud.com") {
                            if let url = URL(string: "https://www.icloud.com") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    Button("Try Again") {
                        browser.reload()
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .loading, .ready:
                if let count = browser.count {
                    grid(count: count)
                } else {
                    loading
                }
            }
        }
        .task(id: ObjectIdentifier(browser)) {
            browser.load()
        }
    }

    private var loading: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading your library…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 2)], spacing: 2) {
                    ForEach(0..<30, id: \.self) { _ in
                        Rectangle()
                            .fill(.quaternary)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
                .accessibilityHidden(true)
            }
            .padding()
        }
    }

    /// The library as a lazy grid. Every cell asks for its own item, so nothing is materialized up front.
    private func grid(count: Int) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 2)], spacing: 2) {
                ForEach(0..<count, id: \.self) { index in
                    LibraryTile(
                        item: browser.item(at: index),
                        isSelected: browser.item(at: index).map { model.selection.contains($0.id) } ?? false,
                        browser: browser
                    )
                    .focusable()
                    .focused($focusedIndex, equals: index)
                    .onTapGesture {
                        // A tap with Shift held selects the range from the last tile clicked.
                        tap(index, extendsRange: NSEvent.modifierFlags.contains(.shift))
                    }
                    .onKeyPress(.space) {
                        tap(index, extendsRange: false)
                        return .handled
                    }
                }
            }
        }
        .focusable()
        // Edit > Select All (⌘A) reaches the grid only while it has focus; text fields keep their own.
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            model.selection.selectAll()
        }
        .focusedValue(\.gridSelection, GridSelectionActions(
            selectAll: { model.selection.selectAll() },
            deselectAll: { model.selection.deselectAll() }
        ))
    }

    private func tap(_ index: Int, extendsRange: Bool) {
        focusedIndex = index
        if extendsRange, let anchor {
            selectRange(from: anchor, to: index)
        } else if let item = browser.item(at: index) {
            model.selection.toggle(item.id)
        }
        anchor = index
    }

    /// Selects every item between two positions. Items on pages still loading are added as their pages arrive.
    private func selectRange(from start: Int, to end: Int) {
        rangeTask?.cancel()
        let browser = browser
        let model = model
        let lower = min(start, end)
        let upper = max(start, end)
        rangeTask = Task { @MainActor in
            var pending = Array(lower...upper)
            // About 45 seconds at most; the pages normally arrive in well under a second.
            for _ in 0..<300 {
                var ids: [String] = []
                var missing: [Int] = []
                for index in pending {
                    if let item = browser.item(at: index) {
                        ids.append(item.id)
                    } else {
                        missing.append(index)
                    }
                }
                model.selection.select(ids)
                if missing.isEmpty || Task.isCancelled { return }
                pending = missing
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }
}

/// One cell of the grid. Selected cells get an accent ring and checkmark; unselected cells look normal.
private struct LibraryTile: View {
    let item: LibraryItem?
    let isSelected: Bool
    let browser: LibraryBrowser
    @State private var image: NSImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if item?.isVideo == true {
                    Image(systemName: "video.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(4)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                selectionMark
                    .padding(4)
            }
            .overlay {
                if isSelected {
                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .contentShape(Rectangle())
            .task(id: item?.id) {
                guard let item else {
                    image = nil
                    return
                }
                image = await browser.thumbnail(for: item, pixelSize: CGSize(width: 256, height: 256))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var selectionMark: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        guard let item else { return "Loading" }
        var label = item.filename
        if let created = item.created {
            label += ", " + created.formatted(date: .abbreviated, time: .shortened)
        }
        if item.isVideo {
            label += ", video"
        }
        return label
    }
}
