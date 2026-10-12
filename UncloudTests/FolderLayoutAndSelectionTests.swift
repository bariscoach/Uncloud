import Foundation
import Testing
@testable import Uncloud

@Suite("FolderLayout")
struct FolderLayoutTests {
    @Test func iCloudOffersOnlyMonthAndAlbum() {
        #expect(FolderLayout.allCases.filter { $0.isAvailable(for: .iCloud) } == [.month, .album])
    }

    @Test func photosLibraryOffersEveryLayout() {
        #expect(FolderLayout.allCases.allSatisfy { $0.isAvailable(for: .photosLibrary) })
    }

    @Test func placeLayoutsNeedPlaces() {
        #expect(FolderLayout.place.usesPlaces)
        #expect(FolderLayout.placeThenMonth.usesPlaces)
        #expect(!FolderLayout.month.usesPlaces)
        #expect(FolderLayout.album.usesAlbums)
        #expect(!FolderLayout.place.usesAlbums)
    }
}

@Suite("LibrarySelection")
struct LibrarySelectionTests {
    @Test func everythingContainsAnyID() {
        let selection = LibrarySelection.everything
        #expect(selection.isEverything)
        #expect(!selection.isNothing)
        #expect(selection.contains("anything"))
        #expect(selection.selectedCount(total: 10) == 10)
    }

    @Test func allExceptExcludesItsIDs() {
        let selection = LibrarySelection.allExcept(["a"])
        #expect(!selection.contains("a"))
        #expect(selection.contains("b"))
        #expect(!selection.isEverything)
        #expect(selection.selectedCount(total: 5) == 4)
    }

    @Test func onlyIncludesItsIDs() {
        let selection = LibrarySelection.only(["a", "b"])
        #expect(selection.contains("a"))
        #expect(!selection.contains("c"))
        #expect(selection.selectedCount(total: 10) == 2)
        #expect(selection.selectedCount(total: 1) == 1)
    }

    @Test func nothingIsOnlyWithNoIDs() {
        #expect(LibrarySelection.only([]).isNothing)
        #expect(LibrarySelection.only([]).selectedCount(total: 10) == 0)
        #expect(!LibrarySelection.allExcept([]).isNothing)
    }

    @Test func selectAndDeselectInAllExceptMode() {
        var selection = LibrarySelection.everything
        selection.deselect(["a", "b"])
        #expect(selection == .allExcept(["a", "b"]))
        selection.select(["a"])
        #expect(selection == .allExcept(["b"]))
        selection.toggle("b")
        #expect(selection == .everything)
        selection.toggle("c")
        #expect(selection == .allExcept(["c"]))
    }

    @Test func selectAndDeselectInOnlyMode() {
        var selection = LibrarySelection.only([])
        selection.select(["a", "b"])
        #expect(selection == .only(["a", "b"]))
        selection.deselect(["a"])
        #expect(selection == .only(["b"]))
        selection.toggle("b")
        #expect(selection.isNothing)
        selection.toggle("c")
        #expect(selection == .only(["c"]))
    }

    @Test func selectAllAndDeselectAll() {
        var selection = LibrarySelection.only(["a"])
        selection.selectAll()
        #expect(selection == .everything)
        selection.deselectAll()
        #expect(selection == .only([]))
        #expect(selection.isNothing)
    }

    @Test func persistenceRoundTripForBothModes() throws {
        try withTemporaryDirectory { folder in
            let store = LibrarySelectionStore(directory: folder)
            try store.save(.allExcept(["x", "y"]), source: .photosLibrary, account: nil)
            #expect(store.load(source: .photosLibrary, account: nil) == .allExcept(["x", "y"]))

            try store.save(.only(["p"]), source: .iCloud, account: "someone@example.com")
            #expect(store.load(source: .iCloud, account: "someone@example.com") == .only(["p"]))
            // Another account gets its own file.
            #expect(store.load(source: .iCloud, account: "other@example.com") == .everything)
            // Account matching ignores case and surrounding spaces.
            #expect(store.load(source: .iCloud, account: " Someone@Example.com ") == .only(["p"]))
        }
    }

    @Test func savingEverythingRemovesTheFile() throws {
        try withTemporaryDirectory { folder in
            let store = LibrarySelectionStore(directory: folder)
            try store.save(.only(["a"]), source: .photosLibrary, account: nil)
            #expect(FileManager.default.fileExists(atPath: store.fileURL(source: .photosLibrary, account: nil).path(percentEncoded: false)))
            try store.save(.everything, source: .photosLibrary, account: nil)
            #expect(!FileManager.default.fileExists(atPath: store.fileURL(source: .photosLibrary, account: nil).path(percentEncoded: false)))
            #expect(store.load(source: .photosLibrary, account: nil) == .everything)
        }
    }

    @Test func corruptFileLoadsAsEverything() throws {
        try withTemporaryDirectory { folder in
            let store = LibrarySelectionStore(directory: folder)
            try writeFile("{ not json", to: store.fileURL(source: .photosLibrary, account: nil).lastPathComponent, in: folder)
            #expect(store.load(source: .photosLibrary, account: nil) == .everything)
        }
    }

    @Test func unknownModeIsRejected() throws {
        let data = Data(#"{"mode":"sometimes","ids":[]}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LibrarySelection.self, from: data)
        }
    }
}
