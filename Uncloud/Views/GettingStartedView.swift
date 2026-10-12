import SwiftUI

/// Help > Getting Started: the same three steps and privacy note as the landing page.
struct GettingStartedView: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Getting Started")
                .font(.title2.weight(.semibold))
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HowItWorksSteps()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Why Uncloud")
                            .font(.headline)
                        BenefitsGrid()
                    }
                    PrivacyNote(showsLearnMore: false)
                    Text("Diagnostic logs stay on this Mac. When you report a problem, you can share them from Help > Show Diagnostic Logs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .frame(width: 460, height: 560)
    }
}
