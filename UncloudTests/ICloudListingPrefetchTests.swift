import Foundation
import Testing
@testable import Uncloud

/// R11 on the app side: the listing prefetch setting is off by default, and only a depth above 1 reaches the bridge.
@Suite struct ICloudListingPrefetchTests {
    private func defaults(_ value: Int?) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ICloudListingPrefetchTests-\(UUID().uuidString)")!
        if let value {
            defaults.set(value, forKey: ICloudListingPrefetch.defaultsKey)
        }
        return defaults
    }

    private func json(_ request: ICloudBridgeRequest) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    }

    @Test func offUnlessTheSettingAsksForMorePages() throws {
        #expect(ICloudListingPrefetch.requested(in: defaults(nil)) == nil)
        #expect(ICloudListingPrefetch.requested(in: defaults(1)) == nil)
        #expect(ICloudListingPrefetch.requested(in: defaults(2)) == 2)
        #expect(ICloudListingPrefetch.requested(in: defaults(9)) == ICloudListingPrefetch.maximum)
    }

    @Test func aStatsRequestCarriesThePrefetchOnlyWhenItIsOn() throws {
        let plain = try json(ICloudBridgeRequest(cmd: "stats", offset: 40))
        #expect(plain["prefetch"] == nil)
        #expect(plain["offset"] as? Int == 40)
        let ahead = try json(ICloudBridgeRequest(cmd: "stats", offset: 40, prefetch: 2))
        #expect(ahead["prefetch"] as? Int == 2)
    }
}
