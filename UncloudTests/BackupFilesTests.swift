import Foundation
import Testing
@testable import Uncloud

@Suite("Path containment")
struct BackupFilesTests {
    @Test func acceptsPlainRelativePaths() {
        withTemporaryDirectory { destination in
            let url = BackupFiles.containedURL(for: "2024/07/IMG_0001.HEIC", in: destination)
            // A directory's path ends in "/", which the prefix below must not double.
            var root = destination.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            while root.hasSuffix("/") { root.removeLast() }
            #expect(url != nil, "nil for \(destination.path)")
            #expect(url?.path(percentEncoded: false).hasPrefix(root + "/") == true)
        }
    }

    @Test func rejectsEscapesAndOddPaths() {
        withTemporaryDirectory { destination in
            for path in ["", "/etc/passwd", "~/secret", "../outside.jpg", "2024/../../outside.jpg",
                         "2024/./IMG.jpg", "2024//IMG.jpg", ".photo-export/exported.tsv", "a/..", ".."] {
                #expect(BackupFiles.containedURL(for: path, in: destination) == nil, "\(path) should be rejected")
            }
        }
    }

    @Test func rejectsFoldersThatSymlinkOutsideTheDestination() throws {
        try withTemporaryDirectory { root in
            let destination = root.appending(path: "dest", directoryHint: .isDirectory)
            let outside = root.appending(path: "outside", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: destination.appending(path: "2024"), withDestinationURL: outside)
            #expect(BackupFiles.containedURL(for: "2024/IMG_0001.HEIC", in: destination) == nil)
        }
    }

    @Test func keepsAFileSymlinkInsideItsOwnFolder() throws {
        try withTemporaryDirectory { root in
            let destination = root.appending(path: "dest", directoryHint: .isDirectory)
            let outside = try writeFile("outside", to: "secret.jpg", in: root)
            try writeFile("", to: "2024/placeholder", in: destination)
            try FileManager.default.createSymbolicLink(at: destination.appending(path: "2024/IMG.jpg"), withDestinationURL: outside)
            // The link itself is returned, so removing it never removes the target.
            let url = BackupFiles.containedURL(for: "2024/IMG.jpg", in: destination)
            #expect(url?.lastPathComponent == "IMG.jpg")
            #expect(url?.deletingLastPathComponent().lastPathComponent == "2024")
        }
    }

    @Test func removalKeepsFilesSharedWithOtherItemsAndOutsideLinks() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try writeFile("a", to: "Trips/shared.jpg", in: destination)
            try writeFile("b", to: "2024/only-one.jpg", in: destination)
            try manifest.recordExport(of: "one", files: ["Trips/shared.jpg", "2024/only-one.jpg"])
            try manifest.recordExport(of: "two", files: ["Trips/shared.jpg"])

            let result = BackupFiles.removeRecordedFiles(for: ["one"], in: destination)

            #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "2024/only-one.jpg").path(percentEncoded: false)))
            #expect(FileManager.default.fileExists(atPath: destination.appending(path: "Trips/shared.jpg").path(percentEncoded: false)))
            #expect(result.keptPaths == ["Trips/shared.jpg"])
            #expect(result.clearedIDs.isEmpty)
            #expect(result.removedFileCount == 1)
        }
    }
}
