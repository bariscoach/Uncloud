import Foundation
import Testing
@testable import Uncloud

/// Which account items the app menu and the menu bar extra show (account-menu plan §1.3, §1.4, §7.1).
@Suite("AccountMenu")
struct AccountMenuTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 24 * 60 * 60

    static func summary(_ entitlement: Entitlement, phase: AccountModel.Phase = .signedIn, mode: AccountMode = .preview) -> AccountSummary {
        AccountSummary.make(
            mode: mode, phase: phase,
            account: UncloudAccount(id: "u", email: "name@example.com"),
            entitlement: entitlement,
            access: EntitlementPolicy.access(entitlement, now: now),
            lastError: nil, now: now
        )
    }

    static func plus(_ status: Entitlement.Status, anchor: TimeInterval, cancel: Bool = false, checked: Date = now) -> Entitlement {
        Entitlement(plan: .plus, status: status, currentPeriodEnd: now.addingTimeInterval(anchor), cancelAtPeriodEnd: cancel, checkedAt: checked)
    }

    static func titles(_ items: [AccountMenuItem]) -> [String] {
        items.map(\.title)
    }

    @Test("Free shows Account Settings, Get Uncloud Plus and Sign Out, in that order")
    func freeItems() {
        let items = AccountMenuItems.appMenu(summary: Self.summary(.free), isExporting: false)
        #expect(Self.titles(items) == ["Account Settings…", "Get Uncloud Plus…", "Sign Out of Uncloud…"])
        #expect(items.map(\.action) == [.accountSettings, .getPlus, .signOut])
    }

    @Test("Plus shows Manage Subscription, and so does grace")
    func plusItems() {
        let renewing = AccountMenuItems.appMenu(summary: Self.summary(Self.plus(.active, anchor: 30 * Self.day)), isExporting: false)
        #expect(renewing.map(\.title)[1] == "Manage Subscription…")

        let grace = AccountMenuItems.appMenu(summary: Self.summary(Self.plus(.active, anchor: -Self.day)), isExporting: false)
        #expect(grace.map(\.title)[1] == "Manage Subscription…")
    }

    @Test("Past due shows Update Payment Method")
    func pastDueItems() {
        let items = AccountMenuItems.appMenu(summary: Self.summary(Self.plus(.pastDue, anchor: -Self.day)), isExporting: false)
        #expect(items.map(\.title)[1] == "Update Payment Method…")
        #expect(items.map(\.action)[1] == .updatePaymentMethod)
    }

    @Test("Sign Out is disabled while an export runs, and the other items stay enabled")
    func signOutDisabledWhileExporting() {
        let items = AccountMenuItems.appMenu(summary: Self.summary(.free), isExporting: true)
        #expect(items.first { $0.action == .signOut }?.isEnabled == false)
        #expect(items.first { $0.action == .accountSettings }?.isEnabled == true)
    }

    @Test("Off, signed out and loading have no account items")
    func noItemsWithoutAnAccount() {
        #expect(AccountMenuItems.appMenu(summary: Self.summary(.free, mode: .off), isExporting: false).isEmpty)
        #expect(AccountMenuItems.appMenu(summary: Self.summary(.free, phase: .signedOut(.welcome)), isExporting: false).isEmpty)
        #expect(AccountMenuItems.appMenu(summary: Self.summary(.free, phase: .restoring), isExporting: false).isEmpty)
    }

    @Test("The menu bar gets a line only for past due and offline grace")
    func menuBarLines() {
        let pastDue = AccountMenuItems.menuBarLine(summary: Self.summary(Self.plus(.pastDue, anchor: -Self.day)))
        #expect(pastDue == AccountMenuLine(
            text: "Uncloud Plus: your last payment didn’t go through",
            buttonTitle: "Update Payment Method…",
            action: .updatePaymentMethod
        ))

        let grace = AccountMenuItems.menuBarLine(summary: Self.summary(Self.plus(.active, anchor: -Self.day)))
        #expect(grace == AccountMenuLine(text: "Uncloud Plus: couldn’t check your plan", buttonTitle: "Check Again", action: .checkAgain))

        #expect(AccountMenuItems.menuBarLine(summary: Self.summary(.free)) == nil)
        #expect(AccountMenuItems.menuBarLine(summary: Self.summary(Self.plus(.active, anchor: 30 * Self.day))) == nil)
        #expect(AccountMenuItems.menuBarLine(summary: Self.summary(.free, mode: .off)) == nil)
        #expect(AccountMenuItems.menuBarLine(summary: Self.summary(.free, phase: .signedOut(.welcome))) == nil)
    }
}
