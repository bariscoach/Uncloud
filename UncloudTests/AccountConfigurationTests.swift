import Foundation
import Testing
@testable import Uncloud

@Suite("AccountConfiguration")
struct AccountConfigurationTests {
    static func live(
        baseURL: String? = "https://uncloud-api.vercel.app",
        supabaseURL: String? = "https://nkcbuwuuatsbskqcqosc.supabase.co",
        publishableKey: String? = "sb_publishable_test",
        isDebug: Bool = false
    ) -> AccountConfiguration {
        AccountConfiguration.resolve(
            mode: "live",
            isDebug: isDebug,
            baseURL: baseURL,
            supabaseURL: supabaseURL,
            supabasePublishableKey: publishableKey
        )
    }

    @Test("Live with all three values is live, with the base URL constant")
    func liveComplete() {
        let config = Self.live()
        #expect(config.mode == .live)
        #expect(config.apiBaseURL == URL(string: "https://uncloud-api.vercel.app"))
        #expect(config.supabasePublishableKey == "sb_publishable_test")
    }

    @Test("Live with any value missing, empty, or not https is off, never a lockout")
    func liveIncomplete() {
        #expect(Self.live(baseURL: nil).mode == .off)
        #expect(Self.live(baseURL: "").mode == .off)
        #expect(Self.live(baseURL: "http://uncloud-api.vercel.app").mode == .off)
        #expect(Self.live(supabaseURL: nil).mode == .off)
        #expect(Self.live(publishableKey: "  ").mode == .off)
    }

    @Test("Preview is a Debug-only mode, and off in Release")
    func previewIsDebugOnly() {
        #expect(AccountConfiguration.resolve(mode: "preview", isDebug: true, baseURL: nil, supabaseURL: nil,
                                             supabasePublishableKey: nil).mode == .preview)
        #expect(AccountConfiguration.resolve(mode: "preview", isDebug: false, baseURL: nil, supabaseURL: nil,
                                             supabasePublishableKey: nil).mode == .off)
    }

    @Test("Off, missing and unknown modes are off, and carry no URLs or keys")
    func offCarriesNothing() {
        for mode in [nil, "off", "bogus"] {
            let config = AccountConfiguration.resolve(mode: mode, isDebug: true, baseURL: "https://uncloud-api.vercel.app",
                                                      supabaseURL: "https://x.supabase.co", supabasePublishableKey: "k")
            #expect(config.mode == .off)
            #expect(config.apiBaseURL == nil)
            #expect(config.supabaseURL == nil)
            #expect(config.supabasePublishableKey == nil)
        }
    }

    @Test("Terms and privacy come from the API base URL, or the README without a server")
    func links() {
        let config = Self.live()
        #expect(AccountLinks.terms(config) == URL(string: "https://uncloud-api.vercel.app/terms"))
        #expect(AccountLinks.privacy(config) == URL(string: "https://uncloud-api.vercel.app/privacy"))
        let preview = AccountConfiguration.resolve(mode: "preview", isDebug: true, baseURL: nil, supabaseURL: nil,
                                                   supabasePublishableKey: nil)
        #expect(AccountLinks.terms(preview) == AccountLinks.fallback)
    }
}
