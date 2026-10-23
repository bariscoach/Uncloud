import AppKit
import SwiftUI

/// The main window: a sidebar of the panes in `ExportModel.Pane` order, and the selected pane in the detail.
struct MainWindow: View {
    @Environment(ExportModel.self) private var model
    @Environment(BackupTools.self) private var backupTools
    @Environment(AccountModel.self) private var account

    var body: some View {
        @Bindable var model = model
        @Bindable var account = account

        NavigationSplitView {
            PaneSidebar(selection: paneSelection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            // The one account control: the Uncloud account and the photo source, in one popover (plan §6.2).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    AccountFooterRow()
                }
            }
        } detail: {
            switch model.pane {
            case .export:
                ExportView()
                    .navigationTitle(model.source.title)
            case .backup:
                ExportSettingsPane()
                    .navigationTitle(ExportModel.Pane.backup.title)
            case .tools:
                ToolsPane()
                    .navigationTitle(ExportModel.Pane.tools.title)
            case .cleanup:
                // Delete from iCloud is the Uncloud Plus feature; while a run is going, its grid stays open after a lapse.
                if Self.showsCleanup(allowed: account.allows(.cleanUpICloud), isRunning: model.iCloudCleanup?.isRunning == true) {
                    CleanupView()
                        .navigationTitle(ExportModel.Pane.cleanup.title)
                } else {
                    LockedFeatureView(feature: .cleanUpICloud)
                        .navigationTitle(ExportModel.Pane.cleanup.title)
                }
            case .browse:
                if account.allows(.browseBackup) {
                    BrowseBackupView(browse: backupTools.browse)
                        .navigationTitle(ExportModel.Pane.browse.title)
                } else {
                    LockedFeatureView(feature: .browseBackup)
                        .navigationTitle(ExportModel.Pane.browse.title)
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
            ExportRangeSheet()
        }
        .sheet(item: $model.introSheet) { sheet in
            switch sheet {
            case .gettingStarted:
                GettingStartedView()
            }
        }
        // The one sign-out confirmation; the account popover and the File menu both open it.
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

    /// Delete from iCloud shows its grid when the plan allows it, or while a run already in progress needs it to stay open
    /// after a lapse (plan §5.5). Otherwise the pane is the locked view.
    static func showsCleanup(allowed: Bool, isRunning: Bool) -> Bool {
        allowed || isRunning
    }

    /// Tools is locked only when none of its three tools is allowed. A free account sees the row locked, and the pane shows the cards (D5).
    static func toolsLocked(allows: (PaidFeature) -> Bool) -> Bool {
        !(allows(.verifyBackup) || allows(.findDuplicates) || allows(.freeUpSpace))
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
}

/// The sidebar's list: the brand header, then the pane rows. The header is list content rather than an inset, so the
/// list starts below the titlebar and the header never ends up under the traffic lights.
struct PaneSidebar: View {
    @Binding var selection: ExportModel.Pane?

    var body: some View {
        List(selection: $selection) {
            SidebarBrandHeader()
                .selectionDisabled()
            SidebarPaneRows()
        }
        // The header and rows fit at the window's minimum height, so the list never scrolls: scrolled rows would slide
        // under the titlebar and its window buttons.
        .scrollDisabled(true)
    }
}

/// The five pane rows, in `ExportModel.Pane` order, with a break before Tools. The sidebar's `List` holds it, and the
/// snapshot tests render it.
struct SidebarPaneRows: View {
    @Environment(ExportModel.self) private var model
    @Environment(AccountModel.self) private var account

    var body: some View {
        ForEach(ExportModel.Pane.allCases, id: \.self) { pane in
            // The break sets the free-up-iCloud steps apart from the utilities and settings that follow.
            if pane == .tools {
                Divider()
            }
            row(for: pane).tag(pane)
        }
    }

    /// One sidebar row. Export Settings keeps its progress badge; the paid panes show a lock while locked (plan §1.1).
    @ViewBuilder
    private func row(for pane: ExportModel.Pane) -> some View {
        switch pane {
        case .export:
            Label(pane.title, systemImage: pane.symbol)
        case .backup:
            Label(pane.title, systemImage: pane.symbol)
                .badge(progressBadge ?? model.newPhotosBadgeText)
                // Increased prominence makes the percentage a coloured capsule while an export runs.
                .badgeProminence(model.isExporting ? .increased : .standard)
                // Badges may not be spoken, so the value carries the same news for VoiceOver.
                .accessibilityValue(backupAccessibilityValue)
        case .browse:
            LockableSidebarRow(title: pane.title, symbol: pane.symbol, isLocked: !account.allows(.browseBackup))
        case .tools:
            LockableSidebarRow(title: pane.title, symbol: pane.symbol, isLocked: MainWindow.toolsLocked(allows: { account.allows($0) }))
        case .cleanup:
            LockableSidebarRow(title: pane.title, symbol: pane.symbol, isLocked: !account.allows(.cleanUpICloud))
        }
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
