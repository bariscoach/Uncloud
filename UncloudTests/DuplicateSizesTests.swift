import Foundation
import Testing
@testable import Uncloud

/// Find Duplicates reads each recorded file's size from one listing per folder. These tests hold that to the answer
/// of a per-file lookup, which is what it was before.
@Suite("Find Duplicates sizes")
struct DuplicateSizesTests {
    /// Sizes by per-file lookup, the way `DuplicateCleanup.scan` got them before the bulk listing.
    private func perFileSizes(_ paths: [String], in destination: URL) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for path in paths {
            guard let url = BackupFiles.containedURL(for: path, in: destination),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            sizes[path] = Int64(values.fileSize ?? 0)
        }
        return sizes
    }

    @Test func listedSizesMatchPerFileLookups() throws {
        try withTemporaryDirectory { destination in
            try writeFile("abc", to: "IMG_1.jpg", in: destination)
            try writeFile("abcdef", to: "2024/07/IMG_2.HEIC", in: destination)
            try writeFile("", to: "2024/07/IMG_3.jpg", in: destination)
            try writeFile("xyz", to: "2024/07/._IMG_2.HEIC", in: destination)
            try FileManager.default.createSymbolicLink(
                at: destination.appending(path: "link.jpg"),
                withDestinationURL: destination.appending(path: "IMG_1.jpg")
            )
            try FileManager.default.createDirectory(
                at: destination.appending(path: "2024/07/folder.jpg"), withIntermediateDirectories: true
            )
            let paths = [
                "IMG_1.jpg", "2024/07/IMG_2.HEIC", "2024/07/IMG_3.jpg", "2024/07/._IMG_2.HEIC",
                "link.jpg", "2024/07/folder.jpg", "2024/07/missing.jpg",
            ]

            let listed = try DuplicateCleanup.recordedSizes(for: paths, in: destination) { _, _ in }

            #expect(listed == perFileSizes(paths, in: destination))
            #expect(listed == [
                "IMG_1.jpg": 3, "2024/07/IMG_2.HEIC": 6, "2024/07/IMG_3.jpg": 0, "2024/07/._IMG_2.HEIC": 3,
            ])
        }
    }

    @Test func reportsProgressPerThousandPathsAndAtTheEnd() throws {
        try withTemporaryDirectory { destination in
            var paths: [String] = []
            for index in 0..<2_500 {
                let path = "2024/07/IMG_\(index).jpg"
                try writeFile("x", to: path, in: destination)
                paths.append(path)
            }
            var reports: [Int] = []

            let sizes = try DuplicateCleanup.recordedSizes(for: paths, in: destination) { done, _ in
                reports.append(done)
            }

            #expect(sizes.count == 2_500)
            #expect(reports.last == 2_500)
            #expect(reports.contains(1_000))
            #expect(reports.contains(2_000))
            #expect(reports.count <= 4, "one report per 1,000 paths, and the last one")
        }
    }

    @Test func aMissingFolderGivesNoSizes() throws {
        try withTemporaryDirectory { destination in
            let paths = ["2099/01/IMG_1.jpg", "2099/01/IMG_2.jpg"]

            let sizes = try DuplicateCleanup.recordedSizes(for: paths, in: destination) { _, _ in }

            #expect(sizes.isEmpty)
        }
    }
}
