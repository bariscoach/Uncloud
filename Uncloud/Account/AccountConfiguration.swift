import Foundation
import os

/// Which account features a build has. Each build sets it in Info.plist as `UncloudAccountMode` (plan A.6).
enum AccountMode: String, Equatable, Sendable {
    /// No accounts, no locks: the app is exactly the free build.
    case off
    /// Fake accounts and a fake plan. Debug builds only.
    case preview
    /// The real server (`LiveAccountService`). Needs every live value below, or it resolves to `off`.
    case live
}

struct AccountConfiguration: Equatable, Sendable {
    let mode: AccountMode
    /// The Vercel API base URL (`UncloudAPIBaseURL`). https only. Set for `live` only.
    let apiBaseURL: URL?
    /// The Supabase project URL (`UncloudSupabaseURL`). https only. Set for `live` only.
    let supabaseURL: URL?
    /// The Supabase publishable key (`UncloudSupabasePublishableKey`). Public by design. Set for `live` only.
    let supabasePublishableKey: String?
    /// The public half of the entitlement signing key, base64 of 32 raw bytes (`UncloudEntitlementPublicKey`).
    let entitlementPublicKey: String?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Uncloud", category: "account")

    /// The configuration of this launch.
    ///
    /// Debug builds accept launch arguments (or user defaults) to switch the mode:
    /// `-UncloudAccountMode off|preview|live`, and `-UncloudAPIBaseURL https://…` to point `live` elsewhere.
    /// A Debug build runs `live` against the test backend with `-UncloudAccountMode live`, passed as a scheme
    /// launch argument or on the command line. Release ignores both and always reads Info.plist.
    static var current: AccountConfiguration {
        let info = Bundle.main.infoDictionary
        var mode = info?["UncloudAccountMode"] as? String
        var baseURL = info?["UncloudAPIBaseURL"] as? String
        #if DEBUG
        let isDebug = true
        let defaults = UserDefaults.standard
        if let override = defaults.string(forKey: "UncloudAccountMode"), ["off", "preview", "live"].contains(override) {
            mode = override
        }
        if let override = defaults.string(forKey: "UncloudAPIBaseURL"), !override.isEmpty {
            baseURL = override
        }
        #else
        let isDebug = false
        #endif
        return resolve(
            mode: mode,
            isDebug: isDebug,
            baseURL: baseURL,
            supabaseURL: info?["UncloudSupabaseURL"] as? String,
            supabasePublishableKey: info?["UncloudSupabasePublishableKey"] as? String,
            entitlementPublicKey: info?["UncloudEntitlementPublicKey"] as? String
        )
    }

    /// The effective configuration for a build. Anything that could ship a fake plan, or lock people out by mistake,
    /// becomes `off`. A half-filled `live` configuration is `off` too, never a lockout.
    static func resolve(
        mode raw: String?,
        isDebug: Bool,
        baseURL: String?,
        supabaseURL: String?,
        supabasePublishableKey: String?,
        entitlementPublicKey: String?
    ) -> AccountConfiguration {
        switch raw.flatMap(AccountMode.init(rawValue:)) ?? .off {
        case .off:
            return off
        case .preview:
            return isDebug ? AccountConfiguration(mode: .preview, apiBaseURL: nil, supabaseURL: nil, supabasePublishableKey: nil, entitlementPublicKey: nil) : off
        case .live:
            guard let api = httpsURL(baseURL), let supabase = httpsURL(supabaseURL),
                  let key = nonEmpty(supabasePublishableKey), let publicKey = nonEmpty(entitlementPublicKey),
                  Data(base64Encoded: publicKey)?.count == 32 else {
                logger.error("UncloudAccountMode is live but the account configuration is incomplete. Accounts are off.")
                return off
            }
            return AccountConfiguration(
                mode: .live,
                apiBaseURL: api,
                supabaseURL: supabase,
                supabasePublishableKey: key,
                entitlementPublicKey: publicKey
            )
        }
    }

    private static let off = AccountConfiguration(mode: .off, apiBaseURL: nil, supabaseURL: nil, supabasePublishableKey: nil, entitlementPublicKey: nil)

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func httpsURL(_ value: String?) -> URL? {
        guard let text = nonEmpty(value), let url = URL(string: text), url.scheme == "https", url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
}
