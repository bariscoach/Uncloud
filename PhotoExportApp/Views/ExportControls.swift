import SwiftUI

/// Keyboard shortcuts for these actions live in `ExportCommands`.
struct ExportControls: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        HStack {
            Button {
                model.cancel()
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .disabled(!model.canCancel)

            Button {
                model.pause()
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .disabled(!model.canPause)

            Spacer()

            Button {
                model.startOrResume()
            } label: {
                Label(model.startTitle, systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canStart)
        }
        .controlSize(.large)
    }
}
