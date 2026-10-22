import Foundation
import Testing
@testable import Uncloud

/// The flat folder's "other files" count, from one bulk listing. `ExportModel.unrecordedEntryCount` delegates to it, so
/// these tests check the counts directly.
@Suite("Flat folder check")
struct FlatFolderCheckTests {
    private func recordFiles(_ paths: [String], in destination: URL) throws {
        try ExportManifest.appendRecords(
            paths.map { (key: "icloud-id:\($0)", paths: [$0]) },
            in: destination
        )
    }

    @Test func countMatchesTheFoundationCountOnAMixedFolder() throws {
        try withTemporaryDirectory { destination in
            try writeFile("a", to: "IMG_0001.HEIC", in: destination)
            try writeFile("b", to: "IMG_0002.MOV", in: destination)
            try writeFile("c", to: "stray.jpg", in: destination)
            try writeFile("d", to: "notes.txt", in: destination)
            try writeFile("e", to: ".DS_Store", in: destination)
            try writeFile("f", to: "IMG_0003.HEIC.part", in: destination)
            try writeFile("g", to: "._IMG_0001.HEIC", in: destination)
            try writeFile("h", to: "2024/07/nested.jpg", in: destination)
            try FileManager.default.createDirectory(
                at: destination.appending(path: "empty-folder", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: destination.appending(path: "link.jpg"),
                withDestinationURL: destination.appending(path: "stray.jpg")
            )
            try recordFiles(["IMG_0001.HEIC", "IMG_0002.MOV", "2024/07/nested.jpg"], in: destination)

            let records = ExportManifest.records(in: destination)
            let flat = FlatFolderCheck.unrecordedEntryCount(in: destination, records: records)

            // stray.jpg, notes.txt, IMG_0003.HEIC.part, 2024, empty-folder, link.jpg
            #expect(flat == 6)
            #expect(ExportModel.unrecordedEntryCount(in: destination) == 6)
        }
    }

    @Test func countIsZeroForAFolderWithOnlyRecordedFiles() throws {
        try withTemporaryDirectory { destination in
            try writeFile("a", to: "IMG_0001.HEIC", in: destination)
            try recordFiles(["IMG_0001.HEIC"], in: destination)

            let flat = FlatFolderCheck.unrecordedEntryCount(in: destination, records: ExportManifest.records(in: destination))

            #expect(flat == 0)
        }
    }

    @Test func hiddenFlaggedEntriesDoNotCount() throws {
        try withTemporaryDirectory { destination in
            try writeFile("a", to: "stray.jpg", in: destination)
            try writeFile("b", to: "System Volume Information", in: destination)
            let flagged = destination.appending(path: "System Volume Information")
            #expect(chflags(flagged.path(percentEncoded: false), UInt32(UF_HIDDEN)) == 0)
            defer { _ = chflags(flagged.path(percentEncoded: false), 0) }

            let flat = FlatFolderCheck.unrecordedEntryCount(in: destination, records: [:])

            #expect(flat == 1)
        }
    }

    @Test func countSpansSeveralBuffers() throws {
        try withTemporaryDirectory { destination in
            var recorded: [String] = []
            let padding = String(repeating: "p", count: 180)
            for index in 0..<4_000 {
                let name = "IMG_\(String(format: "%05d", index))_\(padding).jpg"
                try writeFile("x", to: name, in: destination)
                if index % 4 == 0 { recorded.append(name) }
            }
            try recordFiles(recorded, in: destination)

            let flat = FlatFolderCheck.unrecordedEntryCount(in: destination, records: ExportManifest.records(in: destination))

            #expect(flat == 3_000)
        }
    }

    @Test func missingFolderIsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "uncloud-flat-missing-\(UUID().uuidString)", directoryHint: .isDirectory)

        #expect(FlatFolderCheck.unrecordedEntryCount(in: missing, records: [:]) == nil)
    }

    @Test func emptyFolderCountsNothing() throws {
        try withTemporaryDirectory { destination in
            #expect(FlatFolderCheck.unrecordedEntryCount(in: destination, records: [:]) == 0)
        }
    }
}
