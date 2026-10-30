import AppKit
import Foundation
import Testing
@testable import Uncloud

/// The bridge's preview fields, decoded from page replies, and the browser's forwarding of a preview to its backend.
/// No network: the replies are literal JSON lines.
@Suite("Library previews from the bridge")
struct LibraryPreviewBridgeTests {
    private func assets(_ line: String) throws -> [ICloudAsset] {
        let message = try JSONDecoder().decode(ICloudBridgeMessage.self, from: Data(line.utf8))
        return (message.items ?? []).map(\.asset)
    }

    @Test func aPageReplyWithPreviewsDecodesThem() throws {
        let decoded = try assets(#"""
        {"id":3,"event":"page","offset":0,"items":[{"id":"A","rank":0,"filename":"IMG_1.HEIC","created":null,"added":null,
        "type":"image","size":10,"bytes":10,"thumbURL":"https://example.invalid/t","previewURL":"https://example.invalid/p",
        "previewType":"heic","master":null,"lat":null,"lon":null,"tz":null}]}
        """#)
        #expect(decoded.count == 1)
        #expect(decoded[0].thumbnailURL == URL(string: "https://example.invalid/t"))
        #expect(decoded[0].previewURL == URL(string: "https://example.invalid/p"))
        #expect(decoded[0].previewExtension == "heic")
    }

    @Test func aReplyFromAnOlderBridgeWithoutPreviewsStillDecodes() throws {
        let decoded = try assets(#"""
        {"id":3,"event":"page","offset":0,"items":[{"id":"A","filename":"IMG_1.JPG","created":null,"added":null,
        "type":"image","size":null,"bytes":null,"thumbURL":null}]}
        """#)
        #expect(decoded.count == 1)
        #expect(decoded[0].id == "A")
        #expect(decoded[0].previewURL == nil)
        #expect(decoded[0].previewExtension == nil)
    }
}

/// A backend that answers previews with a fixed file (or none) and records the IDs it was asked about.
@MainActor
private final class PreviewBackend: LibraryBrowserBackend {
    let file: URL?
    private(set) var previewedIDs: [String] = []

    init(file: URL?) {
        self.file = file
    }

    func loadCount() async throws -> Int {
        0
    }

    func loadPage(_ index: Int, pageSize: Int) async throws -> [Uncloud.LibraryItem] {
        []
    }

    func thumbnail(for item: Uncloud.LibraryItem, pixelSize: CGSize) async -> NSImage? {
        nil
    }

    func previewFile(for item: Uncloud.LibraryItem) async -> URL? {
        previewedIDs.append(item.id)
        return file
    }

    func rankHints(for ids: Set<String>) async -> [String: Int] {
        [:]
    }

    func knownBytes() async -> [String: Int64] {
        [:]
    }

    func reset() async {}
}

@MainActor
@Suite("Library previews in the browser")
struct LibraryPreviewBrowserTests {
    @Test func theBrowserForwardsThePreviewFileOfTheItemToItsBackend() async {
        let file = FileManager.default.temporaryDirectory.appending(path: "preview-forwarded.jpg")
        let backend = PreviewBackend(file: file)
        let browser = LibraryBrowser(source: .iCloud, backend: backend)
        let item = Uncloud.LibraryItem(id: "asset-7", filename: "IMG_7.HEIC", created: nil, isVideo: false)
        #expect(await browser.previewFile(for: item) == file)
        #expect(backend.previewedIDs == ["asset-7"])
    }

    @Test func aBackendWithoutAPreviewGivesNil() async {
        let browser = LibraryBrowser(source: .iCloud, backend: PreviewBackend(file: nil))
        let item = Uncloud.LibraryItem(id: "asset-8", filename: "IMG_8.JPG", created: nil, isVideo: false)
        #expect(await browser.previewFile(for: item) == nil)
    }
}
