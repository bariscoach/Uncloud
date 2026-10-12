import Foundation
import Observation

/// Drives icloudpd's `--auth-only` sign-in, including two-factor codes.
@MainActor @Observable final class ICloudSignIn {
    enum State: Equatable {
        case idle
        case signingIn
        case needsCode(devices: [ICloudTrustedDevice], canRequestSMS: Bool, message: String?)
        case sendingSMS
        case needsSMSCode(message: String?)
        case signedIn(appleID: String)
        case failed(String)
    }

    private(set) var state: State

    @ObservationIgnored private var helper: ICloudHelperProcess?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The last code prompt, so invalid input can return to it.
    @ObservationIgnored private var codeState: State?
    @ObservationIgnored private var pendingMessage: String?

    init() {
        if let appleID = ICloudAccount.appleID {
            state = .signedIn(appleID: appleID)
        } else {
            state = .idle
        }
    }

    /// Signs in and saves the session. The password is only kept until icloudpd asks for it,
    /// and in the Keychain if `rememberPassword` is set.
    func signIn(appleID: String, password: String, rememberPassword: Bool) {
        cancel()
        let helper = ICloudHelperProcess(
            arguments: ICloudHelperProcess.commonArguments(appleID: appleID) + ["--auth-only"]
        )
        self.helper = helper
        state = .signingIn
        task = Task { [weak self] in
            await self?.run(helper, appleID: appleID, password: password, rememberPassword: rememberPassword)
        }
    }

    /// Sends a six-digit verification code.
    func submit(code: String) {
        guard let helper else {
            return
        }
        helper.send(code.trimmingCharacters(in: .whitespacesAndNewlines))
        state = .signingIn
    }

    /// Asks Apple to text a code to a trusted phone number.
    func requestSMS(device: ICloudTrustedDevice) {
        guard let helper else {
            return
        }
        helper.send(device.index)
        state = .sendingSMS
    }

    /// Stops a sign-in in progress.
    func cancel() {
        task?.cancel()
        task = nil
        helper?.terminate()
        helper = nil
        codeState = nil
        pendingMessage = nil
        if case .signedIn = state {
            return
        }
        state = .idle
    }

    /// Forgets the account, its session and saved password, and the cached thumbnails.
    func signOut() {
        cancel()
        ICloudBridge.shutDownAll()
        ICloudAccount.signOut()
        ICloudLibrary.clearCaches()
        state = .idle
    }

    // MARK: - Running

    private func run(_ helper: ICloudHelperProcess, appleID: String, password: String, rememberPassword: Bool) async {
        let events: AsyncStream<ICloudOutputEvent>
        do {
            events = try helper.start()
        } catch {
            finish(helper, with: .failed(error.localizedDescription))
            return
        }
        var passwordToSend: String? = password
        var devices: [ICloudTrustedDevice] = []
        var authenticated = false
        var passwordRefused = false
        for await event in events {
            guard self.helper === helper else {
                return
            }
            switch event {
            case .passwordPrompt:
                if let passwordToSend {
                    helper.send(passwordToSend)
                } else {
                    // A second prompt means the first password was refused.
                    passwordRefused = true
                    helper.terminate()
                }
                passwordToSend = nil
            case .trustedDevices(let list):
                devices = list
            case .codePrompt(let canRequestSMS):
                let codeState = State.needsCode(devices: devices, canRequestSMS: canRequestSMS, message: pendingMessage)
                self.codeState = codeState
                pendingMessage = nil
                state = codeState
            case .smsCodePrompt:
                let codeState = State.needsSMSCode(message: pendingMessage)
                self.codeState = codeState
                pendingMessage = nil
                state = codeState
            case .invalidInput(let message):
                pendingMessage = message
                state = Self.withMessage(codeState, message) ?? state
            case .authenticated:
                authenticated = true
            default:
                break
            }
        }
        let status = await helper.waitUntilExit()
        guard self.helper === helper, !Task.isCancelled else {
            return
        }
        if status == 0 && authenticated {
            ICloudAccount.appleID = appleID
            if rememberPassword {
                try? ICloudCredentialStore.savePassword(password, for: appleID)
            } else {
                ICloudCredentialStore.deletePassword(for: appleID)
            }
            finish(helper, with: .signedIn(appleID: appleID))
        } else if passwordRefused {
            finish(helper, with: .failed(ICloudFailure.invalidCredentials.message))
        } else if let failure = helper.lastFailure {
            finish(helper, with: .failed(failure.message))
        } else if let detail = helper.diagnosticSummary {
            finish(helper, with: .failed("Sign-in stopped: \(detail)"))
        } else {
            finish(helper, with: .failed("Sign-in stopped unexpectedly (code \(status))."))
        }
    }

    private func finish(_ helper: ICloudHelperProcess, with state: State) {
        guard self.helper === helper else {
            return
        }
        self.helper = nil
        task = nil
        codeState = nil
        pendingMessage = nil
        self.state = state
    }

    private static func withMessage(_ state: State?, _ message: String) -> State? {
        switch state {
        case .needsCode(let devices, let canRequestSMS, _)?:
            .needsCode(devices: devices, canRequestSMS: canRequestSMS, message: message)
        case .needsSMSCode?:
            .needsSMSCode(message: message)
        default:
            nil
        }
    }
}
