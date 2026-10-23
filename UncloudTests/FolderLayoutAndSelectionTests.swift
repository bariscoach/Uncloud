import Foundation
import Testing
@testable import Uncloud

@Suite("FolderLayout")
struct FolderLayoutTests {
    @Test func iCloudOffersMonthAlbumAndOneFolder() {
        #expect(FolderLayout.allCases.filter { $0.isAvailable(for: .iCloud) } == [.month, .album, .flat])
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

@Suite("FolderLayout flat")
struct FolderLayoutFlatTests {
    @Test func flatIsTitledAndExampledAsInThePlan() {
        #expect(FolderLayout.flat.title == "All in One Folder")
        #expect(FolderLayout.flat.example == "IMG_0001.HEIC")
        #expect(FolderLayout.flat.rawValue == "flat")
        #expect(FolderLayout(rawValue: "flat") == .flat)
        #expect(FolderLayout.allCases.last == .flat)
    }

    @Test func flatIsAvailableForPhotosLibrary() {
        #expect(FolderLayout.flat.isAvailable(for: .photosLibrary))
    }

    @Test func flatIsAvailableForICloud() {
        // Plan D3: the iCloud engine records only the files it reports in one folder.
        #expect(FolderLayout.flat.isAvailable(for: .iCloud))
    }

    @Test func flatUsesNoFolderStructureInIcloudpd() {
        #expect(FolderLayout.flat.icloudpdFolderStructure == "none")
        #expect(FolderLayout.month.icloudpdFolderStructure == "{:%Y/%m}")
    }

    @Test func flatHasNoPlacesOrAlbums() {
        #expect(!FolderLayout.flat.usesPlaces)
        #expect(!FolderLayout.flat.usesAlbums)
    }

    @Test func flatCaptionHasNoClashRule() {
        // The clash rule moved to File Names (FolderLayout.clashRule(for:)); see FolderOrganizationTests.
        #expect(FolderLayout.flat.caption(for: .iCloud) == "Everything goes straight into your backup folder, with no subfolders.")
        #expect(FolderLayout.flat.caption(for: .photosLibrary) == FolderLayout.flat.caption(for: .iCloud))
        #expect(FolderLayout.month.caption(for: .iCloud) == nil)
    }
}

@Suite("PhotoKit flat export")
struct PhotoKitFlatExportTests {
    @Test func flatFolderIsEmptyAndTheDestinationItself() {
        #expect(ExportEngine.folderPath(for: .flat, monthKey: "2024-07", place: nil) == "")
        let destination = URL(filePath: "/Volumes/Photos Archive", directoryHint: .isDirectory)
        #expect(ExportEngine.folderURL(in: destination, folderPath: "") == destination)
        #expect(ExportEngine.folderURL(in: destination, folderPath: "2024/07").path(percentEncoded: false) .hasPrefix("/Volumes/Photos Archive/2024/07"))
    }

    @Test func relativePathHasNoLeadingSlashWhenFlat() {
        #expect(ExportEngine.relativePath(in: "", filename: "IMG_0001.HEIC") == "IMG_0001.HEIC")
        #expect(ExportEngine.relativePath(in: "2024/07", filename: "IMG_0001.HEIC") == "2024/07/IMG_0001.HEIC")
        #expect(ExportEngine.relativePath(in: "Italy/Rome/2024-07", filename: "a.mov") == "Italy/Rome/2024-07/a.mov")
    }

    @Test func monthAndPlaceFoldersAreUnchanged() {
        #expect(ExportEngine.folderPath(for: .month, monthKey: "2024-07", place: nil) == "2024/07")
        #expect(ExportEngine.folderPath(for: .month, monthKey: nil, place: nil) == "Undated")
        #expect(ExportEngine.folderPath(for: .place, monthKey: "2024-07", place: "Rome") == "Rome")
        #expect(ExportEngine.folderPath(for: .placeThenMonth, monthKey: "2024-07", place: "Italy/Rome") == "Italy/Rome/2024-07")
        #expect(ExportEngine.folderPath(for: .placeThenMonth, monthKey: nil, place: "Italy/Rome") == "Italy/Rome/Undated")
    }

    @Test func collidingNamesGetDistinctFilesInTheRoot() throws {
        try withTemporaryDirectory { destination in
            var names: [String] = []
            for _ in 0..<3 {
                let url = FileManager.default.availableURL(in: destination, for: "IMG_0001.HEIC")
                try Data("photo".utf8).write(to: url)
                names.append(url.lastPathComponent)
            }
            #expect(names == ["IMG_0001.HEIC", "IMG_0001 (1).HEIC", "IMG_0001 (2).HEIC"])
            #expect(Set(names).count == names.count)
            #expect(names.allSatisfy { !$0.hasPrefix("/") })
        }
    }

    /// The manifest and checksum records of two flat items, the second one a name collision, with a sidecar.
    @Test func flatManifestRecordsHaveRootPathsAndWork() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            let digest = { (letter: String) in String(repeating: letter, count: 64) }

            var checksums: [String: String] = [:]
            var recordedFiles: [String] = []
            for (id, name, hash) in [("asset-1", "IMG_0001.HEIC", "a"), ("asset-2", "IMG_0001.HEIC", "b")] {
                let url = FileManager.default.availableURL(in: destination, for: name)
                try Data(hash.utf8).write(to: url)
                let path = ExportEngine.relativePath(in: "", filename: url.lastPathComponent)
                checksums[path] = digest(hash)
                try manifest.recordExport(of: id, files: [path])
                recordedFiles.append(path)
            }
            let sidecar = ExportEngine.relativePath(in: "", filename: "IMG_0001 (1).xmp")
            checksums[sidecar] = digest("c")
            try manifest.recordChecksums(checksums)
            try manifest.recordLayout(.flat)

            #expect(recordedFiles == ["IMG_0001.HEIC", "IMG_0001 (1).HEIC"])
            #expect(ExportManifest.records(in: destination) == [
                "asset-1": ["IMG_0001.HEIC"],
                "asset-2": ["IMG_0001 (1).HEIC"],
            ])
            #expect(ExportManifest.exportedIDs(in: destination) == ["asset-1", "asset-2"])
            #expect(ExportManifest.checksums(in: destination) == [
                "IMG_0001.HEIC": digest("a"),
                "IMG_0001 (1).HEIC": digest("b"),
                "IMG_0001 (1).xmp": digest("c"),
            ])
            #expect(ExportManifest.layout(in: destination) == .flat)
            #expect(ExportManifest.records(in: destination).values.flatMap { $0 }.allSatisfy { !$0.hasPrefix("/") })
        }
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
