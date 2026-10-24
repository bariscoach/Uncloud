import Foundation

/// The signed-in Uncloud account. The email is shown in Settings; the id is the server's.
struct UncloudAccount: Codable, Equatable, Sendable {
    let id: String
    let email: String
    /// When the account was created. Known after a sign-in; nil for accounts cached before it was stored.
    var createdAt: Date? = nil
    /// When the server last confirmed the account. Nil until the first check. Limits the launch check to once a day.
    var checkedAt: Date? = nil
}

/// Sign Up and Sign In share the same two steps. The intent only changes the wording of the email.
enum AuthIntent: String, Equatable, Sendable {
    case signUp, signIn
}

/// What `requestCode` returns: the challenge to verify against.
struct AuthChallenge: Equatable, Hashable, Sendable {
    let id: String
    let email: String
    let expiresAt: Date
    let resendAfter: Date
}

/// The result of a successful verify: the account, its tokens, and whether the account was just created.
struct AuthSession: Equatable, Sendable {
    let account: UncloudAccount
    let tokens: AccountTokens
    let isNewAccount: Bool
}

struct AccountTokens: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let accessExpiresAt: Date
}

enum AccountError: Error, Equatable, Sendable {
    case invalidEmail
    case wrongCode
    case codeExpired
    case tooManyAttempts
    case rateLimited(retryAfter: Date?)
    case offline
    case server(message: String?)
    case signedOut
    case confirmationMismatch

    /// The sentence shown next to the field or in a banner (plan F.7).
    var message: String {
        switch self {
        case .invalidEmail: "Enter a valid email address."
        case .wrongCode: "That code isn’t right. Check it and try again."
        case .codeExpired: "That code has expired. Send a new one."
        case .tooManyAttempts: "Too many tries. Send a new code and try again."
        case .rateLimited: "Too many codes requested. Try again in a few minutes."
        case .offline: "Can’t reach Uncloud. Check your internet connection and try again."
        // Only the code-email failure has its own sentence; server wording is never shown as is.
        case let .server(message) where message == LiveAccountService.codeEmailNotSent: LiveAccountService.codeEmailNotSent
        case .server: "Uncloud couldn’t finish that. Try again in a moment."
        case .signedOut: "You’ve been signed out. Sign in again to keep using Uncloud."
        case .confirmationMismatch: "The email doesn’t match your Uncloud account."
        }
    }
}
