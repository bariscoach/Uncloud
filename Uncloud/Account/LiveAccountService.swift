import Foundation

/// Dates on the wire: ISO 8601 UTC. The server writes whole seconds; Supabase may add fractions.
enum WireDate {
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

extension URLSession {
    /// The session the account service uses: no cookies, no cache, 15 s timeouts, and no waiting for a connection.
    static let uncloud: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}

/// The real account backend. Sign-in goes straight to Supabase Auth over REST; the account is confirmed with the
/// Vercel API (`/v1/me`), which the app reads for identity only. Tokens are never logged.
actor LiveAccountService: AccountService {
    static let otpLifetime: TimeInterval = 10 * 60
    static let resendInterval: TimeInterval = 60
    static let maxWrongCodes = 5

    private let apiBaseURL: URL
    private let supabaseURL: URL
    private let publishableKey: String
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let userAgent: String
    /// Wrong codes per challenge id. The fifth wrong code ends the challenge.
    private var wrongCodes: [String: Int] = [:]

    /// Nil unless `configuration` is `live` with all its values, so the app can never reach the network by accident.
    init?(
        configuration: AccountConfiguration,
        session: URLSession = .uncloud,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        guard configuration.mode == .live, let api = configuration.apiBaseURL,
              let supabase = configuration.supabaseURL, let key = configuration.supabasePublishableKey else {
            return nil
        }
        apiBaseURL = api
        supabaseURL = supabase
        publishableKey = key
        self.session = session
        self.now = now
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        userAgent = "Uncloud/\(version) (macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion))"
    }

    // MARK: - AccountService

    func requestCode(email: String, intent: AuthIntent) async throws -> AuthChallenge {
        let url = try endpoint(supabaseURL, "/auth/v1/otp")
        let reply = try await send("POST", url, json: ["email": email, "create_user": true], supabase: true)
        guard reply.isSuccess else { throw requestCodeError(reply) }
        let current = now()
        return AuthChallenge(
            id: UUID().uuidString,
            email: email,
            expiresAt: current.addingTimeInterval(Self.otpLifetime),
            resendAfter: current.addingTimeInterval(Self.resendInterval)
        )
    }

    func verify(challenge: AuthChallenge, code: String) async throws -> AuthSession {
        if wrongCodes[challenge.id, default: 0] >= Self.maxWrongCodes {
            throw AccountError.tooManyAttempts
        }
        let url = try endpoint(supabaseURL, "/auth/v1/verify")
        let reply = try await send(
            "POST", url,
            json: ["type": "email", "email": challenge.email, "token": code],
            supabase: true
        )
        guard reply.isSuccess else { throw verifyError(reply, challenge: challenge) }
        wrongCodes[challenge.id] = nil

        let body = try decodeSupabase(SupabaseSession.self, reply.data)
        guard let user = body.user else { throw AccountError.server(message: nil) }
        let tokens = accountTokens(from: body)
        // A failed confirmation must not block the sign-in: the Supabase user is enough to sign in.
        let confirmed = try? await currentAccount(tokens: tokens)
        var signedIn = confirmed ?? UncloudAccount(id: user.id, email: user.email ?? challenge.email)
        signedIn.createdAt = user.createdAt.flatMap(WireDate.parse)
        return AuthSession(
            account: signedIn,
            tokens: tokens,
            isNewAccount: Self.isNewAccount(user)
        )
    }

    func currentAccount(tokens: AccountTokens) async throws -> UncloudAccount {
        let reply = try await send("GET", try endpoint(apiBaseURL, "/v1/me"), bearer: tokens.accessToken, supabase: false)
        guard reply.isSuccess else { throw apiError(reply) }
        let body = try decode(MeBody.self, reply.data)
        return UncloudAccount(id: body.account.id, email: body.account.email)
    }

    func refresh(tokens: AccountTokens) async throws -> AccountTokens {
        let url = try endpoint(supabaseURL, "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")])
        let reply = try await send("POST", url, json: ["refresh_token": tokens.refreshToken], supabase: true)
        guard reply.isSuccess else { throw refreshError(reply) }
        return accountTokens(from: try decodeSupabase(SupabaseSession.self, reply.data))
    }

    func signOut(tokens: AccountTokens) async {
        guard let url = try? endpoint(supabaseURL, "/auth/v1/logout", query: [URLQueryItem(name: "scope", value: "local")]) else {
            return
        }
        _ = try? await send("POST", url, bearer: tokens.accessToken, supabase: true)
    }

    func deleteAccount(confirmEmail: String, tokens: AccountTokens) async throws {
        // 204 on success. The server deletes the Supabase user and its rows (plan §4.2).
        _ = try await apiPost("/v1/account/delete", ["confirmEmail": confirmEmail], tokens: tokens)
    }

    // MARK: - Error mapping (plan §6.2 and §4.4)

    private func requestCodeError(_ reply: Reply) -> AccountError {
        let failure = decodeFailure(reply.data)
        switch reply.status {
        case 429:
            return .rateLimited(retryAfter: retryAfter(fromMessage: failure?.msg) ?? now().addingTimeInterval(60))
        case 400, 422:
            if ["validation_failed", "email_address_invalid"].contains(failure?.errorCode ?? "") {
                return .invalidEmail
            }
            return .server(message: nil)
        default:
            // Supabase answers 500 "Error sending confirmation email" when its mail sender refuses the address.
            if reply.status >= 500, failure?.msg?.localizedCaseInsensitiveContains("sending") == true {
                return .server(message: Self.codeEmailNotSent)
            }
            return .server(message: nil)
        }
    }

    static let codeEmailNotSent = "Uncloud couldn’t send the code email. Try again later."

    private func verifyError(_ reply: Reply, challenge: AuthChallenge) -> AccountError {
        if reply.status == 429 {
            return .tooManyAttempts
        }
        guard [400, 401, 403, 422].contains(reply.status) else {
            return .server(message: nil)
        }
        if now() >= challenge.expiresAt {
            return .codeExpired
        }
        let wrong = wrongCodes[challenge.id, default: 0] + 1
        wrongCodes[challenge.id] = wrong
        return wrong >= Self.maxWrongCodes ? .tooManyAttempts : .wrongCode
    }

    private func refreshError(_ reply: Reply) -> AccountError {
        let signedOutCodes = ["refresh_token_not_found", "refresh_token_already_used", "session_not_found"]
        if reply.status == 401 || (reply.status == 400 && signedOutCodes.contains(decodeFailure(reply.data)?.errorCode ?? "")) {
            return .signedOut
        }
        return .server(message: nil)
    }

    private func apiError(_ reply: Reply) -> AccountError {
        let body = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: reply.data))?.error
        switch body?.code {
        case "unauthorized":
            return .signedOut
        case "rate_limited":
            return .rateLimited(retryAfter: retryAfter(reply))
        case "confirmation_mismatch":
            return .confirmationMismatch
        default:
            switch reply.status {
            case 401: return .signedOut
            case 429: return .rateLimited(retryAfter: retryAfter(reply))
            default: return .server(message: body?.message)
            }
        }
    }

    private func retryAfter(_ reply: Reply) -> Date? {
        guard let text = reply.http.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(text) else {
            return nil
        }
        return now().addingTimeInterval(seconds)
    }

    /// Supabase says "... after 42 seconds" in its message when it rate limits a code request.
    private func retryAfter(fromMessage message: String?) -> Date? {
        guard let message, let match = message.firstMatch(of: /after (\d+) seconds/), let seconds = TimeInterval(String(match.1)) else {
            return nil
        }
        return now().addingTimeInterval(seconds)
    }

    // MARK: - Transport

    private struct Reply {
        let status: Int
        let data: Data
        let http: HTTPURLResponse

        var isSuccess: Bool { (200..<300).contains(status) }
    }

    private func apiPost(_ path: String, _ body: [String: Any], tokens: AccountTokens) async throws -> Reply {
        let reply = try await send("POST", try endpoint(apiBaseURL, path), json: body, bearer: tokens.accessToken, supabase: false)
        guard reply.isSuccess else { throw apiError(reply) }
        return reply
    }

    /// One request. Network failures become `.offline`; cancellation stays a `CancellationError`.
    private func send(
        _ method: String,
        _ url: URL,
        json: [String: Any]? = nil,
        bearer: String? = nil,
        supabase: Bool
    ) async throws -> Reply {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if supabase {
            request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        }
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: json)
            } catch {
                throw AccountError.server(message: nil)
            }
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AccountError.server(message: nil) }
            return Reply(status: http.statusCode, data: data, http: http)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AccountError.offline
        }
    }

    private func endpoint(_ base: URL, _ path: String, query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { throw AccountError.server(message: nil) }
        return url
    }

    // MARK: - Decoding

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AccountError.server(message: nil)
        }
    }

    private func decodeSupabase<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw AccountError.server(message: nil)
        }
    }

    private func decodeFailure(_ data: Data) -> SupabaseFailure? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(SupabaseFailure.self, from: data)
    }

    private func accountTokens(from session: SupabaseSession) -> AccountTokens {
        let expires = session.expiresAt.map { Date(timeIntervalSince1970: $0) }
            ?? now().addingTimeInterval(session.expiresIn ?? 3600)
        return AccountTokens(accessToken: session.accessToken, refreshToken: session.refreshToken, accessExpiresAt: expires)
    }

    /// True when the account was created by this sign-in: the email was confirmed within a minute of the sign-in.
    private static func isNewAccount(_ user: SupabaseSession.User) -> Bool {
        guard let confirmed = user.emailConfirmedAt.flatMap(WireDate.parse),
              let signedIn = user.lastSignInAt.flatMap(WireDate.parse) else {
            return false
        }
        return abs(confirmed.timeIntervalSince(signedIn)) < 60
    }

    // MARK: - Wire types

    private struct SupabaseSession: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Double?
        let expiresIn: Double?
        let user: User?

        struct User: Decodable {
            let id: String
            let email: String?
            let emailConfirmedAt: String?
            let lastSignInAt: String?
            let createdAt: String?
        }
    }

    /// Supabase's error shape. Only the fields the app reads.
    private struct SupabaseFailure: Decodable {
        let errorCode: String?
        let msg: String?
    }

    private struct APIErrorEnvelope: Decodable {
        struct Body: Decodable {
            let code: String
            let message: String?
        }
        let error: Body
    }

    /// `/v1/me`. Only the identity is read; any other fields the server sends are ignored.
    private struct MeBody: Decodable {
        let account: AccountBody
    }

    private struct AccountBody: Decodable {
        let id: String
        let email: String
    }
}
