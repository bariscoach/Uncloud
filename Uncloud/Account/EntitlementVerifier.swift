import CryptoKit
import Foundation

/// Dates on the wire: ISO 8601 UTC. The server writes whole seconds; Supabase may add fractions.
enum WireDate {
    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return formatter.string(from: date)
    }

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

/// Checks the server's Ed25519 signature over an entitlement (plan §4.5). The message is the exact bytes the server signs.
/// Without a public key, nothing verifies, so `live` never trusts an unsigned plan.
struct EntitlementVerifier: Sendable {
    static let domain = "uncloud-entitlement-v1"

    let publicKey: Curve25519.Signing.PublicKey?

    init(publicKey: Curve25519.Signing.PublicKey?) {
        self.publicKey = publicKey
    }

    /// From the base64 public key in Info.plist. A missing or malformed key gives a verifier that rejects everything.
    init(base64PublicKey: String?) {
        if let base64PublicKey, let raw = Data(base64Encoded: base64PublicKey),
           let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) {
            publicKey = key
        } else {
            publicKey = nil
        }
    }

    func isValid(_ entitlement: Entitlement, accountID: String) -> Bool {
        guard let publicKey, let encoded = entitlement.signature, let signature = Data(base64Encoded: encoded) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: Data(Self.message(entitlement, accountID: accountID).utf8))
    }

    /// `uncloud-entitlement-v1\n<accountId>\n<plan>\n<status>\n<currentPeriodEnd or empty>\n<true|false>\n<checkedAt>`
    static func message(_ entitlement: Entitlement, accountID: String) -> String {
        [
            domain,
            accountID,
            entitlement.plan.rawValue,
            entitlement.status.rawValue,
            entitlement.currentPeriodEnd.map(WireDate.format) ?? "",
            entitlement.cancelAtPeriodEnd ? "true" : "false",
            WireDate.format(entitlement.checkedAt),
        ].joined(separator: "\n")
    }
}
