import Foundation
import Testing
@testable import Uncloud

/// A made-up checksum for a file, so grouping tests don't need real files. Single digits only, so it's a valid 64-character hex string.
private func digest(_ number: Int) -> String {
    String(repeating: "0", count: 63) + String(number)
}

@Suite("Find Duplicates grouping")
struct DuplicateGroupingTests {
    private func find(
        _ records: [String: [String]],
        _ checksums: [String: String],
        sizes: [String: Int64] = [:],
        order: [String: Int] = [:]
    ) -> DuplicateFinder.Result {
        DuplicateFinder.findGroups(records: records, checksums: checksums, sizes: sizes, exportOrder: order)
    }

    @Test func identicalPhotosBecomeOneGroup() {
        let result = find(
            ["icloud-id:A": ["2024/07/IMG_0001.HEIC"], "icloud-id:B": ["2024/07/IMG_0002.HEIC"]],
            ["2024/07/IMG_0001.HEIC": digest(1), "2024/07/IMG_0002.HEIC": digest(1)]
        )
        #expect(result.groups.map { $0.copies.map(\.id) } == [["icloud-id:A", "icloud-id:B"]])
        #expect(result.notCheckedCount == 0)
    }

    @Test func photosLibraryItemsGroupToo() {
        let result = find(
            ["LOCAL-A": ["2024/07/IMG_0001.HEIC"], "LOCAL-B": ["2024/07/IMG_0002.HEIC"]],
            ["2024/07/IMG_0001.HEIC": digest(1), "2024/07/IMG_0002.HEIC": digest(1)]
        )
        #expect(result.groups.map { $0.copies.map(\.id) } == [["LOCAL-A", "LOCAL-B"]])
    }

    @Test func differentChecksumsDoNotGroup() {
        let result = find(
            ["icloud-id:A": ["2024/07/IMG_0001.HEIC"], "icloud-id:B": ["2024/07/IMG_0002.HEIC"]],
            ["2024/07/IMG_0001.HEIC": digest(1), "2024/07/IMG_0002.HEIC": digest(2)]
        )
        #expect(result.groups.isEmpty)
    }

    @Test func livePhotoOnlyMatchesALivePhotoWithTheSameMovie() {
        let result = find(
            [
                "icloud-id:A": ["2024/07/IMG_0001.HEIC", "2024/07/IMG_0001.MOV"],
                "icloud-id:B": ["2024/07/IMG_0002.HEIC", "2024/07/IMG_0002.MOV"],
                "icloud-id:C": ["2024/07/IMG_0003.HEIC"],
            ],
            [
                "2024/07/IMG_0001.HEIC": digest(1), "2024/07/IMG_0001.MOV": digest(2),
                "2024/07/IMG_0002.HEIC": digest(1), "2024/07/IMG_0002.MOV": digest(2),
                "2024/07/IMG_0003.HEIC": digest(1),
            ]
        )
        // The plain photo shares the still with the Live Photos, but it's a different item.
        #expect(result.groups.map { $0.copies.map(\.id) } == [["icloud-id:A", "icloud-id:B"]])
    }

    @Test func xmpSidecarsAreIgnoredForMatching() {
        let result = find(
            [
                "icloud-id:A": ["2024/07/IMG_0001.HEIC", "2024/07/IMG_0001.xmp"],
                "icloud-id:B": ["2024/07/IMG_0002.HEIC", "2024/07/IMG_0002.xmp"],
            ],
            [
                "2024/07/IMG_0001.HEIC": digest(1), "2024/07/IMG_0001.xmp": digest(2),
                "2024/07/IMG_0002.HEIC": digest(1), "2024/07/IMG_0002.xmp": digest(3),
            ]
        )
        #expect(result.groups.count == 1)
    }

    @Test func missingChecksumsAreNotGroupedAndAreCounted() {
        let result = find(
            ["icloud-id:A": ["2024/07/IMG_0001.HEIC"], "icloud-id:B": ["2024/07/IMG_0002.HEIC"]],
            ["2024/07/IMG_0001.HEIC": digest(1)]
        )
        #expect(result.groups.isEmpty)
        #expect(result.notCheckedCount == 1)
    }

    @Test func pathOnlyAndPartialRecordsAreNotItems() {
        let result = find(
            [
                "icloud-id:A": ["2024/07/IMG_0001.HEIC"],
                "icloud-id:B": ["2024/07/IMG_0002.HEIC"],
                // Covered by the ID record for the same file, so it isn't counted.
                "icloud:2024/07/IMG_0001.HEIC": ["2024/07/IMG_0001.HEIC"],
                // Not covered by any ID record: counted as not checked.
                "icloud:2024/07/IMG_0003.HEIC": ["2024/07/IMG_0003.HEIC"],
                "icloud-partial:C": ["2024/07/IMG_0004.HEIC"],
            ],
            [
                "2024/07/IMG_0001.HEIC": digest(1), "2024/07/IMG_0002.HEIC": digest(1),
                "2024/07/IMG_0003.HEIC": digest(1), "2024/07/IMG_0004.HEIC": digest(1),
            ]
        )
        #expect(result.groups.map { $0.copies.map(\.id) } == [["icloud-id:A", "icloud-id:B"]])
        #expect(result.notCheckedCount == 2)
    }

    @Test func differentLayoutsAreNotGrouped() {
        let result = find(
            ["icloud-id:A": ["2024/07/IMG_0001.HEIC"], "icloud-id:B": ["IMG_0001.HEIC"]],
            ["2024/07/IMG_0001.HEIC": digest(1), "IMG_0001.HEIC": digest(1)]
        )
        #expect(result.groups.isEmpty)
    }

    @Test func differentAlbumFoldersAreNotGrouped() {
        // The same photo in two albums is in both on purpose; removing one would take it out of an album.
        let result = find(
            ["icloud-id:A": ["Trips/IMG_0001.HEIC"], "icloud-id:B": ["Family/IMG_0002.HEIC"]],
            ["Trips/IMG_0001.HEIC": digest(1), "Family/IMG_0002.HEIC": digest(1)]
        )
        #expect(result.groups.isEmpty)
    }

    @Test func sameAlbumFolderIsGrouped() {
        let result = find(
            ["icloud-id:A": ["Trips/IMG_0001.HEIC"], "icloud-id:B": ["Trips/IMG_0002.HEIC"]],
            ["Trips/IMG_0001.HEIC": digest(1), "Trips/IMG_0002.HEIC": digest(1)]
        )
        #expect(result.groups.count == 1)
    }

    @Test func differentMonthFoldersAreNotGrouped() {
        let result = find(
            ["icloud-id:A": ["2024/07/IMG_0001.HEIC"], "icloud-id:B": ["2024/08/IMG_0002.HEIC"]],
            ["2024/07/IMG_0001.HEIC": digest(1), "2024/08/IMG_0002.HEIC": digest(1)]
        )
        #expect(result.groups.isEmpty)
    }

    @Test func flatFilesInTheSameFolderAreGrouped() {
        let result = find(
            ["icloud-id:A": ["IMG_0001.HEIC"], "icloud-id:B": ["IMG_0002.HEIC"]],
            ["IMG_0001.HEIC": digest(1), "IMG_0002.HEIC": digest(1)]
        )
        #expect(result.groups.count == 1)
    }

    @Test func recordsThatShareAFileAreNotGrouped() {
        let result = find(
            [
                "icloud-id:A": ["2024/07/IMG_0001.HEIC"],
                "icloud-id:B": ["2024/07/IMG_0001.HEIC"],
                "icloud-id:C": ["2024/07/IMG_0002.HEIC"],
            ],
            [
                "2024/07/IMG_0001.HEIC": digest(1),
                "2024/07/IMG_0002.HEIC": digest(1),
            ]
        )
        // A and B are the same file, so C has no other copy to pair with.
        #expect(result.groups.isEmpty)
    }

    @Test func anAlbumItemCopiedIntoSeveralFoldersIsNeverItsOwnDuplicate() {
        let result = find(
            ["icloud-id:A": ["Trips/IMG_0001.HEIC", "Family/IMG_0001.HEIC"]],
            ["Trips/IMG_0001.HEIC": digest(1), "Family/IMG_0001.HEIC": digest(1)]
        )
        #expect(result.groups.isEmpty)
    }

    @Test func extraCopiesAddUpToTheReclaimableBytes() {
        let result = find(
            ["icloud-id:A": ["2024/07/IMG_0001.HEIC"], "icloud-id:B": ["2024/07/IMG_0002.HEIC"]],
            ["2024/07/IMG_0001.HEIC": digest(1), "2024/07/IMG_0002.HEIC": digest(1)],
            sizes: ["2024/07/IMG_0001.HEIC": 100, "2024/07/IMG_0002.HEIC": 40]
        )
        #expect(result.groups.first?.duplicateBytes == 40)
    }
}

@Suite("Find Duplicates keeper choice")
struct DuplicateKeeperTests {
    private func keeperID(_ records: [String: [String]], order: [String: Int] = [:]) -> String? {
        var checksums: [String: String] = [:]
        for path in records.values.joined() {
            checksums[path] = digest(1)
        }
        return DuplicateFinder.findGroups(records: records, checksums: checksums, sizes: [:], exportOrder: order)
            .groups.first?.keeperID
    }

    @Test func copyMarkersAreCountedInTheFileName() {
        #expect(DuplicateFinder.copyMarkerCount(in: "2024/07/IMG_0001.HEIC") == 0)
        #expect(DuplicateFinder.copyMarkerCount(in: "2024/07/IMG_0001 (1).HEIC") == 1)
        #expect(DuplicateFinder.copyMarkerCount(in: "2024/07/IMG_0001-1.JPG") == 1)
        #expect(DuplicateFinder.copyMarkerCount(in: "2024/07/IMG_0001-2483921.HEIC") == 1)
        #expect(DuplicateFinder.copyMarkerCount(in: "2024/07/IMG_0001 copy.HEIC") == 1)
        #expect(DuplicateFinder.copyMarkerCount(in: "2024/07/IMG_0001 copy (2).HEIC") == 2)
    }

    @Test func theCopyWithFewestMarkersIsKept() {
        // "icloud-id:A" would win on the ID alone, so the marker rule is what keeps B.
        #expect(keeperID(["icloud-id:A": ["2024/07/IMG_0001 (1).HEIC"], "icloud-id:B": ["2024/07/IMG_0001.HEIC"]]) == "icloud-id:B")
    }

    @Test func anIcloudSizeSuffixCountsAsACopyMarker() {
        #expect(keeperID(["icloud-id:A": ["2024/07/IMG_0001-2483921.HEIC"], "icloud-id:B": ["2024/07/IMG_0001.HEIC"]]) == "icloud-id:B")
    }

    @Test func theShortestPathBreaksTheTie() {
        #expect(keeperID(["icloud-id:A": ["2024/07/IMG_0001_long_name.HEIC"], "icloud-id:B": ["2024/07/IMG_0001.HEIC"]]) == "icloud-id:B")
    }

    @Test func theEarliestExportBreaksTheTieAfterPathLength() {
        let records = ["icloud-id:A": ["2024/07/IMG_0001.HEIC"], "icloud-id:B": ["2024/07/IMG_0002.HEIC"]]
        #expect(keeperID(records, order: ["icloud-id:A": 5, "icloud-id:B": 2]) == "icloud-id:B")
    }

    @Test func theEarliestExportIsKeptEvenWhenItsNameHasCopyMarkers() {
        // The original is the first copy saved, so the name's copy marker and the shorter path don't outrank it.
        let records = ["icloud-id:A": ["2024/07/IMG_0001 (1).HEIC"], "icloud-id:B": ["2024/07/IMG_0001.HEIC"]]
        #expect(keeperID(records, order: ["icloud-id:A": 1, "icloud-id:B": 2]) == "icloud-id:A")
    }

    @Test func theKeeperComesFirstInTheGroup() {
        var checksums: [String: String] = [:]
        checksums["2024/07/IMG_0001 (1).HEIC"] = digest(1)
        checksums["2024/07/IMG_0001.HEIC"] = digest(1)
        let result = DuplicateFinder.findGroups(
            records: ["icloud-id:A": ["2024/07/IMG_0001 (1).HEIC"], "icloud-id:B": ["2024/07/IMG_0001.HEIC"]],
            checksums: checksums,
            sizes: [:]
        )
        #expect(result.groups.first?.copies.first?.id == result.groups.first?.keeperID)
        #expect(result.groups.first?.duplicates.map(\.id) == ["icloud-id:A"])
    }
}

@Suite("Find Duplicates removal")
struct DuplicateRemovalTests {
    /// Deletes instead of trashing, so tests never touch the real Trash.
    private static func deleting(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// Writes an item's files and records it the way an export does: the record, and a checksum per file.
    private func save(_ key: String, _ files: [String: String], in destination: URL) throws {
        let manifest = try ExportManifest(destination: destination)
        var checksums: [String: String] = [:]
        for (path, text) in files {
            try writeFile(text, to: path, in: destination)
            checksums[path] = try FileHasher.sha256(of: destination.appending(path: path))
        }
        if key.hasPrefix(ExportManifest.iCloudIDPrefix) {
            try manifest.recordICloudItem(id: String(key.dropFirst(ExportManifest.iCloudIDPrefix.count)), paths: files.keys.sorted())
        } else {
            try manifest.recordExport(of: key, files: files.keys.sorted())
        }
        try manifest.recordChecksums(checksums)
    }

    /// Two identical items: A (exported first, so kept) and B, which has a sidecar.
    private func twoCopies(in destination: URL) throws {
        try save("icloud-id:A", ["2024/07/IMG_0001.HEIC": "same bytes"], in: destination)
        try save("icloud-id:B", ["2024/07/IMG_0002.HEIC": "same bytes", "2024/07/IMG_0002.xmp": "sidecar"], in: destination)
    }

    private func groups(in destination: URL) -> [DuplicateFinder.Group] {
        DuplicateFinder.findGroups(
            records: ExportManifest.records(in: destination),
            checksums: ExportManifest.checksums(in: destination),
            sizes: [:],
            exportOrder: ExportManifest.firstRecordPositions(in: destination)
        ).groups
    }

    @Test func duplicateFilesAreTrashedAndTheKeeperIsKept() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try twoCopies(in: destination)
            let result = DuplicateFinder.remove(groups: groups(in: destination), in: destination, trasher: Self.deleting, progress: { _, _ in })

            #expect(result.removedCopies == 1)
            #expect(result.skippedCopies == 0 && result.failedCopies == 0)
            #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "2024/07/IMG_0002.HEIC").path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "2024/07/IMG_0002.xmp").path(percentEncoded: false)))
            #expect(FileManager.default.fileExists(atPath: destination.appending(path: "2024/07/IMG_0001.HEIC").path(percentEncoded: false)))
        }
    }

    @Test func theRecordIsRepointedAtTheKeeperAndNextScanFindsNothing() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try twoCopies(in: destination)
            _ = DuplicateFinder.remove(groups: groups(in: destination), in: destination, trasher: Self.deleting, progress: { _, _ in })

            let records = ExportManifest.records(in: destination)
            #expect(records["icloud-id:B"] == ["2024/07/IMG_0001.HEIC"])
            #expect(records["icloud-id:A"] == ["2024/07/IMG_0001.HEIC"])
            #expect(groups(in: destination).isEmpty)
        }
    }

    @Test func verifyBackupReportsTheRepointedCopyAsVerified() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try twoCopies(in: destination)
            _ = DuplicateFinder.remove(groups: groups(in: destination), in: destination, trasher: Self.deleting, progress: { _, _ in })

            let report = try await BackupVerifier.verify(destination: destination) { _, _ in }
            #expect(report.verifiedItemIDs == ["icloud-id:A", "icloud-id:B"])
            #expect(report.damagedItemIDs.isEmpty)
        }
    }

    @Test func driveCheckStillCountsTheRepointedCopy() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try twoCopies(in: destination)
            _ = DuplicateFinder.remove(groups: groups(in: destination), in: destination, trasher: Self.deleting, progress: { _, _ in })

            #expect(ICloudItemCount.count(records: ExportManifest.records(in: destination)).exact == 2)
        }
    }

    @Test func aChangedFileIsSkippedAndItsRecordLeftAlone() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try twoCopies(in: destination)
            let found = groups(in: destination)
            try writeFile("changed since the check", to: "2024/07/IMG_0002.HEIC", in: destination)

            var trashed: [URL] = []
            let result = DuplicateFinder.remove(groups: found, in: destination, trasher: { trashed.append($0) }, progress: { _, _ in })

            #expect(result.skippedCopies == 1)
            #expect(result.removedCopies == 0)
            #expect(trashed.isEmpty)
            #expect(ExportManifest.records(in: destination)["icloud-id:B"] == ["2024/07/IMG_0002.HEIC", "2024/07/IMG_0002.xmp"])
        }
    }

    @Test func aTrashFailureOnOneFileMeansNoRepoint() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try twoCopies(in: destination)
            let result = DuplicateFinder.remove(groups: groups(in: destination), in: destination, trasher: { url in
                if url.pathExtension == "xmp" {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try FileManager.default.removeItem(at: url)
            }, progress: { _, _ in })

            #expect(result.failedCopies == 1)
            #expect(result.removedCopies == 0)
            // The file that was moved stays moved; the record keeps its own paths.
            #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "2024/07/IMG_0002.HEIC").path(percentEncoded: false)))
            #expect(ExportManifest.records(in: destination)["icloud-id:B"] == ["2024/07/IMG_0002.HEIC", "2024/07/IMG_0002.xmp"])
        }
    }

    @Test func unsafePathsAreRejectedBeforeAnythingIsTrashed() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("same bytes", to: "2024/07/IMG_0001.HEIC", in: destination)
            let keeper = DuplicateFinder.Copy(
                id: "icloud-id:A", paths: ["2024/07/IMG_0001.HEIC"], mediaPaths: ["2024/07/IMG_0001.HEIC"],
                checksums: ["2024/07/IMG_0001.HEIC": try FileHasher.sha256(of: destination.appending(path: "2024/07/IMG_0001.HEIC"))],
                byteCount: 10, exportOrder: 0
            )
            let escaping = DuplicateFinder.Copy(
                id: "icloud-id:B", paths: ["../escape.HEIC"], mediaPaths: ["../escape.HEIC"],
                checksums: ["../escape.HEIC": keeper.checksums["2024/07/IMG_0001.HEIC"] ?? ""],
                byteCount: 10, exportOrder: 1
            )
            let group = DuplicateFinder.Group(id: "group", copies: [keeper, escaping], keeperID: keeper.id)

            var trashed: [URL] = []
            let result = DuplicateFinder.remove(groups: [group], in: destination, trasher: { trashed.append($0) }, progress: { _, _ in })

            #expect(result.skippedCopies == 1)
            #expect(trashed.isEmpty)
            #expect(FileManager.default.fileExists(atPath: destination.appending(path: "2024/07/IMG_0001.HEIC").path(percentEncoded: false)))
        }
    }

    /// A group of copies of the same bytes: the first path is the keeper, each later path a duplicate.
    private func makeGroup(_ paths: [String], digest: String) -> DuplicateFinder.Group {
        let copies = paths.enumerated().map { index, path in
            DuplicateFinder.Copy(
                id: "icloud-id:\(index)", paths: [path], mediaPaths: [path],
                checksums: [path: digest], byteCount: 10, exportOrder: index
            )
        }
        return DuplicateFinder.Group(id: "group", copies: copies, keeperID: copies[0].id)
    }

    @Test func theKeeperIsCheckedOncePerGroup() async throws {
        try await withTemporaryDirectoryAsync { destination in
            let paths = ["2024/07/IMG_0001.HEIC", "2024/07/IMG_0002.HEIC", "2024/07/IMG_0003.HEIC", "2024/07/IMG_0004.HEIC"]
            for path in paths {
                try writeFile("same bytes", to: path, in: destination)
            }
            var hashed: [String: Int] = [:]
            let result = DuplicateFinder.remove(groups: [makeGroup(paths, digest: digest(1))], in: destination, hasher: { url in
                hashed[url.lastPathComponent, default: 0] += 1
                return digest(1)
            }, trasher: Self.deleting, progress: { _, _ in })

            #expect(result.removedCopies == 3)
            #expect(hashed["IMG_0001.HEIC"] == 1)
            #expect(hashed["IMG_0002.HEIC"] == 1)
        }
    }

    @Test func aChangedKeeperSkipsEveryCopyInItsGroup() async throws {
        try await withTemporaryDirectoryAsync { destination in
            let paths = ["2024/07/IMG_0001.HEIC", "2024/07/IMG_0002.HEIC", "2024/07/IMG_0003.HEIC", "2024/07/IMG_0004.HEIC"]
            for path in paths {
                try writeFile("same bytes", to: path, in: destination)
            }
            var trashed: [URL] = []
            let result = DuplicateFinder.remove(groups: [makeGroup(paths, digest: digest(1))], in: destination, hasher: { url in
                // Only the keeper's content has changed.
                url.lastPathComponent == "IMG_0001.HEIC" ? digest(2) : digest(1)
            }, trasher: { trashed.append($0) }, progress: { _, _ in })

            #expect(result.skippedCopies == 3)
            #expect(result.removedCopies == 0)
            #expect(trashed.isEmpty)
        }
    }

    @Test func aKeeperChosenByTheUserIsHonoured() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try twoCopies(in: destination)
            var group = try #require(groups(in: destination).first)
            group.keeperID = "icloud-id:B"

            _ = DuplicateFinder.remove(groups: [group], in: destination, trasher: Self.deleting, progress: { _, _ in })

            #expect(ExportManifest.records(in: destination)["icloud-id:A"] == ["2024/07/IMG_0002.HEIC", "2024/07/IMG_0002.xmp"])
            #expect(FileManager.default.fileExists(atPath: destination.appending(path: "2024/07/IMG_0002.HEIC").path(percentEncoded: false)))
        }
    }
}

@Suite("Find Duplicates extra copies and shared iCloud items")
struct DuplicateExtraCopyGroupingTests {
    private func find(
        _ records: [String: [String]],
        _ checksums: [String: String],
        order: [String: Int] = [:],
        layout: FolderLayout? = nil
    ) -> DuplicateFinder.Result {
        DuplicateFinder.findGroups(records: records, checksums: checksums, sizes: [:], exportOrder: order, layout: layout)
    }

    @Test func aFlatAndAMonthCopyOfOneItemGiveOneExtraCopyInTheMonthFolder() {
        let result = find(
            ["icloud-id:A": ["2026/10/IMG_3134.HEIC", "IMG_3134.HEIC"]],
            ["2026/10/IMG_3134.HEIC": digest(1), "IMG_3134.HEIC": digest(1)],
            layout: .flat
        )
        #expect(result.extraCopies.map(\.folder) == ["2026/10"])
        #expect(result.extraCopies.first?.paths == ["2026/10/IMG_3134.HEIC"])
        #expect(result.groups.isEmpty)
    }

    @Test func theKeeperFollowsTheCurrentLayout() {
        let result = find(
            ["icloud-id:A": ["2026/10/IMG_3134.HEIC", "IMG_3134.HEIC"]],
            ["2026/10/IMG_3134.HEIC": digest(1), "IMG_3134.HEIC": digest(1)],
            layout: .month
        )
        // The month copy is in the current layout, so the flat copy is the extra one.
        #expect(result.extraCopies.map(\.folder) == [""])
        #expect(result.extraCopies.first?.keeperPaths == ["2026/10/IMG_3134.HEIC"])
    }

    @Test func anInLayoutCopyIsKeptEvenWhenANonLayoutCopyWasRecordedFirst() {
        let result = find(
            ["icloud-id:A": ["IMG_3134.HEIC", "2026/10/IMG_3134.HEIC"]],
            ["2026/10/IMG_3134.HEIC": digest(1), "IMG_3134.HEIC": digest(1)],
            layout: .month
        )
        // The flat copy was recorded first, but the month layout keeps the month copy, so the flat copy is the extra one.
        #expect(result.extraCopies.map(\.folder) == [""])
        #expect(result.extraCopies.first?.keeperPaths == ["2026/10/IMG_3134.HEIC"])
    }

    @Test func withNoLayoutTheCopyRecordedFirstIsKept() {
        let result = find(
            ["icloud-id:A": ["2026/10/IMG_3134.HEIC", "IMG_3134.HEIC"]],
            ["2026/10/IMG_3134.HEIC": digest(1), "IMG_3134.HEIC": digest(1)]
        )
        #expect(result.extraCopies.map(\.folder) == [""])
    }

    @Test func aLivePhotoPairInAnotherFolderMovesAsASet() {
        let result = find(
            ["icloud-id:A": ["2026/10/IMG_3134.HEIC", "2026/10/IMG_3134.MOV", "IMG_3134.HEIC", "IMG_3134.MOV"]],
            [
                "2026/10/IMG_3134.HEIC": digest(1), "2026/10/IMG_3134.MOV": digest(2),
                "IMG_3134.HEIC": digest(1), "IMG_3134.MOV": digest(2),
            ],
            layout: .flat
        )
        #expect(result.extraCopies.count == 1)
        #expect(result.extraCopies.first?.paths == ["2026/10/IMG_3134.HEIC", "2026/10/IMG_3134.MOV"])
        #expect(result.extraCopies.first?.mediaPaths.count == 2)
    }

    @Test func aDifferentChecksumIsNotAnExtraCopy() {
        let result = find(
            ["icloud-id:A": ["2026/10/IMG_3134.HEIC", "IMG_3134.HEIC"]],
            ["2026/10/IMG_3134.HEIC": digest(1), "IMG_3134.HEIC": digest(2)],
            layout: .flat
        )
        #expect(result.extraCopies.isEmpty)
    }

    @Test func anAlbumFolderIsNeverAnExtraCopy() {
        let result = find(
            ["icloud-id:A": ["Trips/IMG_3134.HEIC", "IMG_3134.HEIC"]],
            ["Trips/IMG_3134.HEIC": digest(1), "IMG_3134.HEIC": digest(1)],
            layout: .flat
        )
        #expect(result.extraCopies.isEmpty)
    }

    @Test func aFileListedByAnotherItemIsNotTouched() {
        let result = find(
            [
                "icloud-id:A": ["2026/10/IMG_3134.HEIC", "IMG_3134.HEIC"],
                "icloud-id:B": ["2026/10/IMG_3134.HEIC"],
            ],
            ["2026/10/IMG_3134.HEIC": digest(1), "IMG_3134.HEIC": digest(1)],
            layout: .flat
        )
        #expect(result.extraCopies.isEmpty)
    }

    @Test func twoItemsSharingAFileFormOneGroupWhoseFirstExportIsKept() {
        let result = find(
            ["icloud-id:A": ["IMG_1.HEIC"], "icloud-id:B": ["IMG_1.HEIC"], "icloud-id:C": ["IMG_2.HEIC"]],
            ["IMG_1.HEIC": digest(1), "IMG_2.HEIC": digest(2)],
            order: ["icloud-id:A": 5, "icloud-id:B": 2]
        )
        #expect(result.sharedItemGroups.map(\.ids) == [["icloud-id:B", "icloud-id:A"]])
        #expect(result.sharedItemGroups.first?.keeperID == "icloud-id:B")
        #expect(result.sharedItemGroups.first?.extraIDs == ["icloud-id:A"])
        #expect(result.sharedItemGroups.first?.paths == ["IMG_1.HEIC"])
        // The files are one file, so nothing is a same-folder duplicate.
        #expect(result.groups.isEmpty)
    }

    @Test func sharedItemsOfAnyGroupSizeAreJoined() {
        let result = find(
            [
                "icloud-id:A": ["IMG_1.HEIC"], "icloud-id:B": ["IMG_1.HEIC"], "icloud-id:C": ["IMG_1.HEIC"],
                "icloud-id:D": ["IMG_9.HEIC"],
            ],
            ["IMG_1.HEIC": digest(1), "IMG_9.HEIC": digest(2)]
        )
        #expect(result.sharedItemGroups.count == 1)
        #expect(result.sharedItemGroups.first?.ids.count == 3)
    }
}

@Suite("Find Duplicates extra copy removal")
struct DuplicateExtraCopyRemovalTests {
    /// Deletes instead of trashing, so tests never touch the real Trash.
    private static func deleting(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// Writes an item's files and records it the way an export does.
    private func save(_ id: String, _ files: [String: String], in destination: URL) throws {
        let manifest = try ExportManifest(destination: destination)
        var checksums: [String: String] = [:]
        for (path, text) in files {
            try writeFile(text, to: path, in: destination)
            checksums[path] = try FileHasher.sha256(of: destination.appending(path: path))
        }
        try manifest.recordICloudItem(id: id, paths: files.keys.sorted())
        try manifest.recordChecksums(checksums)
    }

    private func extras(in destination: URL, layout: FolderLayout = .flat) -> [DuplicateFinder.ExtraCopy] {
        DuplicateFinder.findGroups(
            records: ExportManifest.records(in: destination),
            checksums: ExportManifest.checksums(in: destination),
            sizes: [:],
            exportOrder: ExportManifest.firstRecordPositions(in: destination),
            layout: layout
        ).extraCopies
    }

    @Test func theExtraFileGoesToTheTrashAndLeavesItsRecordAndChecksums() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try save("A", ["2026/10/IMG_3134.HEIC": "same bytes", "IMG_3134.HEIC": "same bytes"], in: destination)
            var trashed: [URL] = []
            let result = DuplicateFinder.removeExtraCopies(extras(in: destination), in: destination, trasher: { url in
                trashed.append(url)
                try Self.deleting(url)
            }, progress: { _, _ in })

            #expect(result.removedCopies == 1)
            #expect(result.skippedCopies == 0 && result.failedCopies == 0)
            #expect(trashed.map(\.lastPathComponent) == ["IMG_3134.HEIC"])
            #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "2026/10/IMG_3134.HEIC").path(percentEncoded: false)))
            #expect(FileManager.default.fileExists(atPath: destination.appending(path: "IMG_3134.HEIC").path(percentEncoded: false)))
            #expect(ExportManifest.records(in: destination)["icloud-id:A"] == ["IMG_3134.HEIC"])
            #expect(ExportManifest.checksums(in: destination)["2026/10/IMG_3134.HEIC"] == nil)
            #expect(ExportManifest.checksums(in: destination)["IMG_3134.HEIC"] != nil)
            #expect(extras(in: destination).isEmpty)
        }
    }

    @Test func aLivePhotoPairLeavesTheRecordAsASet() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try save("A", [
                "2026/10/IMG_3134.HEIC": "photo", "2026/10/IMG_3134.MOV": "movie",
                "IMG_3134.HEIC": "photo", "IMG_3134.MOV": "movie",
            ], in: destination)
            let result = DuplicateFinder.removeExtraCopies(extras(in: destination), in: destination, trasher: Self.deleting, progress: { _, _ in })

            #expect(result.removedCopies == 1)
            #expect(ExportManifest.records(in: destination)["icloud-id:A"] == ["IMG_3134.HEIC", "IMG_3134.MOV"])
            #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "2026/10/IMG_3134.MOV").path(percentEncoded: false)))
        }
    }

    @Test func aChangedExtraFileIsRefusedAndNothingMoves() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try save("A", ["2026/10/IMG_3134.HEIC": "same bytes", "IMG_3134.HEIC": "same bytes"], in: destination)
            let found = extras(in: destination)
            try writeFile("changed since the check", to: "2026/10/IMG_3134.HEIC", in: destination)

            var trashed: [URL] = []
            let result = DuplicateFinder.removeExtraCopies(found, in: destination, trasher: { trashed.append($0) }, progress: { _, _ in })

            #expect(result.skippedCopies == 1)
            #expect(result.removedCopies == 0)
            #expect(trashed.isEmpty)
            #expect(ExportManifest.records(in: destination)["icloud-id:A"] == ["2026/10/IMG_3134.HEIC", "IMG_3134.HEIC"])
        }
    }

    @Test func aChangedKeeperIsRefusedAndNothingMoves() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try save("A", ["2026/10/IMG_3134.HEIC": "same bytes", "IMG_3134.HEIC": "same bytes"], in: destination)
            let found = extras(in: destination)
            try writeFile("changed keeper", to: "IMG_3134.HEIC", in: destination)

            var trashed: [URL] = []
            let result = DuplicateFinder.removeExtraCopies(found, in: destination, trasher: { trashed.append($0) }, progress: { _, _ in })

            #expect(result.skippedCopies == 1)
            #expect(trashed.isEmpty)
        }
    }

    @Test func aTrashFailureKeepsTheRecordHonest() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try save("A", [
                "2026/10/IMG_3134.HEIC": "photo", "2026/10/IMG_3134.MOV": "movie",
                "IMG_3134.HEIC": "photo", "IMG_3134.MOV": "movie",
            ], in: destination)
            let result = DuplicateFinder.removeExtraCopies(extras(in: destination), in: destination, trasher: { url in
                if url.pathExtension == "MOV" { throw CocoaError(.fileWriteNoPermission) }
                try Self.deleting(url)
            }, progress: { _, _ in })

            #expect(result.failedCopies == 1)
            // The photo that moved is gone from the record; the movie, still on the drive, stays listed.
            #expect(ExportManifest.records(in: destination)["icloud-id:A"] == ["2026/10/IMG_3134.MOV", "IMG_3134.HEIC", "IMG_3134.MOV"])
            #expect(ExportManifest.checksums(in: destination)["2026/10/IMG_3134.HEIC"] == nil)
        }
    }
}
