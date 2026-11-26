import AppKit
import SwiftUI

/// Shown when this Mac has exported its free 1,000 items. Buying does not need an account.
struct LicensePaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var status = ""
    @State private var isActivating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unlock unlimited export")
                .font(.title2.weight(.semibold))
            Text("The first 1,000 photos are free. Further downloads wait for a one-time license. It isn’t a subscription, and it doesn’t need an account.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(LicenseTier.paid) { tier in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tier.displayName).font(.headline)
                        Text(tierDetail(tier))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(tier.priceLabel)
                        .font(.headline)
                    if let url = LicenseCheckout.url(for: tier) {
                        Button("Buy") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            if LicenseCheckout.url(for: .plus) == nil {
                Text("Checkout isn’t connected yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("See pricing", destination: LicenseLinks.pricing)
            }

            Divider()

            Text("Already bought?")
                .font(.headline)
            TextField("License key", text: $key)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Activate") { Task { await activate() } }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating)
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func tierDetail(_ tier: LicenseTier) -> String {
        switch tier {
        case .plus: "Unlimited export on 1 Mac"
        case .pro: "Plus, cleanup, and 2 Macs"
        case .family: "Pro on 5 Macs"
        case .free: ""
        }
    }

    private func activate() async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = LicenseKey.parse(trimmed) else {
            status = LicenseActivation.unrecognized
            return
        }
        isActivating = true
        defer { isActivating = false }
        let remote = await LicenseVerifier.live(baseURL: LicenseVerifier.baseURL()).verify(parsed.key)
        switch LicenseActivation.decide(parsed: parsed, remote: remote) {
        case .saved(let license):
            LicenseStore.current.save(license)
            status = "\(license.tier.displayName) is active on this Mac."
            dismiss()
        case .rejected(let message):
            status = message
        }
    }
}

enum LicenseDeepLink {
    /// `uncloud://license?key=...` from the license email.
    static func key(from url: URL) -> String? {
        guard url.scheme == "uncloud", url.host == "license" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "key" }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
