import Foundation
import Testing
@testable import Uncloud

@Suite("AccountURL")
struct AccountURLTests {
    private static func parse(_ string: String) -> AccountURL? {
        URL(string: string).flatMap(AccountURL.init)
    }

    @Test("The links the app handles parse")
    func handledLinks() {
        #expect(Self.parse("uncloud://checkout/success?session_id=cs_test_123") == .checkoutSuccess(sessionID: "cs_test_123"))
        #expect(Self.parse("uncloud://checkout/success") == .checkoutSuccess(sessionID: nil))
        #expect(Self.parse("uncloud://checkout/cancel") == .checkoutCancel)
        #expect(Self.parse("uncloud://account/refresh") == .refresh)
    }

    @Test("The scheme is compared case-insensitively")
    func uppercaseScheme() {
        #expect(Self.parse("UNCLOUD://checkout/cancel") == .checkoutCancel)
    }

    @Test("Other schemes, hosts and extra paths are ignored", arguments: [
        "https://checkout/success",
        "other://account/refresh",
        "uncloud://billing/success",
        "uncloud://checkout/refresh",
        "uncloud://checkout/success/extra",
        "uncloud://account/refresh/",
        "uncloud:checkout",
    ])
    func ignoredLinks(string: String) {
        #expect(Self.parse(string) == nil)
    }

    @Test("A session_id that is too long or not alphanumeric is dropped, and the link still parses")
    func badSessionIDs() {
        let long = String(repeating: "a", count: 300)
        #expect(Self.parse("uncloud://checkout/success?session_id=\(long)") == .checkoutSuccess(sessionID: nil))
        #expect(Self.parse("uncloud://checkout/success?session_id=cs%20x") == .checkoutSuccess(sessionID: nil))
        #expect(Self.parse("uncloud://checkout/success?session_id=\(String(repeating: "a", count: 255))")
            == .checkoutSuccess(sessionID: String(repeating: "a", count: 255)))
    }
}
