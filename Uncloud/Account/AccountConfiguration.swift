import Foundation
import os

/// Which account features a build has. Each build sets it in Info.plist as `UncloudAccountMode` (plan A.6).
enum AccountMode: String, Equatable, Sendable {
    /// No accounts, no locks: the app is exactly the free build.
    case off
    /// Fake accounts and a fake plan. Debug builds only.
    case preview
    /// The real server. Not built yet, so `AccountModel` treats it as `off`.
    case live
}

struct AccountConfiguration: Equatable, Sendable {
    let mode: AccountMode
    /// The API base URL for `live`. https only.
    let apiBaseURL: URL?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Uncloud", category: "account")

    /// The configuration of this launch. Debug builds accept `-UncloudAccountMode off|preview` to compare the two.
    static var current: AccountConfiguration {
        let info = Bundle.main.infoDictionary
        var mode = info?["UncloudAccountMode"] as? String
        #if DEBUG
        let isDebug = true
        if let override = UserDefaults.standard.string(forKey: "UncloudAccountMode"), ["off", "preview"].contains(override) {
            mode = override
        }
        #else
        let isDebug = false
        #endif
        return resolve(mode: mode, isDebug: isDebug, baseURL: info?["UncloudAPIBaseURL"] as? String)
    }

    /// The effective configuration for a build. Anything that could ship a fake plan, or lock people out by mistake, becomes `off`.
    static func resolve(mode raw: String?, isDebug: Bool, baseURL rawURL: String?) -> AccountConfiguration {
        switch raw.flatMap(AccountMode.init(rawValue:)) ?? .off {
        case .off:
            return AccountConfiguration(mode: .off, apiBaseURL: nil)
        case .preview:
            return AccountConfiguration(mode: isDebug ? .preview : .off, apiBaseURL: nil)
        case .live:
            guard let url = rawURL.flatMap(URL.init(string:)), url.scheme == "https", url.host?.isEmpty == false else {
                logger.error("UncloudAccountMode is live but UncloudAPIBaseURL isn't an https URL. Accounts are off.")
                return AccountConfiguration(mode: .off, apiBaseURL: nil)
            }
            return AccountConfiguration(mode: .live, apiBaseURL: url)
        }
    }
}
