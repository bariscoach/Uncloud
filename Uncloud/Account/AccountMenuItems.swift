import Foundation

/// What a menu item does. The menus map each to the same action as the popover.
enum AccountMenuAction: Equatable {
    case accountSettings, getPlus, manageSubscription, updatePaymentMethod, checkAgain, signOut
}

struct AccountMenuItem: Equatable, Identifiable {
    let title: String
    let action: AccountMenuAction
    let isEnabled: Bool

    /// The titles are unique within the menu, so the title identifies the item.
    var id: String { title }
}

/// The menu bar extra's two lines for a problem: a disabled sentence and one button.
struct AccountMenuLine: Equatable {
    let text: String
    let buttonTitle: String
    let action: AccountMenuAction
}

/// The account items for the app menu and the menu bar extra, as pure data (account-menu plan §1.3 and §1.4).
enum AccountMenuItems {
    /// Uncloud ▸ items after Settings…. Empty unless there is a signed-in account.
    static func appMenu(summary: AccountSummary, isExporting: Bool) -> [AccountMenuItem] {
        guard summary.hasAccount else { return [] }
        let plan: AccountMenuItem
        switch summary.state {
        case .pastDue:
            plan = AccountMenuItem(title: "Update Payment Method…", action: .updatePaymentMethod, isEnabled: true)
        case .plusRenewing, .plusEnding, .offlineGrace:
            plan = AccountMenuItem(title: "Manage Subscription…", action: .manageSubscription, isEnabled: true)
        default:
            plan = AccountMenuItem(title: "Get Uncloud Plus…", action: .getPlus, isEnabled: true)
        }
        return [
            AccountMenuItem(title: "Account Settings…", action: .accountSettings, isEnabled: true),
            plan,
            AccountMenuItem(title: "Sign Out of Uncloud…", action: .signOut, isEnabled: !isExporting),
        ]
    }

    /// The menu bar extra's problem line, only for a failed payment or a plan that couldn't be checked.
    static func menuBarLine(summary: AccountSummary) -> AccountMenuLine? {
        switch summary.state {
        case .pastDue:
            AccountMenuLine(
                text: "Uncloud Plus: your last payment didn’t go through",
                buttonTitle: "Update Payment Method…",
                action: .updatePaymentMethod
            )
        case .offlineGrace:
            AccountMenuLine(text: "Uncloud Plus: couldn’t check your plan", buttonTitle: "Check Again", action: .checkAgain)
        default:
            nil
        }
    }
}
