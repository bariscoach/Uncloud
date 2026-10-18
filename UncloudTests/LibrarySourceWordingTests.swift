import Testing
@testable import Uncloud

@Suite("Copied-photo wording")
struct LibrarySourceWordingTests {
    /// Both sources say "exported": nothing in the UI says "downloaded". Every drive-facing message uses this.
    @Test func bothSourcesSayExported() {
        #expect(LibrarySource.iCloud.copiedVerb == "exported")
        #expect(LibrarySource.photosLibrary.copiedVerb == "exported")
    }
}
