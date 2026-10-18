import SwiftUI

/// The Activity log, collapsed by default. In the Backup pane it is a disclosure row after the History section
/// (`asRow: true`), and its label is plain text. Without `asRow` it keeps the section-header label it always had.
struct ActivitySection: View {
    @Environment(ExportModel.self) private var model
    @AppStorage("activityExpanded") private var isExpanded = false
    var asRow = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Group {
                if model.activity.isEmpty {
                    Text("No activity yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.activity) { entry in
                        ActivityRow(entry: entry)
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                }
            }
            .frame(minHeight: 120, maxHeight: 240)
            .padding(.top, 8)
        } label: {
            if asRow {
                Text("Activity")
            } else {
                SectionTitle("Activity")
            }
        }
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(entry.message)
                .textSelection(.enabled)
            Spacer()
            Text(entry.date, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning, .error: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
