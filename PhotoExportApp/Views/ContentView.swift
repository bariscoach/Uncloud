import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            DestinationHeader()
            Divider()
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            Divider()
            ActivitySection()
                .padding()
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 560)
        .fileImporter(isPresented: $model.isChoosingDestination, allowedContentTypes: [.folder]) { result in
            model.chooseDestination(result)
        }
        .onAppear {
            model.refreshAuthorization()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user may have changed Photos access in System Settings.
            model.refreshAuthorization()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if model.isPhotosAccessBlocked {
            PhotosAccessView()
        } else if model.destination == nil {
            ContentUnavailableView {
                Label("No Destination Folder", systemImage: "folder")
            } description: {
                Text("Choose a folder or external drive to save your photos and videos to.")
            } actions: {
                Button("Choose Folder…") {
                    model.isChoosingDestination = true
                }
            }
        } else {
            VStack(spacing: 16) {
                if model.authorization == .limited {
                    LimitedAccessNotice()
                }
                ProgressCard()
                ExportControls()
            }
            .frame(maxWidth: 520)
        }
    }
}
