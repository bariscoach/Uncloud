import SwiftUI

/// Menu bar commands. The app menu (About, Quit) comes from the system.
struct ExportCommands: Commands {
    let model: ExportModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Choose Destination…") {
                model.isChoosingDestination = true
            }
            .keyboardShortcut("o")
            .disabled(model.isExporting)
        }

        CommandMenu("Export") {
            Button(model.startTitle) {
                model.startOrResume()
            }
            .keyboardShortcut("r")
            .disabled(!model.canStart)

            Button("Pause") {
                model.pause()
            }
            .disabled(!model.canPause)

            Divider()

            Button("Cancel Export") {
                model.cancel()
            }
            .keyboardShortcut(".")
            .disabled(!model.canCancel)
        }
    }
}
