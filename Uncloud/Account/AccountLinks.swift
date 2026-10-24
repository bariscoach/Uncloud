import Foundation

/// The public links Settings shows. Derived from the API base URL, so the server owns the pages.
enum AccountLinks {
    /// Support for email changes and account questions. The owner's address until a domain email exists.
    static let supportEmail = "barishiz@gmail.com"

    static var support: URL {
        URL(string: "mailto:\(supportEmail)") ?? fallback
    }

    /// The public website, for Help › Uncloud Website.
    static let website = URL(string: "https://getuncloud.vercel.app")!

    /// Used when no live server is configured (preview and off builds).
    static let fallback = URL(string: "https://github.com/bariscoach/Uncloud#readme")!

    static func terms(_ configuration: AccountConfiguration) -> URL {
        configuration.apiBaseURL?.appendingPathComponent("terms") ?? fallback
    }

    static func privacy(_ configuration: AccountConfiguration) -> URL {
        configuration.apiBaseURL?.appendingPathComponent("privacy") ?? fallback
    }
}
