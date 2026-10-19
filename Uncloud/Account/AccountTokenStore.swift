import Foundation
import Security

/// Keeps the account tokens between launches. Live builds use the Keychain; preview builds use UserDefaults,
/// because their tokens are fake.
protocol AccountTokenStore: Sendable {
    func load() -> AccountTokens?
    func save(_ tokens: AccountTokens) throws
    func clear()
}

/// UserDefaults is thread-safe, which is what makes the `@unchecked` conformance honest.
struct DefaultsAccountTokenStore: AccountTokenStore, @unchecked Sendable {
    static let key = "uncloudAccountTokens"
    let defaults: UserDefaults

    func load() -> AccountTokens? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(AccountTokens.self, from: data)
    }

    func save(_ tokens: AccountTokens) throws {
        defaults.set(try JSONEncoder().encode(tokens), forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// One generic-password Keychain item holding the tokens as JSON. A missing or unreadable item loads as nil,
/// so the user is asked to sign in again rather than the app failing.
struct KeychainAccountTokenStore: AccountTokenStore {
    private let service: String

    init(service: String = "\(Bundle.main.bundleIdentifier ?? "com.example.Uncloud").uncloud-account") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "tokens",
        ]
    }

    func load() -> AccountTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(AccountTokens.self, from: data)
    }

    func save(_ tokens: AccountTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status: OSStatus
        if SecItemCopyMatching(baseQuery as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        } else {
            var item = baseQuery
            item.merge(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw AccountTokenStoreError.keychain(status)
        }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

enum AccountTokenStoreError: Error, Equatable {
    case keychain(OSStatus)
}
