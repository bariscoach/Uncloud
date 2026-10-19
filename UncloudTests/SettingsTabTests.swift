import Testing
@testable import Uncloud

/// The Settings window's tabs (account-menu plan §2.1). `off` keeps the single General form.
@Suite("SettingsTab")
struct SettingsTabTests {
    @Test("Off has no tabs, so it builds only the General form")
    func offHasNoTabs() {
        #expect(SettingsTab.showsTabs(for: .off) == false)
        #expect(SettingsTab.showsTabs(for: .preview))
        #expect(SettingsTab.showsTabs(for: .live))
    }

    @Test("The raw values round trip and are the stored strings")
    func rawValues() {
        #expect(SettingsTab.allCases == [.general, .account])
        for tab in SettingsTab.allCases {
            #expect(SettingsTab(rawValue: tab.rawValue) == tab)
        }
        #expect(SettingsTab.account.rawValue == "account")
        #expect(SettingsTab.storageKey == "uncloudSettingsTab")
        #expect(SettingsTab(rawValue: "unknown") == nil)
    }
}
