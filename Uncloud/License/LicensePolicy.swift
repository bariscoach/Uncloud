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

/// A key the stub understands: `UC1.<tier>.<seats>.<flag>.<nonce>`.
struct ParsedLicense: Equatable, Sendable {
    var key: String
    var tier: LicenseTier
    var seats: Int
    var grandfathered: Bool
}

enum LicenseKey {
    /// The same shape `server/uncloud-api/lib/licenses.js` accepts. Grandfathered keys are lifetime Plus.
    static func parse(_ raw: String) -> ParsedLicense? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "UC1" else { return nil }
        guard let tier = LicenseTier(rawValue: String(parts[1])), tier != .free else { return nil }
        guard let seats = Int(parts[2]), String(seats) == String(parts[2]), seats == tier.includedMacs else { return nil }
        let flag = parts[3]
        guard flag == "s" || flag == "g" else { return nil }
        if flag == "g", tier != .plus { return nil }
        let nonce = parts[4]
        guard (8...64).contains(nonce.count), nonce.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return ParsedLicense(key: key, tier: tier, seats: seats, grandfathered: flag == "g")
    }
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
    static let freeExportRefusal = "This export needs Uncloud Plus. Free includes about 1,000 items, or a date range."
    static let automaticBackupRefusal = "Automatic backup didn’t run: it needs Uncloud Plus."

    static func allows(_ feature: LicenseFeature, tier: LicenseTier, enforced: Bool) -> Bool {
        if !enforced { return true }
        switch feature {
        case .unlimitedExport, .automaticBackups, .allLayouts, .mapPlaceBrowse, .xmpSidecars:
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

    /// Nil when the export may start. A date range is free at any size. A full library over the cap needs Plus.
    static func exportRefusal(
        selection: LibrarySelection,
        itemCount: Int?,
        isDateRange: Bool,
        tier: LicenseTier,
        enforced: Bool
    ) -> String? {
        guard enforced, tier < .plus else { return nil }
        if isDateRange { return nil }
        switch selection {
        case .only:
            if let itemCount, itemCount <= freeItemCap { return nil }
            return freeExportRefusal
        case .allExcept:
            if let itemCount, itemCount <= freeItemCap { return nil }
            return freeExportRefusal
        }
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
