import Foundation

/// The `uncloud://` links the app handles: the return from Stripe Checkout and from the customer portal (plan D.2).
/// A link is only a hint to refresh the plan. The server decides whether anything was paid.
enum AccountURL: Equatable, Sendable {
    case checkoutSuccess(sessionID: String?)
    case checkoutCancel
    case refresh

    static let scheme = "uncloud"
    static let maxSessionIDLength = 255

    init?(_ url: URL) {
        // URLComponents keeps a trailing slash in the path, which URL.path drops; an extra slash must not match.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme, let host = components.host else { return nil }
        switch (host, components.path) {
        case ("checkout", "/success"):
            self = .checkoutSuccess(sessionID: Self.sessionID(in: components))
        case ("checkout", "/cancel"):
            self = .checkoutCancel
        case ("account", "/refresh"):
            self = .refresh
        default:
            return nil
        }
    }

    /// The `session_id` if it is 1 to 255 letters, digits or underscores; otherwise nil, and the link still counts.
    private static func sessionID(in components: URLComponents) -> String? {
        guard let value = components.queryItems?.first(where: { $0.name == "session_id" })?.value else {
            return nil
        }
        guard !value.isEmpty, value.count <= maxSessionIDLength,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            return nil
        }
        return value
    }
}
