import SwiftUI

/// The code step: six digits from the email. Pasting or typing the sixth digit verifies at once.
/// Esc, or Use a Different Email, goes back to the email screen with the address kept.
struct AccountCodeView: View {
    let challenge: AuthChallenge
    let intent: AuthIntent
    @Environment(AccountModel.self) private var account
    @Environment(\.uncloudAccent) private var accent
    @State private var code = ""
    /// True once the current six digits have been sent, so they aren't sent again until they change.
    @State private var sentCurrentCode = false
    /// Counts resends, so the "We sent a new code" line shows for a few seconds after each one.
    @State private var resendCount = 0
    @State private var showsResendNotice = false
    @FocusState private var isFocused: Bool

    var body: some View {
        AccountPage(onBack: goBack) {
            VStack(spacing: Tokens.Space.l) {
                IconTile(symbol: "envelope.badge", tint: accent ?? .accentColor, size: Tokens.Tile.hero)
                    .padding(.bottom, Tokens.Space.xs)

                VStack(spacing: Tokens.Space.s) {
                    Text("Check Your Email")
                        .font(.title.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    (Text("Enter the 6-digit code we sent to ") + Text(challenge.email).fontWeight(.semibold) + Text("."))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: Tokens.Space.m) {
                    VStack(spacing: Tokens.Space.s) {
                        TextField("Verification code", text: $code, prompt: Text("000000"))
                            .font(.system(.title2, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .frame(width: 200)
                            .textContentType(.oneTimeCode)
                            .focused($isFocused)
                            .disabled(account.isBusy)
                            .onSubmit(verify)
                            .accessibilityLabel("Verification code")
                            .onChange(of: code) { _, value in
                                codeChanged(value)
                            }
                        if let error = account.error {
                            AccountErrorText(error: error)
                        }
                        if showsResendNotice {
                            Text("We sent a new code.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(action: verify) {
                        if account.isBusy {
                            HStack(spacing: Tokens.Space.s) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Checking…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("Verify")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!OneTimeCode.isComplete(code) || account.isBusy)

                    links
                }

                if account.mode == .preview {
                    Label("Preview build: the code is \(PreviewAccountService.code).", systemImage: "hammer")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, Tokens.Space.s)
                }
            }
            .frame(maxWidth: 360)
        }
        .onAppear {
            isFocused = true
        }
        .onChange(of: challenge.id) { _, _ in
            // A new code: clear the old digits, and show the notice.
            code = ""
            resendCount += 1
        }
        .onChange(of: account.error) { _, error in
            // A wrong code is cleared so the user types the new one without selecting; the field is focused again.
            guard error != nil else { return }
            if error == .wrongCode {
                code = ""
            }
            isFocused = true
        }
        .task(id: resendCount) {
            guard resendCount > 0 else { return }
            showsResendNotice = true
            try? await Task.sleep(for: .seconds(4))
            showsResendNotice = false
        }
    }

    /// Send a New Code is enabled once the challenge's resend time has passed, and counts down until then.
    private var links: some View {
        HStack(spacing: Tokens.Space.s) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(challenge.resendAfter.timeIntervalSince(context.date).rounded(.up)))
                Button(remaining > 0 ? "Send a New Code in \(Self.countdown(remaining))" : "Send a New Code") {
                    Task {
                        await account.resendCode()
                    }
                }
                .disabled(remaining > 0 || account.isBusy)
            }
            Text("·")
                .foregroundStyle(.secondary)
            Button("Use a Different Email") {
                goBack()
            }
            .disabled(account.isBusy)
        }
        .buttonStyle(.link)
        .font(.callout)
    }

    /// The digits are typed or pasted: keep only six ASCII digits, and verify once the sixth arrives.
    private func codeChanged(_ value: String) {
        let clean = OneTimeCode.sanitized(value)
        if clean != value {
            code = clean
            return
        }
        if OneTimeCode.isComplete(clean) {
            guard !sentCurrentCode else { return }
            sentCurrentCode = true
            verify()
        } else {
            sentCurrentCode = false
        }
        // Typing clears the error. Clearing the field itself (after a wrong code) must keep it.
        if !clean.isEmpty, account.error != nil {
            account.clearError()
        }
    }

    private func verify() {
        guard OneTimeCode.isComplete(code), !account.isBusy else { return }
        let entered = code
        Task {
            await account.submitCode(entered)
            // A returning account that signed up is told it's a sign-in, not a new account (plan F.7).
            if account.phase == .signedIn, intent == .signUp, !account.isNewAccount {
                AccessibilityNotification.Announcement("Welcome back").post()
            }
        }
    }

    /// Esc: back to the email screen it came from, with the address kept. While a request runs, Esc cancels it.
    private func goBack() {
        if account.isBusy {
            account.cancelRequest()
        } else {
            account.show(intent == .signUp ? .signUp : .signIn)
        }
    }

    private static func countdown(_ seconds: Int) -> String {
        "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
