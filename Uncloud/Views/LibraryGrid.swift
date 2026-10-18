import AppKit
import SwiftUI

/// Which backup state the grid's selection and dimming follow, for Clean Up iCloud.
enum BackupFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case backedUp
    case notBackedUp

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .backedUp: "Backed Up"
        case .notBackedUp: "Not Backed Up"
        }
    }

    func allows(_ id: String, backedUp: Set<String>) -> Bool {
        switch self {
        case .all: true
        case .backedUp: backedUp.contains(id)
        case .notBackedUp: !backedUp.contains(id)
        }
    }

    /// The selection that matches this filter across the whole library, for Select All.
    func selection(backedUp: Set<String>) -> LibrarySelection {
        switch self {
        case .all: .everything
        case .backedUp: .only(backedUp)
        case .notBackedUp: .allExcept(backedUp)
        }
    }
}

/// The library as a lazy grid of thumbnails that can be selected, with tap, Shift-click range, Space and ⌘A.
/// The Library pane and Clean Up iCloud both show it; each passes its own selection.
struct LibraryGrid: View {
    let browser: LibraryBrowser
    @Binding var selection: LibrarySelection
    /// What Select All (⌘A and the Select menu) selects. Everything, unless a filter narrows it.
    var selectAll: LibrarySelection = .everything
    /// The IDs backed up on the current destination. Nil hides the badges.
    var backedUp: Set<String>?
    /// Tiles the filter doesn't allow are dimmed. Nil dims nothing.
    var filter: BackupFilter?

    @FocusState private var focusedIndex: Int?
    /// The last tile clicked, the start of a shift-click range.
    @State private var anchor: Int?
    @State private var rangeTask: Task<Void, Never>?

    var body: some View {
        if let count = browser.count {
            grid(count: count)
        }
    }

    /// The library as a lazy grid. Every cell asks for its own item, so nothing is materialized up front.
    private func grid(count: Int) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 2)], spacing: 2) {
                ForEach(0..<count, id: \.self) { index in
                    let item = browser.item(at: index)
                    LibraryTile(
                        item: item,
                        isSelected: item.map { selection.contains($0.id) } ?? false,
                        isDimmed: item.map { item in
                            filter.map { !$0.allows(item.id, backedUp: backedUp ?? []) } ?? false
                        } ?? false,
                        backedUp: item.map { item in backedUp?.contains(item.id) ?? false } ?? false,
                        showsBackedUpBadge: backedUp != nil,
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
            selection = selectAll
        }
        .focusedValue(\.gridSelection, GridSelectionActions(
            selectAll: { selection = selectAll },
            deselectAll: { selection = .only([]) }
        ))
    }

    private func tap(_ index: Int, extendsRange: Bool) {
        focusedIndex = index
        if extendsRange, let anchor {
            selectRange(from: anchor, to: index)
        } else if let item = browser.item(at: index) {
            selection.toggle(item.id)
        }
        anchor = index
    }

    /// Selects every item between two positions. Items on pages still loading are added as their pages arrive.
    private func selectRange(from start: Int, to end: Int) {
        rangeTask?.cancel()
        let browser = browser
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
                selection.select(ids)
                if missing.isEmpty || Task.isCancelled { return }
                pending = missing
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }
}

/// One cell of the grid. Selected cells get an accent ring and checkmark; unselected cells look normal.
/// Backed-up items get a small badge, which is information only.
private struct LibraryTile: View {
    let item: LibraryItem?
    let isSelected: Bool
    let isDimmed: Bool
    let backedUp: Bool
    let showsBackedUpBadge: Bool
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
            .overlay(alignment: .bottomTrailing) {
                if showsBackedUpBadge, backedUp {
                    // Information only: the item is already in the backup. Text, since a symbol alone reads as something else.
                    Text("Backed Up")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
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
            .opacity(isDimmed ? 0.4 : 1)
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
        if showsBackedUpBadge, backedUp {
            label += ", backed up"
        }
        return label
    }
}
