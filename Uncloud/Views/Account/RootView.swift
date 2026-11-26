import SwiftUI

/// The main window. An Uncloud account is optional, so signed-out people get the same window as everyone else.
/// Sign-in is a sheet from Settings, not a gate in front of export, backup, browse or verify.
struct RootView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ExportModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var licenseNotice: LicenseActivationNotice?

    var body: some View {
        @Bindable var account = account

        Group {
            switch account.phase {
            case .off, .signedIn, .signedOut:
                MainWindow()
                    // The one sign-out confirmation for the popover and the app menu. Settings has its own.
                    .confirmationDialog("Sign Out of Uncloud?", isPresented: $account.isConfirmingSignOut, titleVisibility: .visible) {
                        Button("Sign Out", role: .destructive) {
                            Task { await account.signOut() }
                        }
                    } message: {
                        Text("Your photos and backup aren’t changed. You can keep using Uncloud without an account.")
                    }
            case .restoring:
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .animation(Tokens.Motion.animation(reduceMotion), value: account.phase)
        .task {
            // Confirms the account at launch, at most once a day.
            await account.refreshAccount(force: false)
        }
        .onOpenURL { url in
            guard let key = LicenseDeepLink.key(from: url) else { return }
            Task { await activateLicense(key) }
        }
        .alert(
            licenseNotice?.title ?? "License",
            isPresented: Binding(
                get: { licenseNotice != nil },
                set: { if !$0 { licenseNotice = nil } }
            )
        ) {
            Button("OK") { licenseNotice = nil }
        } message: {
            Text(licenseNotice?.message ?? "")
        }
        .onChange(of: account.phase) { _, phase in
            // A new account gets one line of announcement, since there is no separate welcome screen (plan B.1).
            if phase == .signedIn, account.isNewAccount {
                AccessibilityNotification.Announcement("Welcome to Uncloud").post()
            }
        }
    }

    private func activateLicense(_ key: String) async {
        guard let parsed = LicenseKey.parse(key) else {
            licenseNotice = .failed(LicenseActivation.unrecognized)
            return
        }
        let remote = await LicenseVerifier.live(baseURL: LicenseVerifier.baseURL()).verify(parsed.key)
        switch LicenseActivation.decide(parsed: parsed, remote: remote) {
        case .saved(let license):
            LicenseStore.current.save(license)
            model.isShowingLicensePaywall = false
            licenseNotice = .activated(license)
        case .rejected(let message):
            licenseNotice = .failed(message)
        }
    }
}

/// The signed-out screens. Each route is its own page in the same window, not a sheet.
struct AccountFlowView: View {
    let route: AccountModel.Route

    var body: some View {
        switch route {
        case .welcome:
            WelcomeView()
        case .signUp, .signIn:
            // One view for both, so the typed email and the field's state survive switching between them.
            AccountEmailView(intent: route == .signIn ? .signIn : .signUp)
        case let .code(challenge, intent):
            AccountCodeView(challenge: challenge, intent: intent)
        }
    }
}

/// The shell of every account screen (plan B.3). Centred in the window, and it scrolls only when the window is too short.
/// The optional Back button sits top-left and is the Esc action.
struct AccountPage<Content: View>: View {
    var onBack: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    content
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                .padding(.horizontal, Tokens.Space.l)
                .padding(.vertical, Tokens.Space.xxxl)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .overlay(alignment: .topLeading) {
            if let onBack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .padding(Tokens.Space.l)
            }
        }
    }
}
