import Foundation
import Testing
@testable import Uncloud

@Suite("LiveAccountService", .serialized)
struct LiveAccountServiceTests {
    static let accountID = "11111111-2222-3333-4444-555555555555"
    static let now = WireDate.parse("2026-10-18T09:41:10Z")!
    static let clock: @Sendable () -> Date = { now }

    /// A service whose every request goes to `handler`. The configuration is the one the app builds for `live`.
    static func service(_ handler: @escaping MockURLProtocol.Handler) -> LiveAccountService {
        let session = MockURLProtocol.install(handler)
        let configuration = AccountConfiguration.resolve(
            mode: "live",
            isDebug: false,
            baseURL: "https://api.test.example",
            supabaseURL: "https://supabase.test.example",
            supabasePublishableKey: "sb_publishable_test"
        )
        return LiveAccountService(configuration: configuration, session: session, now: clock)!
    }

    /// An access token with a `sub` claim. The signature part is not checked by the app.
    static func jwt(sub: String) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["sub": sub, "role": "authenticated"])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJFUzI1NiJ9.\(encoded).c2ln"
    }

    static let tokens = AccountTokens(
        accessToken: jwt(sub: accountID),
        refreshToken: "refresh-old",
        accessExpiresAt: now.addingTimeInterval(3600)
    )

    /// `/v1/me` for the test account. The plan fields an older server sent are still here, and the app must ignore them.
    static let meJSON = """
    {"account":{"id":"\(accountID)","email":"name@example.com"},
     "entitlement":{"plan":"plus","status":"active","currentPeriodEnd":"2027-10-18T09:41:10Z",
     "cancelAtPeriodEnd":false,"checkedAt":"2026-10-18T09:41:10Z","signature":"c2ln"}}
    """

    static func sessionJSON(newAccount: Bool, expiresAt: Double? = nil) -> String {
        let signedIn = "2026-10-18T09:41:10Z"
        let confirmed = newAccount ? "2026-10-18T09:41:10.123456Z" : "2026-01-01T00:00:00Z"
        return """
        {"access_token":"access-new","refresh_token":"refresh-new","token_type":"bearer","expires_in":3600,
         "expires_at":\(expiresAt ?? now.timeIntervalSince1970 + 3600),
         "user":{"id":"\(accountID)","email":"name@example.com",
         "email_confirmed_at":"\(confirmed)","last_sign_in_at":"\(signedIn)",
         "created_at":"\(newAccount ? confirmed : "2026-01-01T00:00:00Z")"}}
        """
    }

    static let challenge = AuthChallenge(
        id: "challenge-1",
        email: "name@example.com",
        expiresAt: now.addingTimeInterval(600),
        resendAfter: now.addingTimeInterval(60)
    )

    // MARK: - Sign-in

    @Test("requestCode posts the email to Supabase with the publishable key and no tokens")
    func requestCode() async throws {
        let service = Self.service { _ in MockReply(json: "{}") }
        let fresh = try await service.requestCode(email: "name@example.com", intent: .signUp)
        #expect(fresh.email == "name@example.com")
        #expect(fresh.expiresAt == Self.now.addingTimeInterval(600))
        #expect(fresh.resendAfter == Self.now.addingTimeInterval(60))

        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://supabase.test.example/auth/v1/otp")
        #expect(request.headers["apikey"] == "sb_publishable_test")
        #expect(request.headers["Authorization"] == nil)
        #expect(request.headers["User-Agent"]?.hasPrefix("Uncloud/") == true)
        #expect(request.json?["email"] as? String == "name@example.com")
        #expect(request.json?["create_user"] as? Bool == true)
    }

    @Test("A rate-limited code request reads the wait from Supabase's message")
    func requestCodeRateLimited() async throws {
        let service = Self.service { _ in
            MockReply(status: 429, json: #"{"code":429,"error_code":"over_email_send_rate_limit","msg":"For security purposes, you can only request this after 42 seconds."}"#)
        }
        await #expect(throws: AccountError.rateLimited(retryAfter: Self.now.addingTimeInterval(42))) {
            try await service.requestCode(email: "name@example.com", intent: .signIn)
        }
    }

    @Test("A code email Supabase can't send says so")
    func requestCodeEmailNotSent() async throws {
        let service = Self.service { _ in
            MockReply(status: 500, json: #"{"code":500,"error_code":"unexpected_failure","msg":"Error sending confirmation email"}"#)
        }
        await #expect(throws: AccountError.server(message: LiveAccountService.codeEmailNotSent)) {
            try await service.requestCode(email: "name@example.com", intent: .signUp)
        }
        #expect(AccountError.server(message: LiveAccountService.codeEmailNotSent).message == "Uncloud couldn’t send the code email. Try again later.")
        #expect(AccountError.server(message: "raw server words").message == "Uncloud couldn’t finish that. Try again in a moment.")
    }

    @Test("An address Supabase rejects is invalidEmail")
    func requestCodeInvalidEmail() async throws {
        let service = Self.service { _ in
            MockReply(status: 422, json: #"{"code":422,"error_code":"email_address_invalid","msg":"bad"}"#)
        }
        await #expect(throws: AccountError.invalidEmail) {
            try await service.requestCode(email: "name@example.com", intent: .signIn)
        }
    }

    @Test("Verify signs in, confirms the account with /v1/me, and reports a new account")
    func verifySignsIn() async throws {
        let service = Self.service { request in
            if request.path == "/auth/v1/verify" { return MockReply(json: Self.sessionJSON(newAccount: true)) }
            if request.path == "/v1/me" { return MockReply(json: Self.meJSON) }
            throw URLError(.badURL)
        }
        let session = try await service.verify(challenge: Self.challenge, code: "123456")
        #expect(session.isNewAccount)
        #expect(session.account.id == Self.accountID)
        #expect(session.account.email == "name@example.com")
        #expect(session.tokens.accessToken == "access-new")
        #expect(session.tokens.refreshToken == "refresh-new")
        #expect(session.tokens.accessExpiresAt == Self.now.addingTimeInterval(3600))

        let requests = MockURLProtocol.requests
        let verify = try #require(requests.first { $0.path == "/auth/v1/verify" })
        #expect(verify.json?["type"] as? String == "email")
        #expect(verify.json?["token"] as? String == "123456")
        let me = try #require(requests.first { $0.path == "/v1/me" })
        #expect(me.headers["Authorization"] == "Bearer access-new")
    }

    @Test("An account confirmed long before this sign-in is not new")
    func verifyExistingAccount() async throws {
        let service = Self.service { request in
            request.path == "/v1/me" ? MockReply(json: Self.meJSON) : MockReply(json: Self.sessionJSON(newAccount: false))
        }
        let session = try await service.verify(challenge: Self.challenge, code: "123456")
        #expect(session.isNewAccount == false)
    }

    @Test("Sign-in still works offline, from the Supabase user, with no check time yet")
    func verifyOffline() async throws {
        let service = Self.service { request in
            if request.path == "/v1/me" { throw URLError(.notConnectedToInternet) }
            return MockReply(json: Self.sessionJSON(newAccount: false))
        }
        let session = try await service.verify(challenge: Self.challenge, code: "123456")
        #expect(session.account.id == Self.accountID)
        #expect(session.account.email == "name@example.com")
        #expect(session.account.checkedAt == nil)
    }

    @Test("Wrong codes are wrongCode until the fifth, which ends the challenge")
    func wrongCodes() async throws {
        let service = Self.service { _ in
            MockReply(status: 403, json: #"{"code":403,"error_code":"otp_expired","msg":"Token has expired or is invalid"}"#)
        }
        for _ in 0..<4 {
            await #expect(throws: AccountError.wrongCode) {
                try await service.verify(challenge: Self.challenge, code: "000000")
            }
        }
        await #expect(throws: AccountError.tooManyAttempts) {
            try await service.verify(challenge: Self.challenge, code: "000000")
        }
        let sent = MockURLProtocol.requests.count
        await #expect(throws: AccountError.tooManyAttempts) {
            try await service.verify(challenge: Self.challenge, code: "000000")
        }
        #expect(MockURLProtocol.requests.count == sent)
    }

    @Test("A code rejected after its ten minutes is codeExpired")
    func expiredCode() async throws {
        let service = Self.service { _ in
            MockReply(status: 403, json: #"{"code":403,"error_code":"otp_expired","msg":"expired"}"#)
        }
        let late = AuthChallenge(id: "late", email: "name@example.com", expiresAt: Self.now.addingTimeInterval(-1), resendAfter: Self.now)
        await #expect(throws: AccountError.codeExpired) {
            try await service.verify(challenge: late, code: "123456")
        }
    }

    // MARK: - Account and tokens

    @Test("The account call never refreshes the tokens: it sends the given token to /v1/me and nothing else (L3)")
    func currentAccountDoesNotRefresh() async throws {
        let nearlyExpired = AccountTokens(
            accessToken: Self.jwt(sub: Self.accountID),
            refreshToken: "refresh-old",
            accessExpiresAt: Self.now.addingTimeInterval(30)
        )
        let service = Self.service { request in
            if request.path == "/v1/me" { return MockReply(json: Self.meJSON) }
            throw URLError(.badURL)
        }
        let account = try await service.currentAccount(tokens: nearlyExpired)
        #expect(account.id == Self.accountID)
        #expect(account.email == "name@example.com")
        #expect(MockURLProtocol.requests.map(\.path) == ["/v1/me"])
    }

    @Test("A refresh token that was already used means signed out")
    func refreshAlreadyUsed() async throws {
        let service = Self.service { _ in
            MockReply(status: 400, json: #"{"code":400,"error_code":"refresh_token_already_used","msg":"used"}"#)
        }
        await #expect(throws: AccountError.signedOut) {
            try await service.refresh(tokens: Self.tokens)
        }
    }

    // MARK: - API

    @Test("API error codes map to their account errors")
    func apiErrorCodes() async throws {
        let service = Self.service { request in
            switch request.path {
            case "/v1/account/delete":
                return MockReply(status: 503, json: #"{"error":{"code":"maintenance","message":"x"}}"#)
            default:
                return MockReply(status: 401, json: #"{"error":{"code":"unauthorized","message":"x"}}"#)
            }
        }
        await #expect(throws: AccountError.signedOut) {
            try await service.currentAccount(tokens: Self.tokens)
        }
        await #expect(throws: AccountError.server(message: "x")) {
            try await service.deleteAccount(confirmEmail: "name@example.com", tokens: Self.tokens)
        }
    }

    @Test("Sign-out revokes the local session at Supabase and never throws")
    func signOut() async throws {
        let service = Self.service { _ in throw URLError(.notConnectedToInternet) }
        await service.signOut(tokens: Self.tokens)
        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.url.absoluteString == "https://supabase.test.example/auth/v1/logout?scope=local")
        #expect(request.headers["Authorization"] == "Bearer \(Self.tokens.accessToken)")
    }

    @Test("Network failures are offline; server failures are server errors")
    func transportErrors() async throws {
        let timedOut = Self.service { _ in throw URLError(.timedOut) }
        await #expect(throws: AccountError.offline) {
            try await timedOut.requestCode(email: "name@example.com", intent: .signIn)
        }
        let broken = Self.service { _ in MockReply(status: 500, json: "oops") }
        await #expect(throws: AccountError.server(message: nil)) {
            try await broken.currentAccount(tokens: Self.tokens)
        }
    }

    @Test("Without the live values there is no service, so the app can't reach the network")
    func noServiceWithoutConfiguration() {
        let off = AccountConfiguration.resolve(mode: "live", isDebug: false, baseURL: "", supabaseURL: nil, supabasePublishableKey: "")
        #expect(LiveAccountService(configuration: off) == nil)
    }

    @Test("deleteAccount posts the typed email with the bearer token and accepts 204")
    func deleteAccount() async throws {
        let service = Self.service { _ in MockReply(status: 204) }
        try await service.deleteAccount(confirmEmail: "name@example.com", tokens: Self.tokens)
        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://api.test.example/v1/account/delete")
        #expect(request.headers["Authorization"] == "Bearer \(Self.tokens.accessToken)")
        #expect(request.json?["confirmEmail"] as? String == "name@example.com")
    }

    @Test("A mismatched confirmation is confirmationMismatch")
    func deleteMismatch() async {
        let service = Self.service { _ in
            MockReply(status: 400, json: #"{"error":{"code":"confirmation_mismatch","message":"no"}}"#)
        }
        await #expect(throws: AccountError.confirmationMismatch) {
            try await service.deleteAccount(confirmEmail: "other@example.com", tokens: Self.tokens)
        }
    }

    @Test("An ended session is signedOut, and a rate limit carries its Retry-After")
    func deleteErrors() async {
        let unauthorized = Self.service { _ in
            MockReply(status: 401, json: #"{"error":{"code":"unauthorized","message":"no"}}"#)
        }
        await #expect(throws: AccountError.signedOut) {
            try await unauthorized.deleteAccount(confirmEmail: "name@example.com", tokens: Self.tokens)
        }

        let limited = Self.service { _ in
            MockReply(status: 429, headers: ["Retry-After": "3600"], json: #"{"error":{"code":"rate_limited","message":"no"}}"#)
        }
        await #expect(throws: AccountError.rateLimited(retryAfter: Self.now.addingTimeInterval(3600))) {
            try await limited.deleteAccount(confirmEmail: "name@example.com", tokens: Self.tokens)
        }
    }

    @Test("Verify reads the creation date, with or without fractional seconds")
    func verifyReadsCreatedAt() async throws {
        let fresh = Self.service { request in
            if request.path == "/auth/v1/verify" { return MockReply(json: Self.sessionJSON(newAccount: true)) }
            return MockReply(json: Self.meJSON)
        }
        let newSession = try await fresh.verify(challenge: Self.challenge, code: "123456")
        #expect(newSession.account.createdAt != nil)

        let older = Self.service { request in
            if request.path == "/auth/v1/verify" { return MockReply(json: Self.sessionJSON(newAccount: false)) }
            return MockReply(json: Self.meJSON)
        }
        let oldSession = try await older.verify(challenge: Self.challenge, code: "123456")
        #expect(oldSession.account.createdAt == WireDate.parse("2026-01-01T00:00:00Z"))
    }

    @Test("A cached account without a creation date still decodes, with nil")
    func cachedAccountWithoutCreatedAt() throws {
        let account = try JSONDecoder().decode(UncloudAccount.self, from: Data(#"{"id":"u","email":"name@example.com"}"#.utf8))
        #expect(account.createdAt == nil)
        #expect(account.checkedAt == nil)
        #expect(account.email == "name@example.com")
    }
}
