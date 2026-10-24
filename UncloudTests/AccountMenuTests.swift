import Foundation
import Testing
@testable import Uncloud

/// Which account items the app menu shows (account-menu plan §1.3, §7.1).
@Suite("AccountMenu")
struct AccountMenuTests {
    static func summary(phase: AccountModel.Phase = .signedIn, mode: AccountMode = .preview) -> AccountSummary {
        AccountSummary.make(mode: mode, phase: phase, account: UncloudAccount(id: "u", email: "name@example.com"))
    }

    static func titles(_ items: [AccountMenuItem]) -> [String] {
        items.map(\.title)
    }

    @Test("Signed in shows Account Settings and Sign Out, in that order")
    func signedInItems() {
        let items = AccountMenuItems.appMenu(summary: Self.summary(), isExporting: false)
        #expect(Self.titles(items) == ["Account Settings…", "Sign Out of Uncloud…"])
        #expect(items.map(\.action) == [.accountSettings, .signOut])
    }

    @Test("Sign Out is disabled while an export runs, and Account Settings stays enabled")
    func signOutDisabledWhileExporting() {
        let items = AccountMenuItems.appMenu(summary: Self.summary(), isExporting: true)
        #expect(items.first { $0.action == .signOut }?.isEnabled == false)
        #expect(items.first { $0.action == .accountSettings }?.isEnabled == true)
    }

    @Test("Off, signed out and loading have no account items")
    func noItemsWithoutAnAccount() {
        #expect(AccountMenuItems.appMenu(summary: Self.summary(mode: .off), isExporting: false).isEmpty)
        #expect(AccountMenuItems.appMenu(summary: Self.summary(phase: .signedOut(.welcome)), isExporting: false).isEmpty)
        #expect(AccountMenuItems.appMenu(summary: Self.summary(phase: .restoring), isExporting: false).isEmpty)
    }
}
