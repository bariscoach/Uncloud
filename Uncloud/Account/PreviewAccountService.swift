import Foundation

/// One preview account, keyed by email in `PreviewAccountStore`.
struct PreviewAccountRecord: Codable, Equatable, Sendable {
    let id: String
    let email: String
    /// The current refresh token, or nil once signed out.
    var refreshToken: String?
    /// When the account was created. Optional so records saved before it existed still load.
    var createdAt: Date? = nil
}

/// Preview accounts in a UserDefaults suite, so they survive relaunches. Tests pass a fresh suite.
/// UserDefaults is thread-safe, which is what makes the `@unchecked` conformance honest.
struct PreviewAccountStore: @unchecked Sendable {
    static let suiteName = "com.example.Uncloud.preview-account"
    private static let key = "accounts"

    let defaults: UserDefaults

    func load() -> [String: PreviewAccountRecord] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: PreviewAccountRecord].self, from: data)) ?? [:]
    }

    func save(_ records: [String: PreviewAccountRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// The stub account backend for Debug builds and tests. Deterministic, no network.
///
/// The code is always `123456`. Simulation emails show every error state without a server:
/// `offline@example.com` (offline), `slow@example.com` (2 s per call), `limit@example.com` (rate limited).
actor PreviewAccountService: AccountService {
    static let code = "123456"
    static let maxAttempts = 5
    static let challengeLifetime: TimeInterval = 10 * 60
    static let resendInterval: TimeInterval = 30
    static let accessLifetime: TimeInterval = 60 * 60

    private struct PendingChallenge {
        let email: String
        let expiresAt: Date
        var attempts: Int
    }

    private let store: PreviewAccountStore
    private let now: @Sendable () -> Date
    private var records: [String: PreviewAccountRecord]
    private var challenges: [String: PendingChallenge] = [:]
    private var resendAfter: [String: Date] = [:]

    init(
        store: PreviewAccountStore = PreviewAccountStore(defaults: UserDefaults(suiteName: PreviewAccountStore.suiteName) ?? .standard),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
        records = store.load()
    }

    func requestCode(email rawEmail: String, intent: AuthIntent) async throws -> AuthChallenge {
        guard let email = EmailAddress.normalized(rawEmail) else { throw AccountError.invalidEmail }
        try await simulateDelay(for: email)
        if email == "offline@example.com" { throw AccountError.offline }
        if email == "limit@example.com" { throw AccountError.rateLimited(retryAfter: now().addingTimeInterval(5 * 60)) }

        let current = now()
        if let until = resendAfter[email], current < until {
            throw AccountError.rateLimited(retryAfter: until)
        }
        let challenge = AuthChallenge(
            id: UUID().uuidString,
            email: email,
            expiresAt: current.addingTimeInterval(Self.challengeLifetime),
            resendAfter: current.addingTimeInterval(Self.resendInterval)
        )
        challenges[challenge.id] = PendingChallenge(email: email, expiresAt: challenge.expiresAt, attempts: 0)
        resendAfter[email] = challenge.resendAfter
        return challenge
    }

    func verify(challenge: AuthChallenge, code: String) async throws -> AuthSession {
        try await simulateDelay(for: challenge.email)
        guard var pending = challenges[challenge.id] else { throw AccountError.codeExpired }
        let current = now()
        guard current < pending.expiresAt else {
            challenges[challenge.id] = nil
            throw AccountError.codeExpired
        }
        guard pending.attempts < Self.maxAttempts else { throw AccountError.tooManyAttempts }
        guard OneTimeCode.sanitized(code) == Self.code else {
            pending.attempts += 1
            challenges[challenge.id] = pending
            throw pending.attempts >= Self.maxAttempts ? AccountError.tooManyAttempts : AccountError.wrongCode
        }

        challenges[challenge.id] = nil
        let email = pending.email
        let isNewAccount = records[email] == nil
        var record = records[email] ?? Self.newRecord(email: email, now: current)
        let tokens = Self.issueTokens(now: current)
        record.refreshToken = tokens.refreshToken
        records[email] = record
        persist()
        return AuthSession(
            account: UncloudAccount(id: record.id, email: email, createdAt: record.createdAt),
            tokens: tokens,
            isNewAccount: isNewAccount
        )
    }

    func currentAccount(tokens: AccountTokens) async throws -> UncloudAccount {
        let email = try email(matching: tokens)
        try await simulateDelay(for: email)
        guard let record = records[email] else { throw AccountError.signedOut }
        return UncloudAccount(id: record.id, email: record.email, createdAt: record.createdAt)
    }

    func refresh(tokens: AccountTokens) async throws -> AccountTokens {
        let email = try email(matching: tokens)
        let renewed = Self.issueTokens(now: now())
        records[email]?.refreshToken = renewed.refreshToken
        persist()
        return renewed
    }

    func signOut(tokens: AccountTokens) async {
        guard let email = try? email(matching: tokens) else { return }
        records[email]?.refreshToken = nil
        persist()
    }

    func deleteAccount(confirmEmail: String, tokens: AccountTokens) async throws {
        let email = try email(matching: tokens)
        guard let typed = EmailAddress.normalized(confirmEmail), typed == email else {
            throw AccountError.confirmationMismatch
        }
        try await simulateDelay(for: email)
        if email == "offline@example.com" { throw AccountError.offline }
        records[email] = nil
        persist()
    }

    // MARK: - Helpers

    /// The account whose refresh token is `tokens.refreshToken`. Anything else is signed out.
    private func email(matching tokens: AccountTokens) throws -> String {
        guard let match = records.first(where: { $0.value.refreshToken == tokens.refreshToken }) else {
            throw AccountError.signedOut
        }
        return match.key
    }

    private func simulateDelay(for email: String) async throws {
        if email == "slow@example.com" {
            try await Task.sleep(for: .seconds(2))
        }
    }

    private func persist() {
        store.save(records)
    }

    private static func issueTokens(now: Date) -> AccountTokens {
        AccountTokens(
            accessToken: "preview-access-" + UUID().uuidString,
            refreshToken: "preview-refresh-" + UUID().uuidString,
            accessExpiresAt: now.addingTimeInterval(accessLifetime)
        )
    }

    private static func newRecord(email: String, now: Date) -> PreviewAccountRecord {
        PreviewAccountRecord(id: UUID().uuidString, email: email, refreshToken: nil, createdAt: now)
    }
}
