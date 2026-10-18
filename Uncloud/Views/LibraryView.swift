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
            } else if model.autoResume != nil {
                // The export stopped for a while, such as Apple limiting downloads; Backup has the details.
                Button {
                    model.pane = .backup
                } label: {
                    Label("Waiting to resume", systemImage: "clock")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.orange)
                }
                .help("The export resumes automatically. Show Backup for details.")
                .accessibilityLabel("Export waiting to resume. Show Backup.")
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
                if browser.count != nil {
                    LibraryGrid(browser: browser, selection: selectionBinding)
                } else {
                    loading
                }
            }
        }
        .task(id: ObjectIdentifier(browser)) {
            browser.load()
        }
        // Apple finishes indexing by itself, so the library is checked again every five minutes while
        // this is shown. Ending the state (the reload) cancels the task.
        .task(id: browser.isWaitingForIndexing) {
            guard browser.isWaitingForIndexing else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if !Task.isCancelled, NSApplication.shared.isActive {
                    browser.reload()
                }
            }
        }
    }

    private var selectionBinding: Binding<LibrarySelection> {
        Binding(
            get: { model.selection },
            set: { model.selection = $0 }
        )
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
}
