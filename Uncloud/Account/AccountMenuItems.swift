import Foundation

/// What a menu item does. The menus map each to the same action as the popover.
enum AccountMenuAction: Equatable {
    case accountSettings, signOut
}

struct AccountMenuItem: Equatable, Identifiable {
    let title: String
    let action: AccountMenuAction
    let isEnabled: Bool

    /// The titles are unique within the menu, so the title identifies the item.
    var id: String { title }
}

/// The account items for the app menu, as pure data (account-menu plan §1.3).
enum AccountMenuItems {
    /// Uncloud ▸ items after Settings…. Empty unless there is a signed-in account.
    static func appMenu(summary: AccountSummary, isExporting: Bool) -> [AccountMenuItem] {
        guard summary.hasAccount else { return [] }
        return [
            AccountMenuItem(title: "Account Settings…", action: .accountSettings, isEnabled: true),
            AccountMenuItem(title: "Sign Out of Uncloud…", action: .signOut, isEnabled: !isExporting),
        ]
    }
}
