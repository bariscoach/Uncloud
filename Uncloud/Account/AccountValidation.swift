import Foundation

/// Email rules the app checks before sending a code. Deliberately simple: the server is the real check.
enum EmailAddress {
    static let maxLength = 254

    /// The trimmed, lowercased address, or nil unless it has one `@`, a local part, and a domain with a 2+ letter TLD.
    static func normalized(_ raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.count <= maxLength, !email.contains(where: \.isWhitespace) else { return nil }

        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }

        let domain = parts[1]
        guard !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.hasPrefix("-"), !domain.hasSuffix("-") else { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }

        guard let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return email
    }
}

/// The 6-digit code from the email.
enum OneTimeCode {
    static let length = 6

    /// The first six ASCII digits of `raw`, so pasting "123 456" or "Your code is 123456" gives "123456".
    static func sanitized(_ raw: String) -> String {
        String(raw.filter { $0.isASCII && $0.isNumber }.prefix(length))
    }

    static func isComplete(_ code: String) -> Bool {
        code.count == length && code.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
