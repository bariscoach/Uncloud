import Foundation

/// The plan's price, in one place. Copy says "$9.99/year" before tax; Checkout adds tax. Change the price here only.
enum PlanCopy {
    static let price = "$9.99"
    /// The price for the Welcome page and the paywall, e.g. "$9.99/year".
    static let yearlyPrice = "\(price)/year"
    /// The paywall's and locked panes' price, with tax: "$9.99/year + tax" (Stripe Tax adds it at checkout).
    static let yearlyPricePlusTax = "\(yearlyPrice) + tax"
    /// The one-year option's price, with tax: "$9.99 + tax".
    static let onePricePlusTax = "\(price) + tax"
    /// The Welcome page's one quiet line about what is free and what costs money.
    static let welcomePlanLine = "Export is free. Everything else is Uncloud Plus, \(yearlyPrice)."
}

/// The signed-in Uncloud account. The email is shown in Settings; the id is the server's.
struct UncloudAccount: Codable, Equatable, Sendable {
    let id: String
    let email: String
}

/// Sign Up and Sign In share the same two steps. The intent only changes the wording of the email.
enum AuthIntent: String, Equatable, Sendable {
    case signUp, signIn
}

/// What `requestCode` returns: the challenge to verify against.
struct AuthChallenge: Equatable, Hashable, Sendable {
    let id: String
    let email: String
    let expiresAt: Date
    let resendAfter: Date
}

/// The result of a successful verify: the account, its tokens, its plan, and whether the account was just created.
struct AuthSession: Equatable, Sendable {
    let account: UncloudAccount
    let tokens: AccountTokens
    let entitlement: Entitlement
    let isNewAccount: Bool
}

/// The two ways to buy Plus. Both are one yearly subscription; `oneYear` ends it at the period end (plan §1).
/// The raw values are the API's `renewal` strings.
enum Renewal: String, Equatable, Sendable {
    case automatic
    case oneYear
}

struct AccountTokens: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let accessExpiresAt: Date
}

enum Plan: String, Codable, Equatable, Sendable {
    case free, plus
}

/// The plan as the server last reported it. Cached on disk with `checkedAt`.
/// `signature` is the server's Ed25519 signature over the entitlement (plan §4.5); nil for preview and `free`.
struct Entitlement: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case none, active, trialing, pastDue, canceled, expired
    }

    let plan: Plan
    let status: Status
    /// End of the paid period: the renewal date while active, the end date once canceled.
    let currentPeriodEnd: Date?
    let cancelAtPeriodEnd: Bool
    let checkedAt: Date
    var signature: String? = nil

    static let free = Entitlement(plan: .free, status: .none, currentPeriodEnd: nil, cancelAtPeriodEnd: false, checkedAt: .distantPast)
}

/// The features behind Uncloud Plus. Export, its folders and history, and the backup folder are free and aren't listed.
enum PaidFeature: String, CaseIterable, Identifiable, Sendable {
    case automaticBackups, newPhotos, browseBackup, findDuplicates, verifyBackup, freeUpSpace, cleanUpICloud

    var id: Self { self }

    var title: String {
        switch self {
        case .automaticBackups: "Automatic Backups"
        case .newPhotos: "New Photos"
        case .browseBackup: "Browse Backup"
        case .findDuplicates: "Find Duplicates"
        case .verifyBackup: "Verify Backup"
        case .freeUpSpace: "Free Up Space"
        case .cleanUpICloud: "Clean Up iCloud"
        }
    }

    var symbol: String {
        switch self {
        case .automaticBackups: "clock.arrow.circlepath"
        case .newPhotos: "bell.badge"
        case .browseBackup: "map"
        case .findDuplicates: "doc.on.doc"
        case .verifyBackup: "checkmark.shield"
        case .freeUpSpace: "externaldrive.badge.minus"
        case .cleanUpICloud: "icloud"
        }
    }

    /// The name used on the paywall. New Photos is paid for its reminders only; its count stays free (owner decision 2).
    var paywallTitle: String {
        self == .newPhotos ? "Reminders" : title
    }

    /// One line, as on the Welcome page and the paywall.
    var summary: String {
        switch self {
        case .automaticBackups: "Exports new photos on its own when your drive connects, or once a day."
        case .newPhotos: "Lets you know when new photos are waiting to be backed up."
        case .browseBackup: "Look through your backup by date or on a map, no iCloud needed."
        case .findDuplicates: "Finds photos saved more than once, so you can tidy up."
        case .verifyBackup: "Checks that every file in your backup is intact."
        case .freeUpSpace: "Removes backed-up photos from this Mac to make room."
        case .cleanUpICloud: "Deletes backed-up photos from iCloud, and recovers them if you change your mind."
        }
    }
}

enum AccountError: Error, Equatable, Sendable {
    case invalidEmail
    case wrongCode
    case codeExpired
    case tooManyAttempts
    case rateLimited(retryAfter: Date?)
    case offline
    case server(message: String?)
    case signedOut
    case checkoutUnavailable
    case alreadySubscribed
    case noSubscription

    /// The sentence shown next to the field or in a banner (plan F.7).
    var message: String {
        switch self {
        case .invalidEmail: "Enter a valid email address."
        case .wrongCode: "That code isn’t right. Check it and try again."
        case .codeExpired: "That code has expired. Send a new one."
        case .tooManyAttempts: "Too many tries. Send a new code and try again."
        case .rateLimited: "Too many codes requested. Try again in a few minutes."
        case .offline: "Can’t reach Uncloud. Check your internet connection and try again."
        case .server: "Something went wrong on our side. Try again in a moment."
        case .signedOut: "You’ve been signed out. Sign in again to keep using Uncloud Plus."
        case .checkoutUnavailable: "Checkout isn’t available right now. Try again later."
        case .alreadySubscribed: "You already have Uncloud Plus."
        case .noSubscription: "There’s no plan to change. Get Uncloud Plus to start one."
        }
    }
}
