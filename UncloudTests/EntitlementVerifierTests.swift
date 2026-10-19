import Foundation
import Testing
@testable import Uncloud

@Suite("EntitlementVerifier")
struct EntitlementVerifierTests {
    static let vector = EntitlementVector.load()
    static var verifier: EntitlementVerifier { EntitlementVerifier(base64PublicKey: vector.publicKey) }

    @Test("The shared vector verifies, and the message is the exact bytes the server signed")
    func sharedVector() {
        #expect(EntitlementVerifier.message(Self.vector.entitlement, accountID: Self.vector.accountId) == Self.vector.message)
        #expect(Self.verifier.isValid(Self.vector.entitlement, accountID: Self.vector.accountId))
    }

    @Test("Any change to a signed field, or to the account, fails verification")
    func tamperingFails() {
        let signed = Self.vector.entitlement
        let otherAccount = "8b1c2f3e-0000-4000-8000-000000000002"
        #expect(!Self.verifier.isValid(signed, accountID: otherAccount))

        let upgraded = Entitlement(plan: .plus, status: .pastDue, currentPeriodEnd: signed.currentPeriodEnd,
                               cancelAtPeriodEnd: signed.cancelAtPeriodEnd, checkedAt: signed.checkedAt, signature: signed.signature)
        #expect(!Self.verifier.isValid(upgraded, accountID: Self.vector.accountId))

        let later = Entitlement(plan: signed.plan, status: signed.status, currentPeriodEnd: signed.currentPeriodEnd,
                                cancelAtPeriodEnd: signed.cancelAtPeriodEnd, checkedAt: signed.checkedAt.addingTimeInterval(1),
                                signature: signed.signature)
        #expect(!Self.verifier.isValid(later, accountID: Self.vector.accountId))
    }

    @Test("Unsigned entitlements, and verifiers without a key, reject everything")
    func missingPieces() {
        var unsigned = Self.vector.entitlement
        unsigned.signature = nil
        #expect(!Self.verifier.isValid(unsigned, accountID: Self.vector.accountId))
        #expect(!EntitlementVerifier(base64PublicKey: nil).isValid(Self.vector.entitlement, accountID: Self.vector.accountId))
        #expect(!EntitlementVerifier(base64PublicKey: "not base64!").isValid(Self.vector.entitlement, accountID: Self.vector.accountId))
    }

    @Test("Dates on the wire are whole-second UTC, and parse with or without fractions")
    func wireDates() throws {
        let date = try #require(WireDate.parse("2026-10-18T09:41:07Z"))
        #expect(WireDate.format(date) == "2026-10-18T09:41:07Z")
        #expect(WireDate.parse("2026-10-18T09:41:07.250Z") == date.addingTimeInterval(0.25))
        #expect(WireDate.parse("yesterday") == nil)
    }
}
