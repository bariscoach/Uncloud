import AppKit
import Testing
@testable import Uncloud

/// The appearance setting: its titles, the NSAppearance each choice sets, and the stored default.
@Suite("AppAppearance")
struct AppAppearanceTests {
    @Test func mapsEachChoiceToAnAppearance() {
        #expect(AppAppearance.system.nsAppearance == nil)
        #expect(AppAppearance.light.nsAppearance?.name == .aqua)
        #expect(AppAppearance.dark.nsAppearance?.name == .darkAqua)
    }

    @Test func titlesAreTheMenuLabels() {
        #expect(AppAppearance.allCases == [.system, .light, .dark])
        #expect(AppAppearance.system.title == "Match System")
        #expect(AppAppearance.light.title == "Light")
        #expect(AppAppearance.dark.title == "Dark")
    }

    @Test func storageKeyAndRawValues() {
        #expect(AppAppearance.storageKey == "appearance")
        #expect(AppAppearance.system.rawValue == "system")
        #expect(AppAppearance.light.rawValue == "light")
        #expect(AppAppearance.dark.rawValue == "dark")
    }

    @Test func defaultIsSystem() {
        #expect(AppAppearance.stored(nil) == .system)
    }

    @Test func unknownStoredValueFallsBackToSystem() {
        #expect(AppAppearance.stored("purple") == .system)
        #expect(AppAppearance.stored("") == .system)
        #expect(AppAppearance.stored("dark") == .dark)
    }
}
