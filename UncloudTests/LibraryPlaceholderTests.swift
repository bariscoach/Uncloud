import AppKit
import Foundation
import Testing
@testable import Uncloud

/// A browser backend whose live pages arrive after `liveDelay`, with an optional catalog count and pages that show
/// first (R12f).
@MainActor
private final class PlaceholderBackend: LibraryBrowserBackend {
    let liveCount: Int
    let placeholderTotal: Int?
    let liveDelay: Duration

    init(liveCount: Int, placeholderCount: Int?, liveDelay: Duration) {
        self.liveCount = liveCount
        self.placeholderTotal = placeholderCount
        self.liveDelay = liveDelay
    }

    func loadCount() async throws -> Int {
        liveCount
    }

    func loadPage(_ index: Int, pageSize: Int) async throws -> [Uncloud.LibraryItem] {
        try await Task.sleep(for: liveDelay)
        let start = index * pageSize
        return (start..<min(liveCount, start + pageSize)).map { number in
            Uncloud.LibraryItem(id: "live-\(number)", filename: "LIVE_\(number).JPG", created: nil, isVideo: false)
        }
    }

    func thumbnail(for item: Uncloud.LibraryItem, pixelSize: CGSize) async -> NSImage? {
        nil
    }

    func rankHints(for ids: Set<String>) async -> [String: Int] {
        [:]
    }

    func knownBytes() async -> [String: Int64] {
        [:]
    }

    func reset() async {}

    func placeholderCount() async -> Int? {
        placeholderTotal
    }

    func placeholderPage(_ index: Int, pageSize: Int) async -> [Uncloud.LibraryItem]? {
        guard let total = placeholderTotal else { return nil }
        let start = index * pageSize
        return (start..<min(total, start + pageSize)).map { number in
            Uncloud.LibraryItem(id: "old-\(number)", filename: "OLD_\(number).JPG", created: nil, isVideo: false)
        }
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
@Suite("Library placeholders from the catalog (R12f)")
struct LibraryPlaceholderTests {
    @Test func aPlaceholderShowsBeforeTheLivePageArrivesAndThenGivesWay() async throws {
        let backend = PlaceholderBackend(liveCount: 5, placeholderCount: 5, liveDelay: .milliseconds(400))
        let browser = LibraryBrowser(source: .iCloud, backend: backend)
        browser.load()
        try await waitUntil { browser.count != nil }
        #expect(browser.count == 5)

        try await waitUntil { browser.item(at: 0)?.isPlaceholder == true }
        #expect(browser.item(at: 0)?.id == "old-0")
        // A placeholder can't be selected until its live page arrives.
        #expect(browser.selectableItem(at: 0) == nil)

        try await waitUntil { browser.item(at: 0)?.isPlaceholder == false }
        #expect(browser.item(at: 0)?.id == "live-0")
        #expect(browser.selectableItem(at: 0)?.id == "live-0")
    }

    @Test func aLiveCountThatDiffersFromTheCatalogWins() async throws {
        let backend = PlaceholderBackend(liveCount: 5, placeholderCount: 7, liveDelay: .zero)
        let browser = LibraryBrowser(source: .iCloud, backend: backend)
        browser.load()
        try await waitUntil { browser.count == 5 }
        #expect(browser.count == 5)
    }

    @Test func withoutACatalogTheBrowserWaitsForTheLiveCount() async throws {
        let backend = PlaceholderBackend(liveCount: 3, placeholderCount: nil, liveDelay: .zero)
        let browser = LibraryBrowser(source: .iCloud, backend: backend)
        browser.load()
        try await waitUntil { browser.count != nil }
        try await waitUntil { browser.item(at: 0) != nil }
        #expect(browser.item(at: 0)?.id == "live-0")
        #expect(browser.item(at: 0)?.isPlaceholder == false)
    }
}
