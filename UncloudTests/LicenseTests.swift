import Foundation
import Testing
@testable import Uncloud

@Suite("License")
struct LicenseTests {
    @Test("Keys match the API stub, including a grandfathered Plus key")
    func parseKeys() {
        let plus = LicenseKey.parse("  UC1.plus.1.g.EXISTING1\n")
        #expect(plus == ParsedLicense(key: "UC1.plus.1.g.EXISTING1", tier: .plus, seats: 1, grandfathered: true))
        #expect(LicenseKey.parse("UC1.pro.2.s.abcd1234")?.tier == .pro)
        #expect(LicenseKey.parse("UC1.family.5.s.FamilyKey1")?.seats == 5)
        for key in [
            "", "plus", "UC1.plus.1.s.short", "UC1.plus.2.s.abcd1234", "UC1.pro.1.s.abcd1234",
            "UC1.family.5.g.abcd1234", "UC1.pro.02.s.abcd1234", "UC1.free.1.s.abcd1234",
        ] {
            #expect(LicenseKey.parse(key) == nil)
        }
    }

    @Test("Limits are off unless enforcement is on")
    func gatingDefaultsOff() {
        #expect(LicenseGating.isEnforced() == false)
        for feature in LicenseFeature.allCases {
            #expect(LicensePolicy.allows(feature, tier: .free, enforced: false))
        }
        #expect(!LicensePolicy.allows(.automaticBackups, tier: .free, enforced: true))
        #expect(LicensePolicy.allows(.automaticBackups, tier: .plus, enforced: true))
        #expect(!LicensePolicy.allows(.verifiedICloudCleanup, tier: .plus, enforced: true))
        #expect(LicensePolicy.allows(.verifiedICloudCleanup, tier: .pro, enforced: true))
        #expect(LicensePolicy.allows(.secondDestination, tier: .family, enforced: true))
        #expect(LicensePolicy.allows(.emailSupport, tier: .family, enforced: true))
        #expect(LicensePolicy.allows(.verifyBackup, tier: .pro, enforced: true))
    }

    @Test("Free keeps By Month and date browse; Plus unlocks the rest")
    func layoutsAndBrowse() {
        #expect(LicensePolicy.layoutAvailable(.month, source: .iCloud, tier: .free, enforced: true))
        #expect(!LicensePolicy.layoutAvailable(.album, source: .iCloud, tier: .free, enforced: true))
        #expect(LicensePolicy.layoutAvailable(.album, source: .iCloud, tier: .plus, enforced: true))
        #expect(LicensePolicy.layoutAvailable(.place, source: .photosLibrary, tier: .plus, enforced: true))
        #expect(!LicensePolicy.layoutAvailable(.place, source: .iCloud, tier: .family, enforced: true))
        #expect(LicensePolicy.layoutAvailable(.place, source: .photosLibrary, tier: .free, enforced: false))
        #expect(LicensePolicy.allowsBrowse(.dates, tier: .free, enforced: true))
        #expect(!LicensePolicy.allowsBrowse(.map, tier: .free, enforced: true))
        #expect(!LicensePolicy.allowsBrowse(.places, tier: .free, enforced: true))
        #expect(LicensePolicy.allowsBrowse(.map, tier: .plus, enforced: true))
    }

    @Test("A full library over the cap needs Plus, and a date range does not")
    func exportCap() {
        #expect(LicensePolicy.exportRefusal(
            selection: .everything, itemCount: 1000, isDateRange: false, tier: .free, enforced: true
        ) == nil)
        #expect(LicensePolicy.exportRefusal(
            selection: .everything, itemCount: 1001, isDateRange: false, tier: .free, enforced: true
        ) == LicensePolicy.freeExportRefusal)
        #expect(LicensePolicy.exportRefusal(
            selection: .everything, itemCount: nil, isDateRange: false, tier: .free, enforced: true
        ) == LicensePolicy.freeExportRefusal)
        #expect(LicensePolicy.exportRefusal(
            selection: .only(["a"]), itemCount: 5000, isDateRange: true, tier: .free, enforced: true
        ) == nil)
        #expect(LicensePolicy.exportRefusal(
            selection: .only(["a", "b"]), itemCount: 2, isDateRange: false, tier: .free, enforced: true
        ) == nil)
        #expect(LicensePolicy.exportRefusal(
            selection: .everything, itemCount: 50_000, isDateRange: false, tier: .plus, enforced: true
        ) == nil)
        #expect(LicensePolicy.exportRefusal(
            selection: .everything, itemCount: 50_000, isDateRange: false, tier: .free, enforced: false
        ) == nil)
    }

    @Test("A license is saved on this Mac and can be removed")
    func storeRoundTrip() throws {
        let name = "license-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = LicenseStore(defaults: defaults)
        #expect(store.load() == nil)
        #expect(store.tier == .free)
        let license = StoredLicense(key: "UC1.pro.2.s.abcd1234", tier: .pro, seats: 2, grandfathered: false, confirmedOnline: true)
        store.save(license)
        #expect(store.load() == license)
        #expect(store.tier == .pro)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test("The server’s answer is kept, and a network failure still saves a well-formed key")
    func activation() {
        let parsed = LicenseKey.parse("UC1.plus.1.s.abcd1234")!
        let accepted = LicenseActivation.decide(
            parsed: parsed,
            remote: .success(LicenseVerification(valid: true, tier: .plus, seats: 1, grandfathered: false))
        )
        guard case .saved(let saved) = accepted else {
            Issue.record("expected a saved license")
            return
        }
        #expect(saved.confirmedOnline)
        #expect(saved.tier == .plus)

        let offline = LicenseActivation.decide(parsed: parsed, remote: .failure(.unavailable))
        guard case .saved(let local) = offline else {
            Issue.record("expected an offline save")
            return
        }
        #expect(!local.confirmedOnline)

        let rejected = LicenseActivation.decide(parsed: parsed, remote: .failure(.invalid))
        #expect(rejected == .rejected(LicenseActivation.invalid))

        let mismatch = LicenseActivation.decide(
            parsed: parsed,
            remote: .success(LicenseVerification(valid: true, tier: .pro, seats: 2, grandfathered: false))
        )
        #expect(mismatch == .rejected(LicenseActivation.invalid))
    }

    @Test("The verify response decodes without an account")
    func decodeVerification() throws {
        let data = Data(#"{"valid":true,"mode":"stub","tier":"family","seats":5,"grandfathered":false,"accountRequired":false}"#.utf8)
        let decoded = LicenseVerifier.decode(data)
        #expect(decoded == .success(LicenseVerification(valid: true, tier: .family, seats: 5, grandfathered: false)))
        let invalid = LicenseVerifier.decode(Data(#"{"valid":false,"reason":"unrecognized_key"}"#.utf8))
        #expect(invalid == .failure(.invalid))
    }

    @Test("Checkout links must be https, and an empty value is a placeholder")
    func checkoutURLs() {
        #expect(LicenseCheckout.url(from: nil) == nil)
        #expect(LicenseCheckout.url(from: "  ") == nil)
        #expect(LicenseCheckout.url(from: "http://buy.example/plus") == nil)
        #expect(LicenseCheckout.url(from: "https://buy.example/plus") == URL(string: "https://buy.example/plus"))
        #expect(LicenseCheckout.url(for: .free) == nil)
    }

    @Test("The public site link matches the marketing site")
    func website() {
        #expect(LicenseLinks.website == URL(string: "https://www.tryuncloud.com"))
        #expect(AccountLinks.website == LicenseLinks.website)
        #expect(LicenseLinks.pricing == URL(string: "https://www.tryuncloud.com/pricing"))
    }
}
