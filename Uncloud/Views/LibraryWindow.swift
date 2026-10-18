import AppKit
import SwiftUI

/// The main window: a sidebar with the Library and Backup panes, and the selected pane in the detail.
struct LibraryWindow: View {
    @Environment(ExportModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// True while the "Export started" banner is up over the Library.
    @State private var showsExportStarted = false

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(selection: paneSelection) {
                Label {
                    Text("Library")
                } icon: {
                    IconTile(symbol: "photo.stack", tint: .purple)
                }
                .tag(ExportModel.Pane.library)

                Label {
                    Text("Backup")
                } icon: {
                    IconTile(symbol: "externaldrive", tint: .teal)
                }
                .badge(progressBadge)
                // Increased prominence makes the percentage a coloured capsule while an export runs.
                .badgeProminence(model.isExporting ? .increased : .standard)
                .tag(ExportModel.Pane.backup)

                Label {
                    Text("Clean Up iCloud")
                } icon: {
                    IconTile(symbol: "trash", tint: .red)
                }
                .tag(ExportModel.Pane.cleanup)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                accountFooter
            }
        } detail: {
            switch model.pane {
            case .library:
                LibraryView()
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if showsExportStarted {
                            ExportStartedBanner(
                                onShowBackup: { model.pane = .backup },
                                onClose: { showsExportStarted = false }
                            )
                            .transition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : .smooth, value: showsExportStarted)
            case .backup:
                BackupPane()
            case .cleanup:
                CleanupView()
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .fileImporter(isPresented: $model.isChoosingDestination, allowedContentTypes: [.folder]) { result in
            model.chooseDestination(result)
        }
        .sheet(isPresented: $model.isShowingICloudSignIn) {
            ICloudSignInSheet()
        }
        .sheet(item: $model.introSheet) { sheet in
            switch sheet {
            case .gettingStarted:
                GettingStartedView()
            }
        }
        // The one sign-out confirmation; the sidebar footer and the File menu both open it.
        .confirmationDialog("Sign Out of iCloud?", isPresented: $model.isConfirmingICloudSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                model.signIn.signOut()
            }
        } message: {
            Text("Uncloud forgets this Apple ID and its saved password. Files already in your folder aren’t changed.")
        }
        .onAppear {
            model.refreshAuthorization()
        }
        .onChange(of: model.isExporting) { _, isExporting in
            // Only exports the user starts from the Library get the banner. Backup runs and automatic backups don't.
            guard isExporting, model.pane == .library, !startedAutomatically else { return }
            showsExportStarted = true
            AccessibilityNotification.Announcement("Export started. Track its progress in Backup.").post()
        }
        .onChange(of: model.pane) { _, pane in
            if pane == .backup {
                showsExportStarted = false
            }
        }
        .task(id: showsExportStarted) {
            // Goes away on its own after a few seconds. Restarting the task when it's shown again resets the timer.
            guard showsExportStarted else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled {
                showsExportStarted = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user may have changed Photos access in System Settings, or accepted Apple's updated iCloud terms.
            model.refreshAuthorization()
            if model.source == .iCloud, case let .failed(message)? = model.browser?.state,
               message == ICloudFailure.setupIncomplete.message || message == ICloudFailure.libraryIndexing.message {
                model.browser?.reload()
            }
        }
    }

    /// The sidebar selection. The list never clears it, so the optional is only a SwiftUI requirement.
    private var paneSelection: Binding<ExportModel.Pane?> {
        Binding(
            get: { model.pane },
            set: { pane in
                if let pane {
                    model.pane = pane
                }
            }
        )
    }

    /// True when the run that just started was an automatic backup or an automatic resume, which shouldn't announce itself.
    private var startedAutomatically: Bool {
        model.isAutomaticRunInProgress || model.isAutoResumedRunInProgress
    }

    /// The export percentage on the Backup row while an export runs.
    private var progressBadge: Text? {
        guard model.isExporting else { return nil }
        return Text("\(Int(model.fractionComplete * 100))%")
    }

    /// The source and account: switch source, and sign in or out of iCloud. This is the only place for them.
    private var accountFooter: some View {
        Menu {
            Picker("Source", selection: sourceSelection) {
                ForEach(LibrarySource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.inline)
            .disabled(model.isExporting)

            if model.source == .iCloud {
                Divider()
                if model.iCloudAppleID != nil {
                    Button("Sign Out…") {
                        model.isConfirmingICloudSignOut = true
                    }
                    .disabled(!model.canSignOutICloud)
                } else {
                    Button("Sign In…") {
                        model.isShowingICloudSignIn = true
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                IconTile(
                    symbol: model.source == .iCloud ? "icloud" : "photo.on.rectangle",
                    tint: model.source == .iCloud ? .blue : .pink
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(accountSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .padding(12)
        .accessibilityLabel("Source and account, \(accountTitle), \(accountSubtitle)")
        .help("Switch source or change the iCloud account")
    }

    /// Source changes are disabled while an export runs, so the picker can't revert under the user.
    private var sourceSelection: Binding<LibrarySource> {
        Binding(
            get: { model.source },
            set: { model.source = $0 }
        )
    }

    private var accountTitle: String {
        switch model.source {
        case .iCloud:
            model.iCloudAppleID ?? LibrarySource.iCloud.title
        case .photosLibrary:
            LibrarySource.photosLibrary.title
        }
    }

    private var accountSubtitle: String {
        switch model.source {
        case .iCloud:
            model.iCloudAppleID == nil ? "Not signed in" : LibrarySource.iCloud.title
        case .photosLibrary:
            model.isSourceReady ? "Ready" : "Access needed"
        }
    }
}

/// A non-modal note across the top of the Library that an export has started. It doesn't take focus or
/// block the grid, and VoiceOver hears it through an announcement when it appears.
private struct ExportStartedBanner: View {
    let onShowBackup: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "arrow.down.circle", tint: .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Export started")
                    .font(.headline)
                Text("Track its progress in Backup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Show Backup", action: onShowBackup)
                .buttonStyle(.bordered)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, minHeight: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
