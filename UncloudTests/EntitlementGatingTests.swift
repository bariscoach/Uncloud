import Foundation
import Testing
@testable import Uncloud

/// The gates the app puts on paid features: what runs, what opens the paywall, and that `off` changes nothing.
@MainActor
@Suite("Entitlement gating")
struct EntitlementGatingTests {
    @Test("A free account's locked feature opens the paywall for that feature and runs nothing")
    func lockedFeatureOpensPaywall() async {
        let harness = AccountModelTests.makeHarness()
        await AccountModelTests.signIn(harness.model)
        var ran = false

        harness.model.require(.findDuplicates) { ran = true }

        #expect(ran == false)
        #expect(harness.model.paywall?.feature == .findDuplicates)
        #expect(harness.model.allows(.findDuplicates) == false)
    }

    @Test("A subscribed account runs the feature at once and no paywall opens")
    func subscribedFeatureRuns() async {
        let harness = AccountModelTests.makeHarness()
        await AccountModelTests.signIn(harness.model, email: "plus@example.com")
        var ran = false

        harness.model.require(.verifyBackup) { ran = true }

        #expect(ran)
        #expect(harness.model.paywall == nil)
    }

    @Test("Off accounts allow everything, so no lock or paywall ever shows")
    func offAllowsEverything() {
        let harness = AccountModelTests.makeHarness(mode: .off)
        var ran = false

        for feature in PaidFeature.allCases {
            #expect(harness.model.allows(feature))
        }
        harness.model.require(.browseBackup) { ran = true }

        #expect(ran)
        #expect(harness.model.paywall == nil)
        #expect(harness.model.showsAppMenus)
    }

    @Test("Continue after a successful checkout runs the action that opened the paywall")
    func continueRunsAction() async {
        let harness = AccountModelTests.makeHarness()
        await AccountModelTests.signIn(harness.model)
        var ran = 0
        harness.model.require(.freeUpSpace) { ran += 1 }

        await harness.model.openCheckout(for: .freeUpSpace, renewal: .automatic)
        await harness.model.refreshEntitlement(force: true)
        #expect(harness.model.checkout == .active)
        harness.model.finishPaywall()

        #expect(ran == 1)
        #expect(harness.model.paywall == nil)
        #expect(harness.model.allows(.freeUpSpace))
    }

    @Test("One year, no auto-renewal is the same subscription set not to renew")
    func oneYearEndsAtPeriodEnd() async {
        let harness = AccountModelTests.makeHarness()
        await AccountModelTests.signIn(harness.model)

        await harness.model.openCheckout(for: nil, renewal: .oneYear)
        await harness.model.refreshEntitlement(force: true)

        #expect(harness.model.entitlement.plan == .plus)
        #expect(harness.model.entitlement.cancelAtPeriodEnd)
        #expect(harness.model.entitlement.currentPeriodEnd != nil)
    }

    @Test("Turning renewal off keeps the plan until its end, and turning it back on renews it")
    func renewalToggleKeepsPlan() async {
        let harness = AccountModelTests.makeHarness()
        await AccountModelTests.signIn(harness.model, email: "plus@example.com")

        await harness.model.setAutoRenew(false)
        #expect(harness.model.entitlement.cancelAtPeriodEnd)
        #expect(harness.model.allows(.automaticBackups))

        await harness.model.setAutoRenew(true)
        #expect(harness.model.entitlement.cancelAtPeriodEnd == false)
    }

    @Test("Returning from the billing page looks at the plan again, once")
    func portalReturnRefreshes() async {
        let harness = AccountModelTests.makeHarness()
        await AccountModelTests.signIn(harness.model, email: "plus@example.com")
        await harness.model.openManageSubscription()
        #expect(harness.model.awaitingPortalReturn)

        harness.model.appDidBecomeActive()
        await harness.model.refreshTask?.value

        #expect(harness.model.awaitingPortalReturn == false)
    }

    @Test("Reminders are the paid part of New Photos, under the paywall's name")
    func newPhotosPaywallName() {
        #expect(PaidFeature.newPhotos.paywallTitle == "Reminders")
        #expect(PaidFeature.browseBackup.paywallTitle == "Browse Backup")
    }

    @Test("Prices read the same everywhere: with tax on the paywall and locked panes")
    func priceCopy() {
        #expect(PlanCopy.yearlyPricePlusTax == "$9.99/year + tax")
        #expect(PlanCopy.onePricePlusTax == "$9.99 + tax")
        #expect(PlanText.renewalTerms(.automatic).contains("$9.99/year + tax"))
        #expect(PlanText.renewalTerms(.oneYear).contains("$9.99 + tax"))
    }

    @Test("Deleting and recovering that start after the plan lapsed are both refused (L6)")
    func deleteAndRecoverRefusedAfterLapse() {
        #expect(CleanupGridView.mayStart(mode: .library, allowsCleanUp: false) == false)
        #expect(CleanupGridView.mayStart(mode: .recentlyDeleted, allowsCleanUp: false) == false)
        #expect(CleanupGridView.mayStart(mode: .library, allowsCleanUp: true))
        #expect(CleanupGridView.mayStart(mode: .recentlyDeleted, allowsCleanUp: true))
    }

    @Test("Only Clean Up iCloud has a locked note, and it says where recoverable photos stay")
    func cleanUpLockedNote() {
        let note = PaidFeature.cleanUpICloud.lockedNote ?? ""
        #expect(note.contains("30 days"))
        #expect(note.contains("iCloud.com"))
        for feature in PaidFeature.allCases where feature != .cleanUpICloud {
            #expect(feature.lockedNote == nil, "\(feature) has no locked note")
        }
    }

    @Test("Clean Up iCloud shows its grid when the plan allows it or a run is going, and the lock otherwise")
    func cleanupPaneGate() {
        #expect(MainWindow.showsCleanup(allowed: false, isRunning: false) == false)
        #expect(MainWindow.showsCleanup(allowed: false, isRunning: true))
        #expect(MainWindow.showsCleanup(allowed: true, isRunning: false))
        #expect(MainWindow.showsCleanup(allowed: true, isRunning: true))
    }

    @Test("A free account keeps the new-photos offer: its title and subtitle never read the account")
    func newPhotosOfferIsFree() async {
        let harness = AccountModelTests.makeHarness()
        await AccountModelTests.signIn(harness.model)
        #expect(harness.model.allows(.cleanUpICloud) == false)
        #expect(harness.model.allows(.newPhotos) == false)

        // The export title is computed from the backup alone, so it is the same with the account locked out.
        #expect(NewPhotosTitle.offersNewOnly(isPaused: false, hasInterruptedRun: false, needsFolder: false,
                                             isEverything: true, hasNewPhotosStatus: false, backedUpCount: 9_207))
        #expect(NewPhotosTitle.primary(isPaused: false, hasInterruptedRun: false, needsFolder: false, isEverything: true,
                                       hasNewPhotosStatus: false, backedUpCount: 9_207, notBackedUpCount: 1_243,
                                       fallback: "Export All Photos") == "Export 1,243 New Photos")
    }
}
