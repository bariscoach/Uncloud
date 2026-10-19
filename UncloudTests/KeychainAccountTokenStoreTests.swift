import Foundation
import Testing
@testable import Uncloud

/// Uses its own Keychain service name per test, so it never touches the app's real items.
@Suite("KeychainAccountTokenStore")
struct KeychainAccountTokenStoreTests {
    static func store() -> KeychainAccountTokenStore {
        KeychainAccountTokenStore(service: "com.example.UncloudTests.keychain-\(UUID().uuidString)")
    }

    @Test("Tokens round trip, a second save replaces the first, and clear removes them")
    func roundTrip() throws {
        let store = Self.store()
        defer { store.clear() }
        #expect(store.load() == nil)

        let first = AccountTokens(accessToken: "a1", refreshToken: "r1", accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save(first)
        #expect(store.load() == first)

        let second = AccountTokens(accessToken: "a2", refreshToken: "r2", accessExpiresAt: Date(timeIntervalSince1970: 1_800_003_600))
        try store.save(second)
        #expect(store.load() == second)

        store.clear()
        #expect(store.load() == nil)
    }
}
