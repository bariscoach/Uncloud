import AppKit
import SwiftUI

/// The main window: a sidebar with the Backup, Library, Browse Backup and Clean Up panes, and the selected pane in the detail.
struct MainWindow: View {
    @Environment(ExportModel.self) private var model
    @Environment(BackupTools.self) private var backupTools
    @Environment(AccountModel.self) private var account

    var body: some View {
        @Bindable var model = model
        @Bindable var account = account

        NavigationSplitView {
            List(selection: paneSelection) {
                // Backup is the home pane, so it comes first.
                Label("Backup", systemImage: "externaldrive")
                    .badge(progressBadge ?? model.newPhotosBadgeText)
                    // Increased prominence makes the percentage a coloured capsule while an export runs.
                    .badgeProminence(model.isExporting ? .increased : .standard)
                    // Badges may not be spoken, so the value carries the same news for VoiceOver.
                    .accessibilityValue(backupAccessibilityValue)
                    .tag(ExportModel.Pane.backup)

                Label("Library", systemImage: "photo.on.rectangle")
                    .tag(ExportModel.Pane.export)

                // Locked for free accounts: the row stays, with a lock, and choosing it shows the locked view (plan C.3).
                LockableSidebarRow(title: "Browse Backup", symbol: "photo.stack", isLocked: !account.allows(.browseBackup))
                    .tag(ExportModel.Pane.browse)

                // The one destructive pane sits apart from the two backup panes.
                // Locked for free accounts as a whole, like Browse Backup (Clean Up iCloud is Uncloud Plus).
                Section("iCloud") {
                    LockableSidebarRow(title: "Clean Up iCloud", symbol: "icloud", isLocked: !account.allows(.cleanUpICloud))
                        .tag(ExportModel.Pane.cleanup)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                accountFooter
            }
            // The account button sits at the sidebar's trailing titlebar edge, clear of each pane's own toolbar (plan §1.1).
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if account.mode != .off, account.phase == .signedIn {
                        AccountButton()
                    }
                }
            }
        } detail: {
            switch model.pane {
            case .export:
                ExportView()
                    .navigationTitle(model.source.title)
            case .backup:
                BackupPane()
                    .navigationTitle("Backup")
            case .cleanup:
                if Self.showsCleanup(allowed: account.allows(.cleanUpICloud), isRunning: model.iCloudCleanup?.isRunning == true) {
                    CleanupView()
                        .navigationTitle("Clean Up iCloud")
                } else {
                    LockedFeatureView(feature: .cleanUpICloud)
                        .navigationTitle("Clean Up iCloud")
                }
            case .browse:
                if account.allows(.browseBackup) {
                    BrowseBackupView(browse: backupTools.browse)
                        .navigationTitle("Browse Backup")
                } else {
                    LockedFeatureView(feature: .browseBackup)
                        .navigationTitle("Browse Backup")
                }
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        // The paywall for a locked feature, presented from the main window. Not Now or Esc closes it and runs nothing.
        .sheet(item: $account.paywall) { request in
            PaywallSheet(request: request)
                .environment(account)
                .accentVariant(AccentVariant.override)
        }
        .fileImporter(isPresented: $model.isChoosingDestination, allowedContentTypes: [.folder]) { result in
            model.chooseDestination(result)
        }
        .sheet(isPresented: $model.isShowingICloudSignIn) {
            ICloudSignInSheet()
        }
        .sheet(isPresented: $model.isChoosingExportSince) {
            ExportSinceSheet()
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
            Text("Uncloud forgets this Apple Account and its saved password. Your backup isn’t changed.")
        }
        .onAppear {
            model.refreshAuthorization()
        }
        .onChange(of: model.isExporting) { _, isExporting in
            // Only exports the user starts from Export are announced. Backup runs and automatic backups aren't.
            guard isExporting, model.pane == .export, !startedAutomatically else { return }
            AccessibilityNotification.Announcement("Export started. Progress is in Backup.").post()
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

    /// Clean Up iCloud shows its grid when the plan allows it, or while a run already in progress needs it to stay open
    /// after a lapse (plan §5.5). Otherwise the pane is the locked view.
    static func showsCleanup(allowed: Bool, isRunning: Bool) -> Bool {
        allowed || isRunning
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

    /// What the Backup row's badge says, as text: the export percentage while it runs, else the new-photos count.
    private var backupAccessibilityValue: String {
        if model.isExporting {
            return "\(Int(model.fractionComplete * 100)) percent exported"
        }
        guard let status = model.newPhotosStatus, status.count > 0 || status.isAtLeast else { return "" }
        return NewPhotosText.countPhrase(status)
    }

    /// The source and account: switch source, and sign in or out of iCloud. This is also in the File menu.
    private var accountFooter: some View {
        Menu {
            Picker("Photos From", selection: sourceSelection) {
                ForEach(LibrarySource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.inline)
            .disabled(model.isExporting)

            if model.source == .iCloud {
                Divider()
                if model.iCloudAppleID != nil {
                    Button("Sign Out of iCloud…") {
                        model.isConfirmingICloudSignOut = true
                    }
                    .disabled(!model.canSignOutICloud)
                } else {
                    Button("Sign In to iCloud…") {
                        model.isShowingICloudSignIn = true
                    }
                }
            }
        } label: {
            HStack(spacing: Tokens.Space.s) {
                Image(systemName: model.source == .iCloud ? "icloud" : "photo.on.rectangle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
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
        .padding(Tokens.Space.m)
        .accessibilityLabel("Photos from \(accountTitle), \(accountSubtitle)")
        .help("Choose where photos come from, or change the Apple Account used for iCloud Photos")
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
            model.isSourceReady ? "Ready" : "Needs access"
        }
    }
}

/// A sidebar row for a paid pane: the title and symbol, with a lock while it's locked (plan C.3).
struct LockableSidebarRow: View {
    let title: String
    let symbol: String
    let isLocked: Bool

    var body: some View {
        if isLocked {
            HStack {
                Label(title, systemImage: symbol)
                Spacer(minLength: Tokens.Space.s)
                LockGlyph()
            }
            .accessibilityValue("Requires Uncloud Plus")
        } else {
            Label(title, systemImage: symbol)
        }
    }
}
