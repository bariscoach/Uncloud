import SwiftUI

/// Shared wording for plan dates and the renewal terms, so the paywall, Settings and the locked panes say the same thing.
enum PlanText {
    /// "October 18, 2027". The locale and time zone are parameters so tests can pin them.
    static func date(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        date.formatted(zoned(Date.FormatStyle(date: .long, time: .omitted), locale: locale, timeZone: timeZone))
    }

    /// The style with the locale and time zone set, for the tests' pinned output.
    static func zoned(_ style: Date.FormatStyle, locale: Locale, timeZone: TimeZone) -> Date.FormatStyle {
        var style = style
        style.locale = locale
        style.timeZone = timeZone
        return style
    }

    /// "October 18", for the places that name a day without a year.
    static func monthDay(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        date.formatted(zoned(Date.FormatStyle().month(.wide).day(), locale: locale, timeZone: timeZone))
    }

    /// The date a year from now: when a purchase made today renews or ends.
    static func oneYearFromNow(_ now: Date = .now) -> String {
        date(Calendar.current.date(byAdding: .year, value: 1, to: now) ?? now)
    }

    /// The plain renewal terms shown next to the button, for the choice in effect.
    static func renewalTerms(_ renewal: Renewal, now: Date = .now) -> String {
        switch renewal {
        case .automatic:
            "Renews at \(PlanCopy.yearlyPricePlusTax) on \(oneYearFromNow(now)). Turn off anytime in Settings."
        case .oneYear:
            "One year at \(PlanCopy.onePricePlusTax). Ends on \(oneYearFromNow(now)) and won’t renew unless you turn renewal on."
        }
    }
}

/// The paywall: what Uncloud Plus adds, the two renewal choices and Checkout (plan §5.2). Opened by a locked feature,
/// or from Settings. It waits while the browser has Checkout open, then says so when the plan is on.
struct PaywallSheet: View {
    let request: PaywallRequest
    @Environment(AccountModel.self) private var account
    @Environment(\.uncloudAccent) private var accent
    /// Remembered between paywalls. "Renew automatically" is the default (orchestrator decision 1).
    @AppStorage("uncloudPaywallRenewal") private var renewal: Renewal = .automatic
    /// Set when "Refresh" found no plan for the account.
    @State private var refreshFoundNoPlan = false

    static let width: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            header
            if let feature = request.feature {
                Text("\(feature.paywallTitle) is part of Uncloud Plus.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Keep your backup safe, tidy and up to date, on its own.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            featureList
            Divider()
            checkoutBody
            if case let .failed(error) = account.checkout {
                Label(error.message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Tokens.Status.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(Tokens.Sheet.padding)
        .frame(width: Self.width)
        .onChange(of: account.checkout) { _, checkout in
            // A new checkout attempt clears the "no plan found" note.
            if checkout == .opening { refreshFoundNoPlan = false }
        }
    }

    // MARK: - Header and features

    private var header: some View {
        HStack(alignment: .center, spacing: Tokens.Space.m) {
            AppLogo(size: 52)
                .accessibilityHidden(true)
            Text("Get Uncloud Plus")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var featureList: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
            alignment: .leading,
            spacing: Tokens.Space.s
        ) {
            ForEach(PaidFeature.allCases) { feature in
                let isOpening = feature == request.feature
                HStack(spacing: Tokens.Space.s) {
                    Image(systemName: feature.symbol)
                        .foregroundStyle(accent ?? .accentColor)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(feature.paywallTitle)
                        .font(.callout.weight(isOpening ? .semibold : .regular))
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Body by checkout state

    @ViewBuilder
    private var checkoutBody: some View {
        switch account.checkout {
        case .idle, .failed:
            renewalChoices
        case .opening:
            renewalChoices
                .disabled(true)
        case let .waiting(processing):
            waitingBody(processing: processing)
        case .active:
            activeBody
        }
    }

    private var renewalChoices: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                RenewalOptionRow(
                    title: "Renew automatically every year",
                    price: PlanCopy.yearlyPricePlusTax,
                    caption: "Renews each year until you turn it off.",
                    spokenLabel: "Renew automatically every year, \(PlanCopy.yearlyPrice) plus tax",
                    isSelected: renewal == .automatic,
                    action: { renewal = .automatic }
                )
                RenewalOptionRow(
                    title: "One year, no auto-renewal",
                    price: PlanCopy.onePricePlusTax,
                    caption: "Uncloud Plus ends after a year unless you renew.",
                    spokenLabel: "One year, no auto-renewal, \(PlanCopy.price) plus tax",
                    isSelected: renewal == .oneYear,
                    action: { renewal = .oneYear }
                )
            }
            .onKeyPress(.upArrow) {
                renewal = .automatic
                return .handled
            }
            .onKeyPress(.downArrow) {
                renewal = .oneYear
                return .handled
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Renewal")
            .accessibilityHint("Choose whether Uncloud Plus renews every year.")

            // The plain terms sit next to the button they apply to.
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text(PlanText.renewalTerms(renewal))
                    .font(Tokens.Font.help)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Pay with card, Apple Pay or Google Pay on Stripe’s secure checkout page. Tax is added at checkout.")
                    .font(Tokens.Font.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func waitingBody(processing: Bool) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Label {
                Text("Finish checking out in your browser, then come back here.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.up.forward.app")
                    .foregroundStyle(accent ?? .accentColor)
            }
            if processing {
                Label {
                    Text("Payment is still processing. This can take a minute.")
                        .font(Tokens.Font.help)
                        .foregroundStyle(.secondary)
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if refreshFoundNoPlan {
                Text("No plan yet. If you finished checking out, give it a moment, then check again.")
                    .font(Tokens.Font.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Tokens.Space.s)
    }

    private var activeBody: some View {
        VStack(spacing: Tokens.Space.s) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(Tokens.Status.success)
                .accessibilityHidden(true)
            Text("You’re all set")
                .font(.title3.weight(.semibold))
            Text(activeSentence)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Space.s)
    }

    /// "Uncloud Plus is on and renews on …", or "… is on until …" when the plan won't renew.
    private var activeSentence: String {
        let entitlement = account.entitlement
        guard let end = entitlement.currentPeriodEnd else {
            return "Uncloud Plus is on."
        }
        let date = PlanText.date(end)
        return entitlement.cancelAtPeriodEnd
            ? "Uncloud Plus is on until \(date)."
            : "Uncloud Plus is on and renews on \(date)."
    }

    // MARK: - Footer

    /// The buttons on the right, and the refresh link on its own line below them, so nothing wraps or truncates.
    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            HStack(spacing: Tokens.Space.s) {
                Spacer(minLength: Tokens.Space.s)
                buttons
            }
            .controlSize(Tokens.Sheet.footerControlSize)
            if account.checkout != .active {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
                    Button("Already Subscribed? Refresh") {
                        Task {
                            await account.refreshEntitlement(force: true)
                            refreshFoundNoPlan = account.access == .free
                        }
                    }
                    .buttonStyle(.link)
                    .fixedSize()
                    .help("Looks up your plan again.")
                    if refreshFoundNoPlan, case .idle = account.checkout {
                        Text("We couldn’t find a plan for \(account.account?.email ?? "this account").")
                            .font(Tokens.Font.meta)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch account.checkout {
        case .idle, .failed:
            Button("Not Now") {
                account.dismissPaywall()
            }
            .keyboardShortcut(.cancelAction)
            Button("Continue to Checkout") {
                Task { await account.openCheckout(for: request.feature, renewal: renewal) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .opening:
            HStack(spacing: Tokens.Space.s) {
                ProgressView()
                    .controlSize(.small)
                Text("Opening Checkout…")
                    .foregroundStyle(.secondary)
            }
        case .waiting:
            Button("Not Now") {
                account.dismissPaywall()
            }
            .keyboardShortcut(.cancelAction)
            Button("Open Checkout Again") {
                Task { await account.openCheckout(for: request.feature, renewal: renewal) }
            }
            Button("Check Again") {
                Task {
                    await account.refreshEntitlement(force: true)
                    refreshFoundNoPlan = account.access == .free
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .active:
            Button("Continue") {
                account.finishPaywall()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}
