import SwiftUI

/// Help › Getting Started: the same three steps, benefits and privacy note as the landing page.
/// The benefits are a plain list here.
struct GettingStartedView: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        SheetScaffold("Getting Started", width: 460) {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.section) {
                    HowItWorksSteps()
                    VStack(alignment: .leading, spacing: Tokens.Space.l) {
                        Text("Why Uncloud")
                            .font(.headline)
                        ForEach(Benefit.all) { benefit in
                            BenefitRow(benefit: benefit)
                        }
                    }
                    PrivacyNote(showsLearnMore: false)
                    Text("Diagnostic logs stay on this Mac. When you report a problem, you can share them from Help › Show Diagnostic Logs in Finder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // The sheet already pads by Tokens.Sheet.padding (20); this brings the reading column to 24.
                .padding(.horizontal, Tokens.Space.xs)
                .padding(.bottom, Tokens.Space.s)
            }
            .frame(maxHeight: .infinity)
        } buttons: {
            Button("Done") {
                model.introSheet = nil
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .frame(height: 560)
    }
}
