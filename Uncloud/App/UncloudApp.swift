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

    init() {
        let model = ExportModel()
        let settings = AutoBackupSettings()
        let controller = AutoBackupController(model: model, settings: settings)
        controller.start()
        #if DEBUG
        HelperProbe.runIfRequested()
        #endif
        _backupTools = State(initialValue: BackupTools(model: model))
        _model = State(initialValue: model)
        _settings = State(initialValue: settings)
        _controller = State(initialValue: controller)
    }

    var body: some Scene {
        Window("Uncloud", id: "main") {
            LibraryWindow()
                .backupToolSheets()
                .environment(model)
                .environment(backupTools)
        }
        .windowResizability(.contentMinSize)
        .commands {
            ExportCommands(model: model, tools: backupTools)
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(settings)
        }

        MenuBarExtra("Uncloud", systemImage: "photo.on.rectangle.angled", isInserted: showsMenuBarItem) {
            MenuBarContent()
                .environment(model)
                .environment(settings)
        }
        .menuBarExtraStyle(.menu)
    }

    /// The menu bar item shows only when the user wants it and automatic backup is on.
    private var showsMenuBarItem: Binding<Bool> {
        let settings = settings
        return Binding(
            get: { settings.showInMenuBar && settings.isEnabled },
            set: { settings.showInMenuBar = $0 }
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // While automatic backup is on, the app keeps running in the menu bar.
        !AutoBackupSettings.isEnabledInDefaults
    }
}
