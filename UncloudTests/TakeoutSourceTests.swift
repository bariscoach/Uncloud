import Foundation
import Testing
@testable import Uncloud

@Suite("Takeout source")
struct TakeoutSourceTests {
    /// 2019-07-15 12:00 UTC.
    private static let takenSeconds = 1_563_192_000

    private func sidecar(title: String, taken: Int? = takenSeconds) -> String {
        var fields = ["\"title\": \"\(title)\""]
        if let taken {
            fields.append("\"photoTakenTime\": {\"timestamp\": \"\(taken)\"}")
        }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    private func member(_ path: String, _ text: String) -> ZipTestArchive.Member {
        ZipTestArchive.member(path: path, payload: Data(text.utf8))
    }

    @discardableResult
    private func writeZip(_ members: [ZipTestArchive.Member], named name: String, in folder: URL) throws -> URL {
        let url = folder.appending(path: name)
        try ZipTestArchive.archive(members).write(to: url)
        return url
    }

    private func item(_ result: TakeoutSource.Result, named name: String) throws -> TakeoutItem {
        try #require(result.items.first { $0.name == name })
    }

    @Test func takeoutFolderFindsPhotosWithTheirSidecars() throws {
        try withTemporaryDirectory { root in
            let takeout = root.appending(path: "Takeout", directoryHint: .isDirectory)
            try writeFile("photo", to: "Takeout/Google Photos/Photos from 2019/IMG_1.jpg", in: root)
            try writeFile(sidecar(title: "IMG_1.jpg"), to: "Takeout/Google Photos/Photos from 2019/IMG_1.jpg.json", in: root)
            try writeFile("<html></html>", to: "Takeout/archive_browser.html", in: root)
            try writeFile("{}", to: "Takeout/Google Photos/print-subscriptions.json", in: root)

            let result = try TakeoutSource.scan([takeout])

            #expect(result.unreadable.isEmpty)
            #expect(result.items.count == 1)
            let photo = try item(result, named: "IMG_1.jpg")
            #expect(photo.folder == "Photos from 2019")
            #expect(photo.album == nil)
            #expect(photo.size == 5)
            #expect(photo.metadata?.takenDate == Date(timeIntervalSince1970: TimeInterval(Self.takenSeconds)))
            #expect(photo.sourceKey == "Takeout|Google Photos/Photos from 2019/IMG_1.jpg|5")
            if case .file = photo.origin {} else { Issue.record("a folder item should read from its file") }
        }
    }

    @Test func albumFolderWithMetadataIsAnAlbumAndYearFoldersAreNot() throws {
        try withTemporaryDirectory { root in
            let photos = root.appending(path: "Google Photos", directoryHint: .isDirectory)
            try writeFile("{\"title\": \"Rome 2024\"}", to: "Google Photos/Rome 2024/metadata.json", in: root)
            try writeFile("album photo", to: "Google Photos/Rome 2024/IMG_3.jpg", in: root)
            try writeFile(sidecar(title: "IMG_3.jpg"), to: "Google Photos/Rome 2024/IMG_3.jpg.json", in: root)
            try writeFile("{\"title\": \"Photos from 2019\"}", to: "Google Photos/Photos from 2019/metadata.json", in: root)
            try writeFile("year photo", to: "Google Photos/Photos from 2019/IMG_4.jpg", in: root)

            let result = try TakeoutSource.scan([photos])

            #expect(try item(result, named: "IMG_3.jpg").album == "Rome 2024")
            #expect(try item(result, named: "IMG_3.jpg").folder == "Rome 2024")
            #expect(try item(result, named: "IMG_4.jpg").album == nil)
        }
    }

    @Test func zipInputReadsEntriesAndSidecarsFromTheArchive() throws {
        try withTemporaryDirectory { root in
            let zip = try writeZip([
                ZipTestArchive.member(path: "Takeout/Google Photos/Photos from 2019/", payload: Data()),
                member("Takeout/Google Photos/Photos from 2019/IMG_1.jpg", "photo"),
                member("Takeout/Google Photos/Photos from 2019/IMG_1.jpg.json", sidecar(title: "IMG_1.jpg")),
                member("__MACOSX/Takeout/Google Photos/Photos from 2019/._IMG_1.jpg", "junk"),
            ], named: "takeout-001.zip", in: root)

            let result = try TakeoutSource.scan([zip])

            #expect(result.unreadable.isEmpty)
            #expect(result.items.count == 1)
            let photo = try item(result, named: "IMG_1.jpg")
            guard case let .zip(archive, entry) = photo.origin else {
                Issue.record("a zip item should read from its archive")
                return
            }
            #expect(archive == zip)
            #expect(entry.path == "Takeout/Google Photos/Photos from 2019/IMG_1.jpg")
            #expect(photo.size == 5)
            #expect(photo.folder == "Photos from 2019")
            #expect(photo.metadata?.takenDate == Date(timeIntervalSince1970: TimeInterval(Self.takenSeconds)))
            #expect(photo.sourceKey == "takeout-001.zip|Takeout/Google Photos/Photos from 2019/IMG_1.jpg|5")
        }
    }

    @Test func folderContainingZipsReadsEachZipAsAnInput() throws {
        try withTemporaryDirectory { root in
            try writeZip([member("Takeout/Google Photos/Photos from 2019/IMG_1.jpg", "one")], named: "takeout-001.zip", in: root)
            try writeZip([member("Takeout/Google Photos/Photos from 2019/IMG_2.jpg", "two")], named: "takeout-002.zip", in: root)

            let result = try TakeoutSource.scan([root])

            #expect(result.items.map(\.name).sorted() == ["IMG_1.jpg", "IMG_2.jpg"])
        }
    }

    @Test func sidecarInAnotherZipPartIsStillMatched() throws {
        try withTemporaryDirectory { root in
            let photoPart = try writeZip([
                member("Takeout/Google Photos/Rome/IMG_5.jpg", "photo"),
            ], named: "takeout-001.zip", in: root)
            let sidecarPart = try writeZip([
                member("Takeout/Google Photos/Rome/IMG_5.jpg.json", sidecar(title: "IMG_5.jpg")),
            ], named: "takeout-002.zip", in: root)

            let result = try TakeoutSource.scan([sidecarPart, photoPart])

            #expect(result.items.count == 1)
            #expect(try item(result, named: "IMG_5.jpg").metadata?.takenDate != nil)
        }
    }

    @Test func truncatedSidecarLeavesTheFileWithoutMetadata() throws {
        try withTemporaryDirectory { root in
            try writeFile("photo", to: "Takeout/Google Photos/Photos from 2019/IMG_6.jpg", in: root)
            try writeFile("{\"title\": \"IMG_6.jpg\", \"photoTaken", to: "Takeout/Google Photos/Photos from 2019/IMG_6.jpg.json", in: root)

            let result = try TakeoutSource.scan([root.appending(path: "Takeout", directoryHint: .isDirectory)])

            #expect(result.items.count == 1)
            #expect(try item(result, named: "IMG_6.jpg").metadata == nil)
        }
    }

    @Test func titleMatchesASidecarWithAnotherName() throws {
        try withTemporaryDirectory { root in
            try writeFile("photo", to: "Takeout/Google Photos/Photos from 2019/IMG_9.jpg", in: root)
            try writeFile(sidecar(title: "IMG_9.jpg"), to: "Takeout/Google Photos/Photos from 2019/Trip_renamed.json", in: root)

            let result = try TakeoutSource.scan([root.appending(path: "Takeout", directoryHint: .isDirectory)])

            #expect(try item(result, named: "IMG_9.jpg").metadata?.title == "IMG_9.jpg")
        }
    }

    @Test func livePhotoMovieUsesThePhotosSidecar() throws {
        try withTemporaryDirectory { root in
            try writeFile("still", to: "Takeout/Google Photos/Photos from 2019/IMG_7.HEIC", in: root)
            try writeFile("movie", to: "Takeout/Google Photos/Photos from 2019/IMG_7.MP4", in: root)
            try writeFile(sidecar(title: "IMG_7.HEIC"), to: "Takeout/Google Photos/Photos from 2019/IMG_7.HEIC.json", in: root)

            let result = try TakeoutSource.scan([root.appending(path: "Takeout", directoryHint: .isDirectory)])

            #expect(result.items.count == 2)
            #expect(try item(result, named: "IMG_7.HEIC").metadata != nil)
            #expect(try item(result, named: "IMG_7.MP4").metadata != nil)
        }
    }

    @Test func onlyMediaFilesAreItems() throws {
        try withTemporaryDirectory { root in
            try writeFile("photo", to: "Takeout/Google Photos/Photos from 2019/IMG_8.jpg", in: root)
            try writeFile("xmp", to: "Takeout/Google Photos/Photos from 2019/IMG_8.xmp", in: root)
            try writeFile("notes", to: "Takeout/Google Photos/Photos from 2019/notes.txt", in: root)
            try writeFile("hidden", to: "Takeout/Google Photos/Photos from 2019/.hidden.jpg", in: root)

            let result = try TakeoutSource.scan([root.appending(path: "Takeout", directoryHint: .isDirectory)])

            #expect(result.items.map(\.name) == ["IMG_8.jpg"])
        }
    }

    @Test func unreadableInputsAreReportedAndSkipped() throws {
        try withTemporaryDirectory { root in
            try writeFile("this is text, not a zip archive, and it is long enough to be scanned for an end record.", to: "broken.zip", in: root)

            let result = try TakeoutSource.scan([root.appending(path: "missing", directoryHint: .isDirectory), root.appending(path: "broken.zip")])

            #expect(result.items.isEmpty)
            #expect(result.unreadable == ["missing", "broken.zip"])
        }
    }

    @Test func everyPhotoInALargeFolderGetsItsSidecar() throws {
        try withTemporaryDirectory { root in
            let count = 1500
            for index in 0..<count {
                let name = String(format: "IMG_%05d.jpg", index)
                try writeFile("photo", to: "Takeout/Google Photos/Photos from 2019/\(name)", in: root)
                // Takeout's newer form: the sidecar is `<name>.supplemental-metadata.json`.
                let sidecarName = name + ".supplemental-metadata.json"
                try writeFile(sidecar(title: name), to: "Takeout/Google Photos/Photos from 2019/\(sidecarName)", in: root)
            }

            let result = try TakeoutSource.scan([root.appending(path: "Takeout", directoryHint: .isDirectory)])

            #expect(result.items.count == count)
            #expect(result.items.allSatisfy { $0.metadata?.title == $0.name })
        }
    }

    @Test func albumNameFollowsTheAlbumRules() {
        #expect(TakeoutSource.albumName(folder: "Rome 2024", hasAlbumMetadata: true) == "Rome 2024")
        #expect(TakeoutSource.albumName(folder: "Trips/Rome", hasAlbumMetadata: true) == "Rome")
        #expect(TakeoutSource.albumName(folder: "Photos from 2019", hasAlbumMetadata: true) == nil)
        #expect(TakeoutSource.albumName(folder: "Rome 2024", hasAlbumMetadata: false) == nil)
        #expect(TakeoutSource.albumName(folder: "", hasAlbumMetadata: true) == nil)
    }

    @Test func yearFolderNamesAreRecognized() {
        #expect(TakeoutSource.isPhotosFromYear("Photos from 2019"))
        #expect(!TakeoutSource.isPhotosFromYear("Photos from 20190"))
        #expect(!TakeoutSource.isPhotosFromYear("Photos from abcd"))
        #expect(!TakeoutSource.isPhotosFromYear("Rome 2024"))
    }

    @Test func folderKeyIsTheSameWhicheverFolderWasChosen() {
        #expect(TakeoutSource.folderKey(for: ["Takeout", "Google Photos", "Rome"]) == "Rome")
        #expect(TakeoutSource.folderKey(for: ["Google Photos", "Rome"]) == "Rome")
        #expect(TakeoutSource.folderKey(for: ["Google Photos"]) == "")
        #expect(TakeoutSource.folderKey(for: ["Rome"]) == "Rome")
        #expect(TakeoutSource.folderKey(for: ["Takeout"]) == "Takeout")
    }
}
