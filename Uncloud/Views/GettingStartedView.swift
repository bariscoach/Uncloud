import SwiftUI

/// Help > Getting Started: the four things to know about Uncloud.
struct GettingStartedView: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Getting Started")
                .font(.title2.weight(.semibold))
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(OnboardingPage.all) { page in
                        HStack(alignment: .top, spacing: 12) {
                            IconTile(symbol: page.symbol, tint: Self.tint(for: page.id))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(page.title)
                                    .font(.headline)
                                Text(page.message)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            HStack {
                Spacer()
                Button("Done") {
                    model.introSheet = nil
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(width: 460, height: 520)
    }

    /// One colour per row, from the palette used for the sidebar and the empty states.
    private static func tint(for id: Int) -> Color {
        switch id {
        case 0: .purple
        case 1: .teal
        case 2: .green
        default: .blue
        }
    }
}
