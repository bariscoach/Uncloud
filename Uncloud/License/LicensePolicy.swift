import CryptoKit
import Foundation

/// Free, Plus, Pro, and Family. Family includes every Pro feature, with more Macs.
enum LicenseTier: String, Codable, CaseIterable, Comparable, Identifiable, Sendable {
    case free, plus, pro, family

    var id: Self { self }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .free: 0
        case .plus: 1
        case .pro: 2
        case .family: 3
        }
    }

    var displayName: String {
        switch self {
        case .free: "Free"
        case .plus: "Plus"
        case .pro: "Pro"
        case .family: "Family"
        }
    }

    /// The Macs included with a purchased key. Free is this Mac, and it is not a key.
    var includedMacs: Int {
        switch self {
        case .free, .plus: 1
        case .pro: 2
        case .family: 5
        }
    }

    var priceLabel: String {
        switch self {
        case .free: "Free"
        case .plus: "$29 once"
        case .pro: "$49 once"
        case .family: "$69 once"
        }
    }

    static var paid: [LicenseTier] { [.plus, .pro, .family] }
}

/// Paid capabilities. Free keeps a manual export of about 1,000 items or a date range, and browse-by-date.
/// Verify Backup, a second destination, and email support are part of Pro. The first two have no screen yet;
/// Help › Contact Support stays available on every tier.
enum LicenseFeature: String, CaseIterable, Sendable {
    case unlimitedExport
    case automaticBackups
    case allLayouts
    case mapPlaceBrowse
    case xmpSidecars
    case verifiedICloudCleanup
    case verifyBackup
    case secondDestination
    case emailSupport
}

/// A signature-checked license. An unsigned key never becomes one of these.
struct ParsedLicense: Equatable, Sendable {
    var key: String
    var tier: LicenseTier
    var seats: Int
    var jti: String
    var issuedAt: Date
}

enum LicensePublicKey {
    /// Test key only. `UncloudLicensePublicKey` in Info.plist replaces it for a release.
    /// Rotate it, and `LICENSE_SIGNING_PRIVATE_KEY`, before turning license limits on.
    static let testRawBase64 = "9eTHD62q5241M5GcgIzPInNbF+/Jsi9c7emeztduWFQ="

    static func raw(bundle: Bundle = .main) -> Data? {
        if let encoded = bundle.object(forInfoDictionaryKey: "UncloudLicensePublicKey") as? String,
           let data = Data(base64Encoded: encoded), data.count == 32 {
            return data
        }
        return Data(base64Encoded: testRawBase64)
    }
}

enum LicenseKey {
    /// Verifies the Ed25519 signature over the canonical payload. Returns nil for any unsigned or altered key.
    static func parse(_ raw: String, publicKey: Data? = LicensePublicKey.raw()) -> ParsedLicense? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "UC1",
              let payload = base64URLDecode(String(parts[1])),
              let signature = base64URLDecode(String(parts[2])),
              signature.count == 64,
              let publicKey, publicKey.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: payload),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              int(object["v"]) == 1,
              let tier = (object["tier"] as? String).flatMap(LicenseTier.init(rawValue:)),
              tier != .free,
              let seats = int(object["seats"]), seats == tier.includedMacs,
              let jti = object["jti"] as? String, (4...128).contains(jti.count),
              let issued = int(object["iat"])
        else { return nil }
        guard canonical(object) == String(data: payload, encoding: .utf8) else { return nil }
        return ParsedLicense(key: token, tier: tier, seats: seats, jti: jti, issuedAt: Date(timeIntervalSince1970: TimeInterval(issued)))
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    /// The same key order as `canonicalLicenseJSON` on the server.
    private static func canonical(_ object: [String: Any]) -> String? {
        var parts: [String] = []
        if let hash = object["emailHash"] as? String {
            guard hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
            parts.append("\"emailHash\":\"\(hash)\"")
        }
        guard let issued = int(object["iat"]), let jti = object["jti"] as? String,
              let seats = int(object["seats"]), let tier = object["tier"] as? String,
              int(object["v"]) == 1 else { return nil }
        parts.append("\"iat\":\(issued)")
        parts.append("\"jti\":\"\(jti)\"")
        parts.append("\"seats\":\(seats)")
        parts.append("\"tier\":\"\(tier)\"")
        parts.append("\"v\":1")
        return "{\(parts.joined(separator: ","))}"
    }

    private static func base64URLDecode(_ text: String) -> Data? {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ CharacterSet.base64URL.contains($0) }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

private extension CharacterSet {
    static let base64URL = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
}

/// One switch for paid limits. Off, which is the default, every feature stays available.
enum LicenseGating {
    static let infoKey = "UncloudLicenseGating"

    static func isEnforced(bundle: Bundle = .main) -> Bool {
        bundle.object(forInfoDictionaryKey: infoKey) as? Bool ?? false
    }
}

enum LicensePolicy {
    static let freeItemCap = 1000
    static let freeExportRefusal = "You’ve exported 1,000 photos for free. Unlock Uncloud to continue."
    /// How long a signed key may be used without a successful revocation check.
    static let revocationGrace: TimeInterval = 14 * 24 * 60 * 60

    static func allows(_ feature: LicenseFeature, tier: LicenseTier, enforced: Bool) -> Bool {
        if !enforced { return true }
        switch feature {
        case .automaticBackups:
            // Automatic backup is a way of exporting. The 1,000-item cap is what stops it.
            return true
        case .unlimitedExport, .allLayouts, .mapPlaceBrowse, .xmpSidecars:
            return tier >= .plus
        case .verifiedICloudCleanup, .verifyBackup, .secondDestination, .emailSupport:
            return tier >= .pro
        }
    }

    /// By Month stays on Free. The other layouts are Plus. A layout the source cannot use stays unavailable.
    static func layoutAvailable(_ layout: FolderLayout, source: LibrarySource, tier: LicenseTier, enforced: Bool) -> Bool {
        guard layout.isAvailable(for: source) else { return false }
        if !enforced || tier >= .plus { return true }
        return layout == .month
    }

    /// Dates are free. Map and Places are Plus.
    static func allowsBrowse(_ mode: BrowseBackup.Mode, tier: LicenseTier, enforced: Bool) -> Bool {
        switch mode {
        case .dates:
            true
        case .map, .places:
            allows(.mapPlaceBrowse, tier: tier, enforced: enforced)
        }
    }

    /// A signed Plus, Pro, or Family key lifts the item cap while its revocation check is still fresh.
    static func unlimited(tier: LicenseTier, activatedAt: Date?, lastCheck: Date?, now: Date, enforced: Bool) -> Bool {
        guard enforced else { return true }
        guard tier >= .plus else { return false }
        guard let anchor = lastCheck ?? activatedAt else { return false }
        return now.timeIntervalSince(anchor) <= revocationGrace
    }
}

/// How many new items the next export may write. Every mode, including a date range, uses this.
struct ExportAllowance: Equatable, Sendable {
    /// Nil when the run is not capped.
    var remaining: Int?
    var blockStart: Bool
    var showPaywall: Bool
}

enum ExportQuota {
    static func allowance(exportedCount: Int, unlimited: Bool, enforced: Bool, cap: Int = LicensePolicy.freeItemCap) -> ExportAllowance {
        if !enforced || unlimited {
            return ExportAllowance(remaining: nil, blockStart: false, showPaywall: false)
        }
        if exportedCount >= cap {
            return ExportAllowance(remaining: 0, blockStart: true, showPaywall: true)
        }
        return ExportAllowance(remaining: cap - exportedCount, blockStart: false, showPaywall: false)
    }
}

/// https checkout URLs from Info.plist. Missing or non-https values are unset.
enum LicenseCheckout {
    static func url(for tier: LicenseTier, bundle: Bundle = .main) -> URL? {
        let key: String
        switch tier {
        case .plus: key = "UncloudCheckoutPlusURL"
        case .pro: key = "UncloudCheckoutProURL"
        case .family: key = "UncloudCheckoutFamilyURL"
        case .free: return nil
        }
        return url(from: bundle.object(forInfoDictionaryKey: key) as? String)
    }

    static func url(from raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

enum LicenseLinks {
    static let website = URL(string: "https://www.tryuncloud.com")!
    static let pricing = URL(string: "https://www.tryuncloud.com/pricing")!
}
