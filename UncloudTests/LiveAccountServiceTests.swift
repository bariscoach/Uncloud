import Foundation
import Testing
@testable import Uncloud

@Suite("LiveAccountService", .serialized)
struct LiveAccountServiceTests {
    static let vector = EntitlementVector.load()
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
            supabasePublishableKey: "sb_publishable_test",
            entitlementPublicKey: vector.publicKey
        )
        return LiveAccountService(
            configuration: configuration,
            verifier: EntitlementVerifier(base64PublicKey: vector.publicKey),
            session: session,
            now: clock
        )!
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
        accessToken: jwt(sub: vector.accountId),
        refreshToken: "refresh-old",
        accessExpiresAt: now.addingTimeInterval(3600)
    )

    /// `/v1/me` for the vector's account, signed.
    static var meJSON: String {
        """
        {"account":{"id":"\(vector.accountId)","email":"name@example.com"},
         "entitlement":{"plan":"plus","status":"active","currentPeriodEnd":"\(vector.currentPeriodEnd)",
         "cancelAtPeriodEnd":false,"checkedAt":"\(vector.checkedAt)","signature":"\(vector.signature)"}}
        """
    }

    static func sessionJSON(newAccount: Bool, expiresAt: Double? = nil) -> String {
        let signedIn = "2026-10-18T09:41:10Z"
        let confirmed = newAccount ? "2026-10-18T09:41:10.123456Z" : "2026-01-01T00:00:00Z"
        return """
        {"access_token":"access-new","refresh_token":"refresh-new","token_type":"bearer","expires_in":3600,
         "expires_at":\(expiresAt ?? now.timeIntervalSince1970 + 3600),
         "user":{"id":"\(vector.accountId)","email":"name@example.com",
         "email_confirmed_at":"\(confirmed)","last_sign_in_at":"\(signedIn)"}}
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

    @Test("An address Supabase rejects is invalidEmail")
    func requestCodeInvalidEmail() async throws {
        let service = Self.service { _ in
            MockReply(status: 422, json: #"{"code":422,"error_code":"email_address_invalid","msg":"bad"}"#)
        }
        await #expect(throws: AccountError.invalidEmail) {
            try await service.requestCode(email: "name@example.com", intent: .signIn)
        }
    }

    @Test("Verify signs in, reads the signed plan, and reports a new account")
    func verifySignsIn() async throws {
        let service = Self.service { request in
            if request.path == "/auth/v1/verify" { return MockReply(json: Self.sessionJSON(newAccount: true)) }
            if request.path == "/v1/me" { return MockReply(json: Self.meJSON) }
            throw URLError(.badURL)
        }
        let session = try await service.verify(challenge: Self.challenge, code: "123456")
        #expect(session.isNewAccount)
        #expect(session.account == UncloudAccount(id: Self.vector.accountId, email: "name@example.com"))
        #expect(session.entitlement.plan == .plus)
        #expect(session.entitlement.signature == Self.vector.signature)
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

    @Test("Sign-in still works offline, on the Free plan, with a check time that forces a refresh")
    func verifyOffline() async throws {
        let service = Self.service { request in
            if request.path == "/v1/me" { throw URLError(.notConnectedToInternet) }
            return MockReply(json: Self.sessionJSON(newAccount: false))
        }
        let session = try await service.verify(challenge: Self.challenge, code: "123456")
        #expect(session.entitlement.plan == .free)
        #expect(session.entitlement.checkedAt == .distantPast)
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

    // MARK: - Plan and tokens

    @Test("A token about to expire is refreshed before /v1/me, and the rotated pair is returned")
    func currentEntitlementRefreshes() async throws {
        let nearlyExpired = AccountTokens(
            accessToken: Self.jwt(sub: Self.vector.accountId),
            refreshToken: "refresh-old",
            accessExpiresAt: Self.now.addingTimeInterval(30)
        )
        let service = Self.service { request in
            if request.path == "/auth/v1/token" { return MockReply(json: Self.sessionJSON(newAccount: false)) }
            if request.path == "/v1/me" { return MockReply(json: Self.meJSON) }
            throw URLError(.badURL)
        }
        let (plan, renewed) = try await service.currentEntitlement(tokens: nearlyExpired)
        #expect(plan.plan == .plus)
        #expect(renewed.refreshToken == "refresh-new")
        let requests = MockURLProtocol.requests
        #expect(requests.map(\.path) == ["/auth/v1/token", "/v1/me"])
        let refresh = try #require(requests.first)
        #expect(refresh.url.query == "grant_type=refresh_token")
        #expect(refresh.json?["refresh_token"] as? String == "refresh-old")
        #expect(requests[1].headers["Authorization"] == "Bearer access-new")
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

    @Test("An unsigned plan is rejected, not trusted")
    func unsignedPlanRejected() async throws {
        let unsigned = Self.meJSON.replacingOccurrences(of: #","signature":"\#(Self.vector.signature)""#, with: "")
        let service = Self.service { _ in MockReply(json: unsigned) }
        await #expect(throws: AccountError.server(message: "Unverified plan")) {
            try await service.currentEntitlement(tokens: Self.tokens)
        }
    }

    @Test("A plan changed after signing is rejected")
    func tamperedPlanRejected() async throws {
        let tampered = Self.meJSON.replacingOccurrences(of: #""status":"active""#, with: #""status":"pastDue""#)
        let service = Self.service { _ in MockReply(json: tampered) }
        await #expect(throws: AccountError.server(message: "Unverified plan")) {
            try await service.currentEntitlement(tokens: Self.tokens)
        }
    }

    // MARK: - API

    @Test("Checkout sends the renewal choice and accepts only a Stripe Checkout URL")
    func checkoutURL() async throws {
        let service = Self.service { _ in MockReply(json: #"{"url":"https://checkout.stripe.com/c/pay/cs_test_abc123"}"#) }
        let url = try await service.checkoutURL(tokens: Self.tokens, renewal: .oneYear)
        #expect(url.absoluteString == "https://checkout.stripe.com/c/pay/cs_test_abc123")
        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.url.absoluteString == "https://api.test.example/v1/checkout")
        #expect(request.headers["Authorization"] == "Bearer \(Self.tokens.accessToken)")
        #expect(request.json?["renewal"] as? String == "oneYear")
    }

    @Test("A checkout URL on another host is refused")
    func checkoutURLHost() async throws {
        let service = Self.service { _ in MockReply(json: #"{"url":"https://evil.example/pay"}"#) }
        await #expect(throws: AccountError.server(message: nil)) {
            try await service.checkoutURL(tokens: Self.tokens, renewal: .automatic)
        }
    }

    @Test("API error codes map to their account errors")
    func apiErrorCodes() async throws {
        let service = Self.service { request in
            switch request.path {
            case "/v1/checkout":
                return MockReply(status: 409, json: #"{"error":{"code":"already_subscribed","message":"x"}}"#)
            case "/v1/portal":
                return MockReply(status: 409, json: #"{"error":{"code":"no_subscription","message":"x"}}"#)
            case "/v1/subscription/renewal":
                return MockReply(status: 503, json: #"{"error":{"code":"checkout_unavailable","message":"x"}}"#)
            default:
                return MockReply(status: 401, json: #"{"error":{"code":"unauthorized","message":"x"}}"#)
            }
        }
        await #expect(throws: AccountError.alreadySubscribed) {
            try await service.checkoutURL(tokens: Self.tokens, renewal: .automatic)
        }
        await #expect(throws: AccountError.noSubscription) {
            try await service.manageSubscriptionURL(tokens: Self.tokens)
        }
        await #expect(throws: AccountError.checkoutUnavailable) {
            try await service.setAutoRenew(false, tokens: Self.tokens)
        }
    }

    @Test("Manage subscription opens a Stripe billing portal URL")
    func manageSubscription() async throws {
        let service = Self.service { _ in MockReply(json: #"{"url":"https://billing.stripe.com/p/session/test_1"}"#) }
        let url = try await service.manageSubscriptionURL(tokens: Self.tokens)
        #expect(url.host == "billing.stripe.com")
        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.path == "/v1/portal")
        #expect(request.json?.isEmpty == true)
    }

    @Test("Setting renewal returns the signed plan for the access token's account")
    func setAutoRenew() async throws {
        let service = Self.service { _ in
            MockReply(json: #"{"entitlement":{"plan":"plus","status":"active","currentPeriodEnd":"\#(Self.vector.currentPeriodEnd)","cancelAtPeriodEnd":false,"checkedAt":"\#(Self.vector.checkedAt)","signature":"\#(Self.vector.signature)"}}"#)
        }
        let plan = try await service.setAutoRenew(true, tokens: Self.tokens)
        #expect(plan.cancelAtPeriodEnd == false)
        #expect(plan.signature == Self.vector.signature)
        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.path == "/v1/subscription/renewal")
        #expect(request.json?["autoRenew"] as? Bool == true)
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
            try await broken.currentEntitlement(tokens: Self.tokens)
        }
    }

    @Test("Without the live values there is no service, so the app can't reach the network")
    func noServiceWithoutConfiguration() {
        let off = AccountConfiguration.resolve(mode: "live", isDebug: false, baseURL: "", supabaseURL: nil, supabasePublishableKey: "", entitlementPublicKey: "")
        #expect(LiveAccountService(configuration: off, verifier: EntitlementVerifier(base64PublicKey: nil)) == nil)
    }
}
