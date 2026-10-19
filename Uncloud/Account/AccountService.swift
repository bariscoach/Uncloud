import Foundation

/// The account backend. `PreviewAccountService` for Debug builds; `LiveAccountService` for `live`.
/// Implementations are actors or otherwise Sendable; every call is async and may throw `AccountError`.
protocol AccountService: Sendable {
    /// Sends a 6-digit code to `email`. Sign Up and Sign In both call this; `intent` only affects the email's wording.
    func requestCode(email: String, intent: AuthIntent) async throws -> AuthChallenge
    /// Exchanges the code for a session. Creates the account if the email is new.
    func verify(challenge: AuthChallenge, code: String) async throws -> AuthSession
    /// The plan of the signed-in account, refreshing the tokens first if the access token has expired.
    func currentEntitlement(tokens: AccountTokens) async throws -> (Entitlement, AccountTokens)
    /// Exchanges the refresh token for new tokens. The old refresh token stops working.
    func refresh(tokens: AccountTokens) async throws -> AccountTokens
    /// Revokes the refresh token on the server. Best effort: local sign-out happens whatever this does.
    func signOut(tokens: AccountTokens) async
    /// A Stripe Checkout URL for Uncloud Plus. The app opens it in the browser.
    func checkoutURL(tokens: AccountTokens, renewal: Renewal) async throws -> URL
    /// A Stripe customer portal URL (manage, cancel, change card, invoices).
    func manageSubscriptionURL(tokens: AccountTokens) async throws -> URL
    /// Turns renewal on or off for an existing plan. Returns the plan as the server now reports it.
    func setAutoRenew(_ autoRenew: Bool, tokens: AccountTokens) async throws -> Entitlement
}
