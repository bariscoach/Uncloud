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
                VStack(alignment: .leading, spacing: 28) {
                    HowItWorksSteps()
                    Text("Uncloud also resumes after interruptions, verifies your backup, and can back up automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PrivacyNote(showsLearnMore: false)
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
