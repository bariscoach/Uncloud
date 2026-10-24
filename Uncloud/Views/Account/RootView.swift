import SwiftUI

/// The main window's content. Shows the app while accounts are off or the user is signed in, and the account
/// screens while signed out (plan B.1). `off` never reaches the account screens, so it looks like v0.1.8.
struct RootView: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var account = account

        Group {
            switch account.phase {
            case .off, .signedIn:
                MainWindow()
                    // The one sign-out confirmation for the popover and the app menu. Settings has its own.
                    .confirmationDialog("Sign Out of Uncloud?", isPresented: $account.isConfirmingSignOut, titleVisibility: .visible) {
                        Button("Sign Out", role: .destructive) {
                            Task { await account.signOut() }
                        }
                    } message: {
                        Text("Your photos and backup aren’t changed. Sign in again to use Uncloud Plus.")
                    }
            case .restoring:
                Color(nsColor: .windowBackgroundColor)
            case let .signedOut(route):
                AccountFlowView(route: route)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .animation(Tokens.Motion.animation(reduceMotion), value: account.phase)
        .task {
            // Checks the plan at launch, at most once a day.
            await account.refreshEntitlement(force: false)
        }
        .onChange(of: account.phase) { _, phase in
            // A new account gets one line of announcement, since there is no separate welcome screen (plan B.1).
            if phase == .signedIn, account.isNewAccount {
                AccessibilityNotification.Announcement("Welcome to Uncloud").post()
            }
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
