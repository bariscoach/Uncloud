import SwiftUI

/// The email step, shared by Sign Up and Sign In. The intent only changes the wording and the link at the bottom.
/// It is one view for both routes, so a typed email stays in the field when switching between them.
struct AccountEmailView: View {
    let intent: AuthIntent
    @Environment(AccountModel.self) private var account
    @Environment(\.uncloudAccent) private var accent
    @State private var address = ""
    @FocusState private var isFocused: Bool

    private var isValid: Bool {
        EmailAddress.normalized(address) != nil
    }

    var body: some View {
        AccountPage(onBack: goBack) {
            VStack(spacing: Tokens.Space.l) {
                AppLogo(size: 56)
                    .accessibilityHidden(true)
                VStack(spacing: Tokens.Space.s) {
                    Text(title)
                        .font(.title.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(explanation)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, Tokens.Space.s)

                VStack(spacing: Tokens.Space.m) {
                    VStack(spacing: Tokens.Space.s) {
                        TextField("Email", text: $address, prompt: Text("name@example.com"))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .textContentType(.emailAddress)
                            .autocorrectionDisabled()
                            .focused($isFocused)
                            .disabled(account.isBusy)
                            .onSubmit(submit)
                            .accessibilityLabel("Email")
                            .onChange(of: address) { _, _ in
                                account.clearError()
                            }
                        if let error = account.error {
                            AccountErrorText(error: error)
                        }
                    }

                    Button(action: submit) {
                        if account.isBusy {
                            HStack(spacing: Tokens.Space.s) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Sending code…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("Continue")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    // Disabled until the address is valid. Return still reaches `submit`, which shows the error.
                    .disabled(!isValid || account.isBusy)
                }

                footnote
                    .padding(.top, Tokens.Space.s)
            }
            .frame(maxWidth: 360)
        }
        .onAppear {
            address = account.email
            isFocused = true
        }
    }

    private var title: String {
        intent == .signUp ? "Create Your Uncloud Account" : "Sign In to Uncloud"
    }

    private var explanation: String {
        intent == .signUp
            ? "Enter your email and we’ll send you a 6-digit code. There’s no password to remember."
            : "Enter the email you used for your Uncloud account and we’ll send you a code."
    }

    /// Sign Up links to the terms. Both screens offer the other one as a link.
    @ViewBuilder
    private var footnote: some View {
        if intent == .signUp {
            VStack(spacing: Tokens.Space.m) {
                Text("By creating an account, you agree to the [Terms of Use](\(AccountLinks.terms(.current).absoluteString)) and [Privacy Policy](\(AccountLinks.privacy(.current).absoluteString)).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .tint(accent ?? .accentColor)
                    .fixedSize(horizontal: false, vertical: true)
                switchLink(prompt: "Already have an account?", action: "Sign In", to: .signIn)
            }
        } else {
            switchLink(prompt: "New to Uncloud?", action: "Create Account", to: .signUp)
        }
    }

    private func switchLink(prompt: String, action: String, to route: AccountModel.Route) -> some View {
        HStack(spacing: Tokens.Space.xs) {
            Text(prompt)
                .foregroundStyle(.secondary)
            Button(action) {
                account.show(route)
            }
            .buttonStyle(.link)
        }
        .font(.callout)
    }

    private func submit() {
        guard !account.isBusy else { return }
        Task {
            await account.submitEmail(address, intent: intent)
        }
    }

    /// Back goes to Welcome. While a request runs, Esc cancels it and stays here.
    private func goBack() {
        if account.isBusy {
            account.cancelRequest()
        } else {
            account.show(.welcome)
        }
    }
}

/// An error under a field: a warning symbol and the sentence, in the danger colour. It is also announced to VoiceOver.
struct AccountErrorText: View {
    let error: AccountError

    var body: some View {
        Label(error.message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(Tokens.Status.danger)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear {
                AccessibilityNotification.Announcement(error.message).post()
            }
    }
}
