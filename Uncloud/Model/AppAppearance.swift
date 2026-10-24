import AppKit

/// The app's appearance: follow the system, or always light or dark. Saved in UserDefaults under `storageKey`.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The appearance to set on `NSApp`. Nil follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The choice for a stored raw value. A missing or unknown value is `system`.
    static func stored(_ raw: String?) -> AppAppearance {
        raw.flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    /// Sets the stored choice on the whole app. Every window, sheet, the Settings window and the menu bar extra follow it.
    @MainActor
    static func applyStored() {
        let next = stored(UserDefaults.standard.string(forKey: storageKey)).nsAppearance
        // Setting the same appearance again would redraw every window, and defaults change for many reasons.
        guard NSApp.appearance?.name != next?.name else { return }
        NSApp.appearance = next
    }
}
