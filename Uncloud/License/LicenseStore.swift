import Foundation

/// The license saved on this Mac. A key is not an account.
struct StoredLicense: Codable, Equatable, Sendable {
    var key: String
    var tier: LicenseTier
    var seats: Int
    var grandfathered: Bool
    /// True when `/v1/licenses/verify` accepted the key. False when it was saved offline.
    var confirmedOnline: Bool
}

struct LicenseStore {
    var defaults: UserDefaults
    static let storageKey = "uncloud.license.v1"

    static var standard: LicenseStore { LicenseStore(defaults: .standard) }

    func load() -> StoredLicense? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return try? JSONDecoder().decode(StoredLicense.self, from: data)
    }

    func save(_ license: StoredLicense) {
        guard let data = try? JSONEncoder().encode(license) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    var tier: LicenseTier { load()?.tier ?? .free }
}

struct LicenseVerification: Equatable, Sendable {
    var valid: Bool
    var tier: LicenseTier?
    var seats: Int?
    var grandfathered: Bool
}

enum LicenseVerifyError: Error, Equatable {
    case invalid
    case unavailable
}

enum LicenseActivationDecision: Equatable {
    case saved(StoredLicense)
    case rejected(String)
}

enum LicenseActivation {
    static let unrecognized = "That key isn’t recognized."
    static let invalid = "That key isn’t valid."

    /// The server wins when it answers. A network failure still saves a well-formed key on this Mac.
    static func decide(parsed: ParsedLicense, remote: Result<LicenseVerification, LicenseVerifyError>) -> LicenseActivationDecision {
        switch remote {
        case .success(let verification):
            guard verification.valid,
                  verification.tier == parsed.tier,
                  verification.seats == parsed.seats,
                  verification.grandfathered == parsed.grandfathered
            else { return .rejected(invalid) }
            return .saved(stored(parsed, confirmedOnline: true))
        case .failure(.invalid):
            return .rejected(invalid)
        case .failure(.unavailable):
            return .saved(stored(parsed, confirmedOnline: false))
        }
    }

    private static func stored(_ parsed: ParsedLicense, confirmedOnline: Bool) -> StoredLicense {
        StoredLicense(
            key: parsed.key,
            tier: parsed.tier,
            seats: parsed.seats,
            grandfathered: parsed.grandfathered,
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
                if http.statusCode == 400 { return .failure(.invalid) }
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
        if !valid { return .failure(.invalid) }
        let tier = (object["tier"] as? String).flatMap(LicenseTier.init(rawValue:))
        let seats = object["seats"] as? Int
        let grandfathered = object["grandfathered"] as? Bool ?? false
        return .success(LicenseVerification(valid: true, tier: tier, seats: seats, grandfathered: grandfathered))
    }
}
