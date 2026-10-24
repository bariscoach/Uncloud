import Foundation

/// The account backend. `PreviewAccountService` for Debug builds; `LiveAccountService` for `live`.
/// Implementations are actors or otherwise Sendable; every call is async and may throw `AccountError`.
protocol AccountService: Sendable {
    /// Sends a 6-digit code to `email`. Sign Up and Sign In both call this; `intent` only affects the email's wording.
    func requestCode(email: String, intent: AuthIntent) async throws -> AuthChallenge
    /// Exchanges the code for a session. Creates the account if the email is new.
    func verify(challenge: AuthChallenge, code: String) async throws -> AuthSession
    /// The signed-in account as the server reports it. Only the identity is read. Never refreshes the tokens itself:
    /// the model refreshes them first, through its single-flight refresh, because refresh tokens are single use (L3).
    func currentAccount(tokens: AccountTokens) async throws -> UncloudAccount
    /// Exchanges the refresh token for new tokens. The old refresh token stops working.
    func refresh(tokens: AccountTokens) async throws -> AccountTokens
    /// Revokes the refresh token on the server. Best effort: local sign-out happens whatever this does.
    func signOut(tokens: AccountTokens) async
    /// Deletes the Uncloud account. `confirmEmail` must match the account's email (case and spaces ignored).
    func deleteAccount(confirmEmail: String, tokens: AccountTokens) async throws
}
