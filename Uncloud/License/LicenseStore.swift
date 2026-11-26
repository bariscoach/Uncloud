import Foundation
import Security

/// The license saved on this Mac. A key is not an account. Only a signature-checked key is stored.
struct StoredLicense: Codable, Equatable, Sendable {
    var key: String
    var tier: LicenseTier
    var seats: Int
    var jti: String
    var issuedAt: Date
    var activatedAt: Date
    /// Set when `/v1/licenses/verify` last said the key was not revoked.
    var lastRevocationCheck: Date?
    var confirmedOnline: Bool
}

protocol LicensePersisting: Sendable {
    func load() -> StoredLicense?
    func save(_ license: StoredLicense)
    func clear()
}

final class MemoryLicenseStore: LicensePersisting, @unchecked Sendable {
    var license: StoredLicense?
    func load() -> StoredLicense? { license }
    func save(_ license: StoredLicense) { self.license = license }
    func clear() { license = nil }
}

/// Login-keychain item. It is not in the app container, so deleting Uncloud leaves it in place.
struct KeychainLicenseStore: LicensePersisting, @unchecked Sendable {
    let service: String
    let account: String

    init(service: String = "\(Bundle.main.bundleIdentifier ?? "com.example.Uncloud").license", account: String = "license") {
        self.service = service
        self.account = account
    }

    func load() -> StoredLicense? {
        guard let data = KeychainBlob.load(service: service, account: account) else { return nil }
        return try? JSONDecoder().decode(StoredLicense.self, from: data)
    }

    func save(_ license: StoredLicense) {
        guard let data = try? JSONEncoder().encode(license) else { return }
        try? KeychainBlob.save(data, service: service, account: account)
    }

    func clear() {
        KeychainBlob.delete(service: service, account: account)
    }
}

enum LicenseStore {
    /// App state read from the main window and `ExportModel`. A `static var` of a
    /// `Sendable` value is shared mutable state, which Swift 6 rejects unless it is isolated.
    @MainActor static var current: any LicensePersisting = KeychainLicenseStore()
    @MainActor static var tier: LicenseTier { current.load()?.tier ?? .free }

    @MainActor static func unlimited(now: Date = Date(), enforced: Bool = LicenseGating.isEnforced()) -> Bool {
        guard let license = current.load() else {
            return LicensePolicy.unlimited(tier: .free, activatedAt: nil, lastCheck: nil, now: now, enforced: enforced)
        }
        return LicensePolicy.unlimited(
            tier: license.tier,
            activatedAt: license.activatedAt,
            lastCheck: license.lastRevocationCheck,
            now: now,
            enforced: enforced
        )
    }
}

/// The count of items this Mac has exported. This-device-only, so another Mac starts at zero,
/// and outside the app container, so a reinstall keeps it.
protocol ExportCountStoring: Sendable {
    func load() -> Int
    func add(_ count: Int)
}

final class MemoryExportCountStore: ExportCountStoring, @unchecked Sendable {
    var count = 0
    func load() -> Int { count }
    func add(_ count: Int) { self.count += max(0, count) }
}

struct KeychainExportCountStore: ExportCountStoring {
    let service: String
    init(service: String = "\(Bundle.main.bundleIdentifier ?? "com.example.Uncloud").export-count") {
        self.service = service
    }

    func load() -> Int {
        guard let data = KeychainBlob.load(service: service, account: "count"),
              let text = String(data: data, encoding: .utf8),
              let count = Int(text) else { return 0 }
        return max(0, count)
    }

    func add(_ count: Int) {
        guard count > 0 else { return }
        let next = load() + count
        let data = Data(String(next).utf8)
        try? KeychainBlob.save(data, service: service, account: "count")
    }
}

enum ExportCountStore {
    /// Same isolation as `LicenseStore.current`: the counter is only touched from `ExportModel`.
    @MainActor static var current: any ExportCountStoring = KeychainExportCountStore()
}

enum KeychainBlob {
    static func load(service: String, account: String) -> Data? {
        var query = base(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ data: Data, service: String, account: String) throws {
        let query = base(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // This device only, and the login keychain rather than the app container.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var item = query
            item.merge(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainBlobError.status(status) }
    }

    static func delete(service: String, account: String) {
        SecItemDelete(base(service: service, account: account) as CFDictionary)
    }

    private static func base(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum KeychainBlobError: Error {
    case status(OSStatus)
}

struct LicenseVerification: Equatable, Sendable {
    var valid: Bool
    var tier: LicenseTier?
    var seats: Int?
    var reason: String?
}

enum LicenseVerifyError: Error, Equatable {
    case invalid
    case revoked
    case unavailable
}

enum LicenseActivationDecision: Equatable {
    case saved(StoredLicense)
    case rejected(String)
}

enum LicenseActivation {
    static let unrecognized = "That key isn’t recognized."
    static let invalid = "That key isn’t valid."
    static let revoked = "That license was refunded and can’t be used."

    /// The signature is checked before this is called. A network failure keeps a signed key.
    /// A revocation answer removes it. An unsigned key never reaches here.
    static func decide(
        parsed: ParsedLicense,
        remote: Result<LicenseVerification, LicenseVerifyError>,
        now: Date = Date()
    ) -> LicenseActivationDecision {
        switch remote {
        case .success(let verification):
            guard verification.valid, verification.tier == parsed.tier, verification.seats == parsed.seats else {
                return .rejected(verification.reason == "revoked" ? revoked : invalid)
            }
            return .saved(stored(parsed, confirmedOnline: true, lastCheck: now, now: now))
        case .failure(.invalid):
            return .rejected(invalid)
        case .failure(.revoked):
            return .rejected(revoked)
        case .failure(.unavailable):
            return .saved(stored(parsed, confirmedOnline: false, lastCheck: nil, now: now))
        }
    }

    private static func stored(_ parsed: ParsedLicense, confirmedOnline: Bool, lastCheck: Date?, now: Date) -> StoredLicense {
        StoredLicense(
            key: parsed.key,
            tier: parsed.tier,
            seats: parsed.seats,
            jti: parsed.jti,
            issuedAt: parsed.issuedAt,
            activatedAt: now,
            lastRevocationCheck: lastCheck,
            confirmedOnline: confirmedOnline
        )
    }
}

struct LicenseVerifier: Sendable {
    var verify: @Sendable (String) async -> Result<LicenseVerification, LicenseVerifyError>

    static func live(baseURL: URL?) -> LicenseVerifier {
        LicenseVerifier { key in
            guard let baseURL else { return .failure(.unavailable) }
            let endpoint = baseURL
                .appendingPathComponent("v1")
                .appendingPathComponent("licenses")
                .appendingPathComponent("verify")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["key": key])
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return .failure(.unavailable) }
                if http.statusCode == 503 { return .failure(.unavailable) }
                guard http.statusCode == 200 else { return .failure(.unavailable) }
                return decode(data)
            } catch {
                return .failure(.unavailable)
            }
        }
    }

    static func baseURL(bundle: Bundle = .main) -> URL? {
        LicenseCheckout.url(from: bundle.object(forInfoDictionaryKey: "UncloudAPIBaseURL") as? String)
    }

    static func decode(_ data: Data) -> Result<LicenseVerification, LicenseVerifyError> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.unavailable)
        }
        guard let valid = object["valid"] as? Bool else { return .failure(.unavailable) }
        if !valid {
            return (object["reason"] as? String) == "revoked" ? .failure(.revoked) : .failure(.invalid)
        }
        let tier = (object["tier"] as? String).flatMap(LicenseTier.init(rawValue:))
        let seats = (object["seats"] as? NSNumber)?.intValue ?? object["seats"] as? Int
        return .success(LicenseVerification(valid: true, tier: tier, seats: seats, reason: nil))
    }
}
