import Foundation

/// One preview account, keyed by email in `PreviewAccountStore`.
struct PreviewAccountRecord: Codable, Equatable, Sendable {
    let id: String
    let email: String
    var plan: Plan
    var status: Entitlement.Status
    var currentPeriodEnd: Date?
    var cancelAtPeriodEnd: Bool
    /// The current refresh token, or nil once signed out.
    var refreshToken: String?
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
/// `offline@example.com` (offline), `slow@example.com` (2 s per call), `limit@example.com` (rate limited),
/// `plus@example.com` (a new account starts on Plus), `pastdue@example.com` (a new account starts past due).
actor PreviewAccountService: AccountService {
    static let code = "123456"
    static let maxAttempts = 5
    static let challengeLifetime: TimeInterval = 10 * 60
    static let resendInterval: TimeInterval = 30
    static let accessLifetime: TimeInterval = 60 * 60
    private static let year: TimeInterval = 365 * 24 * 60 * 60

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
            account: UncloudAccount(id: record.id, email: email),
            tokens: tokens,
            entitlement: Self.entitlement(record, now: current),
            isNewAccount: isNewAccount
        )
    }

    func currentEntitlement(tokens: AccountTokens) async throws -> (Entitlement, AccountTokens) {
        let email = try email(matching: tokens)
        try await simulateDelay(for: email)
        var renewed = tokens
        if now() >= tokens.accessExpiresAt {
            renewed = try await refresh(tokens: tokens)
        }
        guard let record = records[email] else { throw AccountError.signedOut }
        return (Self.entitlement(record, now: now()), renewed)
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

    func checkoutURL(tokens: AccountTokens, renewal: Renewal) async throws -> URL {
        let email = try email(matching: tokens)
        try await simulateDelay(for: email)
        records[email]?.plan = .plus
        records[email]?.status = .active
        records[email]?.currentPeriodEnd = now().addingTimeInterval(Self.year)
        // "One year" is the same subscription, set not to renew (plan §1).
        records[email]?.cancelAtPeriodEnd = renewal == .oneYear
        persist()
        let sessionID = "preview_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return URL(string: "uncloud://checkout/success?session_id=\(sessionID)")!
    }

    func manageSubscriptionURL(tokens: AccountTokens) async throws -> URL {
        _ = try email(matching: tokens)
        return URL(string: "uncloud://account/refresh")!
    }

    func setAutoRenew(_ autoRenew: Bool, tokens: AccountTokens) async throws -> Entitlement {
        let email = try email(matching: tokens)
        try await simulateDelay(for: email)
        guard var record = records[email], record.plan == .plus, [.active, .pastDue].contains(record.status) else {
            throw AccountError.noSubscription
        }
        record.cancelAtPeriodEnd = !autoRenew
        records[email] = record
        persist()
        return Self.entitlement(record, now: now())
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
        var record = PreviewAccountRecord(
            id: UUID().uuidString,
            email: email,
            plan: .free,
            status: .none,
            currentPeriodEnd: nil,
            cancelAtPeriodEnd: false,
            refreshToken: nil
        )
        switch email {
        case "plus@example.com":
            record.plan = .plus
            record.status = .active
            record.currentPeriodEnd = now.addingTimeInterval(year)
        case "pastdue@example.com":
            // The period ended a day ago and the renewal payment failed, so the grace period is running.
            record.plan = .plus
            record.status = .pastDue
            record.currentPeriodEnd = now.addingTimeInterval(-24 * 60 * 60)
        default:
            break
        }
        return record
    }

    private static func entitlement(_ record: PreviewAccountRecord, now: Date) -> Entitlement {
        Entitlement(
            plan: record.plan,
            status: record.status,
            currentPeriodEnd: record.currentPeriodEnd,
            cancelAtPeriodEnd: record.cancelAtPeriodEnd,
            checkedAt: now
        )
    }
}
