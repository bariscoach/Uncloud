import Foundation

/// One page of the onboarding carousel.
struct OnboardingPage: Identifiable {
    let id: Int
    let symbol: String
    let title: String
    let message: String

    static let all = [
        OnboardingPage(
            id: 0,
            symbol: "photo.stack",
            title: "Your Whole Library",
            message: "Sign in to iCloud to copy every photo and video, with originals, Live Photos and RAW files, or export from the Photos library on this Mac."
        ),
        OnboardingPage(
            id: 1,
            symbol: "map",
            title: "Organized Your Way",
            message: "Sort everything into folders by month, by place, by place and then month, or by album."
        ),
        OnboardingPage(
            id: 2,
            symbol: "arrow.clockwise.circle",
            title: "Pick Up Where You Left Off",
            message: "Pause or quit at any time. Resume skips what’s already saved, so later exports copy only new items."
        ),
        OnboardingPage(
            id: 3,
            symbol: "lock.shield",
            title: "Private by Design",
            message: "Photos go straight from this Mac to your folder and are never uploaded. For place folders, only locations are sent to Apple to look up city names."
        ),
    ]
}
