import Foundation

/// The public links the paywall and Settings show. Derived from the API base URL, so the server owns the pages.
enum AccountLinks {
    /// Used when no live server is configured (preview and off builds).
    static let fallback = URL(string: "https://github.com/bariscoach/Uncloud#readme")!

    static func terms(_ configuration: AccountConfiguration) -> URL {
        configuration.apiBaseURL?.appendingPathComponent("terms") ?? fallback
    }

    static func privacy(_ configuration: AccountConfiguration) -> URL {
        configuration.apiBaseURL?.appendingPathComponent("privacy") ?? fallback
    }
}
