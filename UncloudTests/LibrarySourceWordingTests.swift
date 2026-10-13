import Testing
@testable import Uncloud

@Suite("Copied-item wording")
struct LibrarySourceWordingTests {
    /// iCloud items are downloaded; Photos library items are exported. Every drive-facing message uses this.
    @Test func iCloudItemsAreDownloadedAndPhotosItemsExported() {
        #expect(LibrarySource.iCloud.copiedVerb == "downloaded")
        #expect(LibrarySource.photosLibrary.copiedVerb == "exported")
    }
}
