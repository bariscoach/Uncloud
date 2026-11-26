import SwiftUI

/// Settings › License. Enter a key, or open pricing. No account.
struct LicenseSettingsForm: View {
    @State private var key = ""
    @State private var status = ""
    @State private var stored: StoredLicense?
    @State private var isActivating = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Plan", value: planTitle)
                if let stored {
                    LabeledContent("Macs", value: stored.seats == 1 ? "1 Mac" : "\(stored.seats) Macs")
                    if !stored.confirmedOnline {
                        Text("Saved on this Mac. Uncloud will confirm it hasn’t been refunded the next time you’re online.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No license key on this Mac. The free app does not need an account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("License Key") {
                TextField("License key", text: $key)
                    .textFieldStyle(.roundedBorder)
                Button("Activate") {
                    Task { await activate() }
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating)
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if stored != nil {
                    Button("Remove License", role: .destructive) {
                        LicenseStore.current.clear()
                        stored = nil
                        status = "Removed from this Mac."
                    }
                }
            }

            Section("Upgrade") {
                ForEach(LicenseTier.paid) { tier in
                    LabeledContent(tier.displayName) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(tier.priceLabel)
                                .foregroundStyle(.secondary)
                            if let url = LicenseCheckout.url(for: tier) {
                                Link("Buy \(tier.displayName)", destination: url)
                            } else {
                                Text("Checkout isn’t connected yet.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Link("See pricing", destination: LicenseLinks.pricing)
            }

            if !LicenseGating.isEnforced() {
                Section {
                    Text("Feature limits are off in this build, so nothing you can use today is locked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { stored = LicenseStore.current.load() }
    }

    private var planTitle: String {
        guard let stored else { return LicenseTier.free.displayName }
        return stored.tier.displayName
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
            stored = license
            key = ""
            status = license.confirmedOnline
                ? "\(license.tier.displayName) is active on this Mac."
                : "Saved on this Mac. Uncloud couldn’t confirm the key online."
        case .rejected(let message):
            status = message
        }
    }
}
