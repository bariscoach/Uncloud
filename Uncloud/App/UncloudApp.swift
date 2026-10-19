import SwiftUI

/// Unit tests are hosted by this app. Under the test runner, start an empty stand-in instead, so a test
/// run never loads the user's account, settings, destination or library. Tests build their own models.
@main
enum Launcher {
    static func main() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            TestHostApp.main()
        } else {
            UncloudApp.main()
        }
    }
}

struct TestHostApp: App {
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

struct UncloudApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: ExportModel
    @State private var settings: AutoBackupSettings
    @State private var controller: AutoBackupController
    @State private var backupTools: BackupTools
    @State private var account: AccountModel

    init() {
        let model = ExportModel()
        let settings = AutoBackupSettings()
        let controller = AutoBackupController(model: model, settings: settings)
        controller.start()
        AppDelegate.model = model
        // Accounts are off in Release builds, and in Debug they use the preview service (plan A.6).
        let account = AccountModel(configuration: .current)
        AppDelegate.account = account
        #if DEBUG
        HelperProbe.runIfRequested()
        #endif
        _backupTools = State(initialValue: BackupTools(model: model))
        _model = State(initialValue: model)
        _settings = State(initialValue: settings)
        _controller = State(initialValue: controller)
        _account = State(initialValue: account)
    }

    var body: some Scene {
        Window("Uncloud", id: "main") {
            RootView()
                .environment(model)
                .environment(backupTools)
                .environment(account)
                .accentVariant(AccentVariant.override)
        }
        .defaultSize(width: 1000, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            ExportCommands(model: model, tools: backupTools, account: account)
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(settings)
                .accentVariant(AccentVariant.override)
        }

        MenuBarExtra("Uncloud", systemImage: "photo.on.rectangle.angled", isInserted: showsMenuBarItem) {
            MenuBarContent()
                .environment(model)
                .environment(settings)
        }
        .menuBarExtraStyle(.menu)
    }

    /// The menu bar item shows only when the user wants it and automatic backup is on. Never while signed out.
    private var showsMenuBarItem: Binding<Bool> {
        let settings = settings
        let account = account
        return Binding(
            get: { settings.showInMenuBar && settings.isEnabled && account.showsAppMenus },
            set: { settings.showInMenuBar = $0 }
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app's model, so quitting can stop its export first.
    @MainActor static weak var model: ExportModel?
    /// How long quitting waits for the export to stop and record where it got to.
    static let exportStopTimeout: Duration = .seconds(3)
    /// The account, for `uncloud://` links (plan D.4). Set once the app has started.
    @MainActor static weak var account: AccountModel? {
        didSet {
            // A link that arrived before the account existed (a cold start) is handled now.
            guard let account, !pendingURLs.isEmpty else { return }
            let urls = pendingURLs
            pendingURLs = []
            for url in urls {
                account.handle(url)
            }
        }
    }
    @MainActor private static var pendingURLs: [URL] = []

    /// Return from Stripe Checkout and the customer portal arrives here, since the app doesn't use `.onOpenURL`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Task { @MainActor in
                guard let account = Self.account else {
                    Self.pendingURLs.append(url)
                    return
                }
                if account.handle(url) {
                    NSApp.activate()
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // While automatic backup is on, the app keeps running in the menu bar.
        !AutoBackupSettings.isEnabledInDefaults
    }

    /// Quitting mid-export or while paused must not leave icloudpd downloading, or stopped with
    /// SIGSTOP, after the app is gone. Stops the export and every helper and bridge first, in a few
    /// seconds at most, then quits. The run stays marked unfinished, so it resumes after relaunch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let engine = Self.model?.stopForTermination()
        guard engine != nil || ICloudProcesses.areRunning else { return .terminateNow }
        Task { @MainActor in
            await Self.shutDown(engine: engine)
            // The export history's last write (the run ended as interrupted) goes to the drive before quitting.
            _ = await Task { await Self.model?.flushSessionWrites() }.value(timeout: Self.exportStopTimeout)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Normally nothing is left by now; kill whatever is, such as a helper started meanwhile.
        ICloudHelperProcess.runningHelpers.forEach { $0.terminate(); $0.kill() }
        ICloudBridge.runningBridges.forEach { $0.terminate(); $0.kill() }
    }

    /// Stops an export's engine (cancelled already) and every helper and bridge process, each wait
    /// bounded: the engine records what it finished as it stops, and the processes get SIGCONT and
    /// SIGTERM, then SIGKILL.
    static func shutDown(engine: Task<Void, Never>?) async {
        async let processes: Void = ICloudProcesses.shutDownAll()
        if let engine {
            _ = await engine.value(timeout: exportStopTimeout)
        }
        await processes
    }
}
