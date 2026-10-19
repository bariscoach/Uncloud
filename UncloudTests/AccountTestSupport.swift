import Foundation
@testable import Uncloud

/// A clock the tests move by hand. Sendable, so the preview service can read it.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    /// A `@Sendable` closure for the services and models.
    var reader: @Sendable () -> Date {
        { [self] in now }
    }
}

/// A UserDefaults suite no other test shares, so every test starts with no accounts and no tokens.
func isolatedDefaults() -> UserDefaults {
    let suite = "com.example.UncloudTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

extension AccountModel {
    /// A model for views that read it without testing accounts. `off` by default, so no lock and no Account section show,
    /// and the snapshots match the app before accounts existed.
    @MainActor static func forTesting(mode: AccountMode = .off) -> AccountModel {
        let defaults = isolatedDefaults()
        return AccountModel(
            mode: mode,
            service: PreviewAccountService(store: PreviewAccountStore(defaults: defaults)),
            tokens: DefaultsAccountTokenStore(defaults: defaults),
            defaults: defaults
        )
    }
}
