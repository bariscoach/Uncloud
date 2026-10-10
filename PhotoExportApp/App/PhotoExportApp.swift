import SwiftUI

@main
struct PhotoExportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ExportModel()

    var body: some Scene {
        Window("Photo Export", id: "main") {
            ContentView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            ExportCommands(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
