import Foundation
import Security

/// Keeps the Apple ID password in the Keychain so icloudpd can be answered without asking again.
enum ICloudCredentialStore {
    private static let service = "Uncloud iCloud"

    /// Saves or replaces the password for an Apple ID.
    static func savePassword(_ password: String, for appleID: String) throws {
        let query = baseQuery(for: appleID)
        let data = Data(password.utf8)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw keychainError(updateStatus)
            }
        } else if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw keychainError(addStatus)
            }
        } else {
            throw keychainError(status)
        }
    }

    /// Returns the saved password for an Apple ID, if there is one.
    static func password(for appleID: String) -> String? {
        var query = baseQuery(for: appleID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Removes the saved password for an Apple ID. Does nothing if there isn't one.
    static func deletePassword(for appleID: String) {
        SecItemDelete(baseQuery(for: appleID) as CFDictionary)
    }

    private static func baseQuery(for appleID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: appleID,
        ]
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        return NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
