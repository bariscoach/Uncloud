import SwiftUI

/// Signs in to iCloud with an Apple ID, then takes the two-factor code when Apple asks for one.
struct ICloudSignInSheet: View {
    @Environment(ExportModel.self) private var model

    @State private var appleID = ICloudAccount.appleID ?? ""
    @State private var password = ""
    @State private var rememberPassword = true
    @State private var code = ""

    var body: some View {
        content
            .padding(Tokens.Sheet.padding)
            .frame(width: Tokens.Sheet.narrow)
            .onAppear(perform: dismissIfSignedIn)
            .onChange(of: model.signIn.state) { _, _ in dismissIfSignedIn() }
            .onDisappear { model.signIn.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.signIn.state {
        case .idle:
            credentials(message: nil)
        case .failed(let message):
            credentials(message: message)
        case .signingIn:
            progress("Signing in…")
        case .sendingSMS:
            progress("Sending a code…")
        case let .needsCode(devices, canRequestSMS, message):
            codeEntry(
                explanation: "Enter the 6-digit code shown on your Apple devices.",
                message: message,
                devices: devices,
                canRequestSMS: canRequestSMS
            )
        case .needsSMSCode(let message):
            codeEntry(
                explanation: "Enter the 6-digit code sent to your phone.",
                message: message,
                devices: [],
                canRequestSMS: false
            )
        case .signedIn:
            EmptyView()
        }
    }

    // MARK: - Screens

    private func credentials(message: String?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign In to iCloud")
                .font(.headline)

            Form {
                TextField("Apple ID", text: $appleID)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Toggle("Remember password in Keychain", isOn: $rememberPassword)
                Text("Lets automatic backups sign in again on their own. If it’s off, you’ll be asked for your password when the sign-in expires (about every two months).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.grouped)

            Text("Your Apple ID and password are sent only to Apple, through icloudpd, the open-source tool built into this app. Two-factor authentication works as usual.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message {
                errorLabel(message)
            }

            HStack {
                Spacer()
                cancelButton
                Button("Sign In") {
                    startSignIn()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSignIn)
            }
        }
    }

    private func progress(_ title: String) -> some View {
        VStack(spacing: 16) {
            ProgressView(title)
            HStack {
                Spacer()
                cancelButton
            }
        }
    }

    private func codeEntry(explanation: String, message: String?, devices: [ICloudTrustedDevice], canRequestSMS: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(explanation)
                .font(.headline)

            TextField("Code", text: $code)
                .textContentType(.oneTimeCode)
                .onChange(of: code) { _, newValue in
                    code = String(newValue.filter { $0.isASCII && $0.isNumber }.prefix(6))
                }

            if let message {
                errorLabel(message)
            }

            HStack {
                if canRequestSMS, !devices.isEmpty {
                    Menu("Text Me a Code") {
                        ForEach(devices, id: \.index) { device in
                            Button(device.label) {
                                model.signIn.requestSMS(device: device)
                            }
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                cancelButton
                Button("Verify") {
                    model.signIn.submit(code: code)
                    code = ""
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(code.count != 6)
            }
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cancelButton: some View {
        Button("Cancel") {
            dismiss()
        }
        .keyboardShortcut(.cancelAction)
    }

    // MARK: - Actions

    private var canSignIn: Bool {
        !appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    /// Hands the password to the model and clears the field, so it lives only in the model's sign-in.
    private func startSignIn() {
        let password = password
        self.password = ""
        model.signIn.signIn(
            appleID: appleID.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            rememberPassword: rememberPassword
        )
    }

    private func dismiss() {
        model.signIn.cancel()
        model.isShowingICloudSignIn = false
    }

    private func dismissIfSignedIn() {
        if case .signedIn = model.signIn.state {
            model.isShowingICloudSignIn = false
        }
    }
}
