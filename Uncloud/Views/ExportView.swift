import AppKit
import SwiftUI

/// The Export pane: the whole library as a grid to choose from, or the state that replaces it.
struct ExportView: View {
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
        // The count sits under the title rather than among the buttons, so it doesn't read as a control.
        .navigationSubtitle(countText)
        .toolbar {
            if model.isSourceReady, let browser = model.browser {
                ExportToolbar(browser: browser)
            }
        }
    }

    /// The selection count and estimated size, shown as the window's subtitle. Empty until the library's count is known.
    private var countText: String {
        guard model.isSourceReady, let total = model.browser?.count else { return "" }
        let selected = model.selection.selectedCount(total: total)
        var count = model.selection.isEverything
            ? "All \(Plural.photos(total)) selected"
            : "\(selected.formatted()) of \(total.formatted()) selected"
        // "· 1,243 not backed up" when the primary action exports only those.
        if let notBackedUp = model.notBackedUpSummary {
            count += " · \(notBackedUp)"
        }
        // The estimated size, such as "· about 412 GB", once anything is selected.
        guard selected > 0, let size = model.storageEstimateText else { return count }
        return "\(count) · \(size)"
    }
}

/// The toolbar of the Export pane: Select All or Deselect All, export progress, and the primary button in its own group.
private struct ExportToolbar: ToolbarContent {
    @Environment(ExportModel.self) private var model
    let browser: LibraryBrowser

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // One text button: Deselect All when everything is selected, otherwise Select All.
            if model.selection.isEverything {
                Button("Deselect All") {
                    model.selection.deselectAll()
                }
                .disabled(model.selection.isNothing)
            } else {
                Button("Select All") {
                    model.selection.selectAll()
                }
                .disabled(browser.count == nil)
            }
        }

        if model.isExporting {
            ToolbarItem(placement: .primaryAction) {
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
        } else if model.autoResume != nil {
            ToolbarItem(placement: .primaryAction) {
                // The export stopped for a while, such as Apple limiting downloads; Backup has the details.
                Button {
                    model.pane = .backup
                } label: {
                    Label {
                        Text("Waiting to Resume")
                    } icon: {
                        // Only the icon carries the warning colour; the title stays the toolbar's normal colour.
                        Image(systemName: "clock")
                            .foregroundStyle(.orange)
                    }
                }
                .help("Resumes on its own. Click to see why.")
                .accessibilityLabel("Export waiting to resume. Show Backup.")
            }
        }

        // Separates the primary action into its own glass group on macOS 26. Older systems don't need the gap.
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            Button(model.primaryExportTitle(total: total)) {
                model.performPrimaryAction()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.primaryExportEnabled(total: total))
            .help(model.primaryExportHelp ?? "")
            .accessibilityHint(model.primaryExportHelp ?? "")
        }
    }

    private var total: Int? { browser.count }
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
                    Label("Sign In to iCloud Again", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("Your iCloud sign-in has expired.")
                } actions: {
                    Button("Sign In to iCloud…") {
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
            // The library may have new photos since the last count, or the source may have changed.
            model.refreshNewPhotos()
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
                    Text("Loading your library…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 2)], spacing: 2) {
                    ForEach(0..<30, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: Tokens.Radius.s)
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
