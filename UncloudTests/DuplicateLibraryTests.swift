import Foundation
import Testing
@testable import Uncloud

/// The duplicates library merges the same-folder groups and the extra copies into one photo each, with the original
/// first. These tests fabricate the scan's results, so they read no files.
@Suite("Find Duplicates library")
struct DuplicateLibraryTests {
    private func copy(_ id: String, _ path: String, bytes: Int64, order: Int = 0) -> DuplicateFinder.Copy {
        DuplicateFinder.Copy(
            id: id, paths: [path], mediaPaths: [path], checksums: [path: "sum"],
            byteCount: bytes, exportOrder: order
        )
    }

    private func group(_ id: String, _ copies: [DuplicateFinder.Copy]) -> DuplicateFinder.Group {
        DuplicateFinder.Group(id: id, copies: copies, keeperID: copies[0].id)
    }

    private func extra(_ recordID: String, folder: String, _ path: String, keeper: String, bytes: Int64) -> DuplicateFinder.ExtraCopy {
        DuplicateFinder.ExtraCopy(
            recordID: recordID, folder: folder, paths: [path], mediaPaths: [path], checksums: [path: "sum"],
            keeperPaths: [keeper], keeperChecksums: [keeper: "sum"], byteCount: bytes
        )
    }

    /// Two photos from the same-folder groups (one with three copies), and one from the extra copies with two folders.
    private var sample: DuplicateLibrary {
        DuplicateLibrary(
            groups: [
                group("2024/07|a", [
                    copy("icloud-id:A1", "2024/07/IMG_0101.HEIC", bytes: 300),
                    copy("icloud-id:A2", "2024/07/IMG_0101 copy.HEIC", bytes: 300),
                    copy("icloud-id:A3", "2024/07/IMG_0101-2483921.JPG", bytes: 300),
                ]),
                group("2024/07|b", [
                    copy("icloud-id:B1", "2024/07/IMG_0102.MOV", bytes: 800),
                    copy("icloud-id:B2", "2024/07/IMG_0102 (1).MOV", bytes: 800),
                ]),
            ],
            extraCopies: [
                extra("icloud-id:D", folder: "", "IMG_0300.HEIC", keeper: "2026/10/IMG_0300.HEIC", bytes: 50),
                extra("icloud-id:D", folder: "2026/09", "2026/09/IMG_0300.HEIC", keeper: "2026/10/IMG_0300.HEIC", bytes: 50),
            ]
        )
    }

    @Test func photosFromBothKindsOfDuplicateAreOneEachLargestFirst() {
        let library = sample
        #expect(library.photos.map(\.id) == ["2024/07|b", "2024/07|a", "icloud-id:D"])
    }

    @Test func theOriginalIsTheKeeperAndTheCopiesFollow() {
        let photo = sample.photos[1]
        #expect(photo.original.path == "2024/07/IMG_0101.HEIC")
        #expect(photo.copies.map(\.path) == ["2024/07/IMG_0101 copy.HEIC", "2024/07/IMG_0101-2483921.JPG"])
        #expect(photo.copyBytes == 600)
    }

    @Test func anExtraCopyPhotoHasTheLayoutCopyAsItsOriginal() {
        let photo = sample.photos[2]
        #expect(photo.original.path == "2026/10/IMG_0300.HEIC")
        #expect(photo.original.folder == "2026/10")
        #expect(photo.copies.map(\.folder) == ["", "2026/09"])
        #expect(photo.copyBytes == 100)
    }

    @Test func aVideoIsMarkedAndAStillIsNot() {
        let photos = sample.photos
        #expect(photos[0].copies.map(\.isVideo) == [true])
        #expect(photos[0].original.isVideo)
        #expect(!photos[1].original.isVideo)
    }

    @Test func theLibraryTotalsCountTheCopiesAndTheirBytes() {
        let totals = sample.totals()
        #expect(totals == DuplicateLibrary.Totals(photos: 3, copies: 5, bytes: 1_500))
    }

    @Test func anExcludedPhotoKeepsAllItsCopiesAndIsLeftOutOfTheTotals() {
        let totals = sample.totals(excluding: ["2024/07|b"])
        #expect(totals == DuplicateLibrary.Totals(photos: 2, copies: 4, bytes: 700))
    }

    @Test func excludingEveryPhotoLeavesNothingToRemove() {
        let totals = sample.totals(excluding: Set(sample.photos.map(\.id)))
        #expect(totals == DuplicateLibrary.Totals())
    }
}

@Suite("Find Duplicates wording")
struct DuplicateWordingTests {
    @Test func theConfirmationTitleIsSingularForOneCopy() {
        #expect(DuplicateWording.confirmationTitle(copies: 1) == "Remove 1 Duplicate?")
        #expect(DuplicateWording.confirmationTitle(copies: 2_854) == "Remove 2,854 Duplicates?")
    }

    @Test func theConfirmationMessageNamesTheVolumeAndTheSizeInBothForms() {
        let one = DuplicateWording.confirmationMessage(copies: 1, bytes: 1_000_000, volume: "Backup")
        #expect(one.contains("moves the other copy (1 MB) to the Trash on “Backup”."))
        #expect(one.hasPrefix("Uncloud keeps the original of each photo, the first copy it saved, and moves"))

        let many = DuplicateWording.confirmationMessage(copies: 2_854, bytes: 66_000_000_000, volume: "Backup")
        #expect(many.contains("moves the other 2,854 copies (66 GB) to the Trash on “Backup”."))
    }

    @Test func theFinishedTitleIsSingularForOneDuplicate() {
        #expect(DuplicateWording.finishedTitle(.init(removedCopies: 1)) == "Removed 1 duplicate")
        #expect(DuplicateWording.finishedTitle(.init(removedCopies: 2_850)) == "Removed 2,850 duplicates")
        #expect(DuplicateWording.finishedTitle(.init()) == "No duplicates were removed")
    }

    @Test func theFinishedDetailsSayWhatIsFreedAndWhatWasLeftAlone() {
        let clean = DuplicateWording.finishedDetails(.init(removedCopies: 2, removedBytes: 66_000_000_000))
        #expect(clean == ["66 GB will be freed when you empty the Trash."])

        let skipped = DuplicateWording.finishedDetails(.init(
            removedCopies: 2_850, removedBytes: 66_000_000_000, skippedCopies: 4, failedCopies: 1
        ))
        #expect(skipped == [
            "66 GB will be freed when you empty the Trash.",
            "4 skipped because they didn’t match their original.",
            "1 couldn’t be moved to the Trash.",
        ])
    }
}
