import Foundation
import Testing
@testable import Uncloud

@Suite("License")
struct LicenseTests {
    private static let signedPlus = "UC1.eyJpYXQiOjE3NjQwMDAwMDAsImp0aSI6ImNzX3Rlc3RfdmVjdG9yIiwic2VhdHMiOjEsInRpZXIiOiJwbHVzIiwidiI6MX0.G7-VNyTkGua4Q8s27S-GtBJ_ZsaDKrAh5WK11qN4iHanE6ZdNgJ-JJY_hgD7IrY1lgRQqXW5kzpJmELwDP5GCQ"

    @Test("Only a signed key activates, including offline")
    func signedKey() {
        let parsed = LicenseKey.parse(Self.signedPlus)
        #expect(parsed?.tier == .plus)
        #expect(parsed?.seats == 1)
        #expect(parsed?.jti == "cs_test_vector")
        #expect(LicenseKey.parse("UC1.plus.1.g.EXISTING1") == nil)
        #expect(LicenseKey.parse(Self.signedPlus + "x") == nil)
        let deepLink = LicenseDeepLink.key(from: URL(string: "uncloud://license?key=\(Self.signedPlus)")!)
        #expect(deepLink == Self.signedPlus)
        #expect(LicenseDeepLink.key(from: URL(string: "https://www.tryuncloud.com/license")!) == nil)
    }

    @Test("The free allowance is 1,000 items in every mode, then the paywall")
    func quota() {
        let open = ExportQuota.allowance(exportedCount: 0, unlimited: false, enforced: true)
        #expect(open.remaining == 1000)
        #expect(!open.blockStart)
        let last = ExportQuota.allowance(exportedCount: 999, unlimited: false, enforced: true)
        #expect(last.remaining == 1)
        let blocked = ExportQuota.allowance(exportedCount: 1000, unlimited: false, enforced: true)
        #expect(blocked.blockStart)
        #expect(blocked.showPaywall)
        #expect(blocked.remaining == 0)
        let over = ExportQuota.allowance(exportedCount: 5000, unlimited: false, enforced: true)
        #expect(over.blockStart)
        let licensed = ExportQuota.allowance(exportedCount: 5000, unlimited: true, enforced: true)
        #expect(licensed.remaining == nil)
        #expect(!licensed.blockStart)
        let off = ExportQuota.allowance(exportedCount: 5000, unlimited: false, enforced: false)
        #expect(off.remaining == nil)
        #expect(!off.showPaywall)
    }

    @Test("A signed key lifts the cap for 14 days without a revocation check")
    func grace() {
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        let recent = now.addingTimeInterval(-2 * 24 * 60 * 60)
        let stale = now.addingTimeInterval(-(15 * 24 * 60 * 60))
        #expect(LicensePolicy.unlimited(tier: .plus, activatedAt: recent, lastCheck: nil, now: now, enforced: true))
        #expect(!LicensePolicy.unlimited(tier: .plus, activatedAt: stale, lastCheck: nil, now: now, enforced: true))
        #expect(LicensePolicy.unlimited(tier: .plus, activatedAt: stale, lastCheck: recent, now: now, enforced: true))
        #expect(!LicensePolicy.unlimited(tier: .free, activatedAt: recent, lastCheck: recent, now: now, enforced: true))
        #expect(LicensePolicy.unlimited(tier: .free, activatedAt: nil, lastCheck: nil, now: now, enforced: false))
    }

    @Test("Limits other than the item cap stay behind the flag")
    func gatingDefaultsOff() {
        #expect(LicenseGating.isEnforced() == false)
        for feature in LicenseFeature.allCases {
            #expect(LicensePolicy.allows(feature, tier: .free, enforced: false))
        }
        #expect(LicensePolicy.allows(.automaticBackups, tier: .free, enforced: true))
        #expect(!LicensePolicy.allows(.mapPlaceBrowse, tier: .free, enforced: true))
        #expect(LicensePolicy.allows(.mapPlaceBrowse, tier: .plus, enforced: true))
        #expect(!LicensePolicy.allows(.verifiedICloudCleanup, tier: .plus, enforced: true))
        #expect(LicensePolicy.allows(.verifiedICloudCleanup, tier: .pro, enforced: true))
    }

    @Test("The export counter lives in the store the app is given")
    func counter() {
        let store = MemoryExportCountStore()
        #expect(store.load() == 0)
        store.add(40)
        store.add(960)
        #expect(store.load() == 1000)
        store.add(0)
        #expect(store.load() == 1000)
        let allowance = ExportQuota.allowance(exportedCount: store.load(), unlimited: false, enforced: true)
        #expect(allowance.blockStart)
    }

    @Test("An unavailable server still saves a signed key, and a revocation does not")
    func activation() {
        let parsed = LicenseKey.parse(Self.signedPlus)!
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        let offline = LicenseActivation.decide(parsed: parsed, remote: .failure(.unavailable), now: now)
        guard case .saved(let saved) = offline else {
            Issue.record("expected an offline save")
            return
        }
        #expect(!saved.confirmedOnline)
        #expect(saved.jti == "cs_test_vector")
        #expect(saved.lastRevocationCheck == nil)

        let revoked = LicenseActivation.decide(parsed: parsed, remote: .failure(.revoked), now: now)
        #expect(revoked == .rejected(LicenseActivation.revoked))

        let store = MemoryLicenseStore()
        if case .saved(let license) = offline {
            store.save(license)
            #expect(store.load()?.tier == .plus)
            store.clear()
            #expect(store.load() == nil)
        }
    }

    @Test("The verify response treats a revoked key as unusable")
    func decodeVerification() {
        let data = Data(#"{"valid":false,"reason":"revoked","accountRequired":false}"#.utf8)
        #expect(LicenseVerifier.decode(data) == .failure(.revoked))
        let ok = Data(#"{"valid":true,"tier":"family","seats":5}"#.utf8)
        #expect(LicenseVerifier.decode(ok) == .success(LicenseVerification(valid: true, tier: .family, seats: 5, reason: nil)))
    }
}
