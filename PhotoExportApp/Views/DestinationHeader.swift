import SwiftUI

struct DestinationHeader: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.destination?.isOnExternalVolume == true ? "externaldrive" : "folder")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Destination")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let destination = model.destination {
                    Text(destination.displayName)
                        .font(.headline)
                    Text(destination.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text("No folder chosen")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                if let issue = model.destinationIssue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            if model.destination != nil {
                Button {
                    model.revealDestination()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }

            Button("Choose…") {
                model.isChoosingDestination = true
            }
            .disabled(model.isExporting)
        }
        .padding()
    }
}
