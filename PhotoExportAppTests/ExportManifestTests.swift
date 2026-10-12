import Foundation
import Testing
@testable import PhotoExportApp

@Suite("ExportManifest")
struct ExportManifestTests {
    @Test func journalRoundTripsRecordsAndIDs() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try manifest.recordExport(of: "item1", files: ["2024/07/1.jpg"])
            try manifest.recordExport(of: "item2", files: ["2024/07/2.jpg", "2024/07/2-live.mov"])
            #expect(ExportManifest.records(in: destination) == [
                "item1": ["2024/07/1.jpg"],
                "item2": ["2024/07/2.jpg", "2024/07/2-live.mov"],
            ])
            #expect(ExportManifest.exportedIDs(in: destination) == ["item1", "item2"])
        }
    }

    @Test func laterLineForSameIDReplacesEarlierOne() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try manifest.recordExport(of: "item3", files: ["2024/08/3.mov"])
            try manifest.recordExport(of: "item3", files: ["2024/09/3-redo.mov"])
            #expect(ExportManifest.records(in: destination)["item3"] == ["2024/09/3-redo.mov"])
        }
    }

    @Test func partialLastLineIsIgnoredAndAppendingKeepsEarlierLines() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try manifest.recordChecksums(["2024/07/1.jpg": String(repeating: "a", count: 64)])
            let checksums = destination.appending(path: ".photo-export/checksums.tsv")
            let before = try String(contentsOf: checksums, encoding: .utf8)
            // Simulate a crash in the middle of writing a line.
            try Data((before + "partial/path.jpg\tdeadbe").utf8).write(to: checksums)

            #expect(ExportManifest.checksums(in: destination)["partial/path.jpg"] == nil)

            let reopened = try ExportManifest(destination: destination)
            let fresh = String(repeating: "1", count: 64)
            try reopened.recordChecksums(["fresh/5.jpg": fresh])
            let sums = ExportManifest.checksums(in: destination)
            #expect(sums["fresh/5.jpg"] == fresh)
            #expect(sums["2024/07/1.jpg"] == String(repeating: "a", count: 64))
            #expect(sums["partial/path.jpg"] == nil)
        }
    }

    @Test func partialJournalLineStaysUnexportedAfterReopening() throws {
        try withTemporaryDirectory { destination in
            _ = try ExportManifest(destination: destination)
            let journal = destination.appending(path: ".photo-export/exported.tsv")
            // item2 was cut off mid-line by a crash. It was never finished, so it must not count as exported.
            try Data("item1\t2024/07/1.jpg\nitem2\t2024/07/2".utf8).write(to: journal)
            #expect(ExportManifest.exportedIDs(in: destination) == ["item1"])

            let reopened = try ExportManifest(destination: destination)
            try reopened.recordExport(of: "item3", files: ["2024/07/3.jpg"])
            #expect(ExportManifest.exportedIDs(in: destination) == ["item1", "item3"])
            #expect(ExportManifest.records(in: destination)["item2"] == nil)
            #expect(ExportManifest.records(in: destination)["item1"] == ["2024/07/1.jpg"])
        }
    }

    @Test func forgetRemovesOnlyTheGivenItemsAndTheirChecksums() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try manifest.recordExport(of: "item1", files: ["2024/07/1.jpg"])
            try manifest.recordExport(of: "item2", files: ["2024/07/2.jpg", "2024/07/2-live.mov"])
            try manifest.recordExport(of: "item3", files: ["2024/08/3.mov"])
            let digest = { (letter: String) in String(repeating: letter, count: 64) }
            try manifest.recordChecksums([
                "2024/07/1.jpg": digest("a"), "2024/07/2.jpg": digest("b"), "2024/07/2-live.mov": digest("c"), "2024/08/3.mov": digest("d"),
            ])

            try ExportManifest.forget(["item1", "item2"], in: destination)

            #expect(ExportManifest.records(in: destination).keys.sorted() == ["item3"])
            #expect(ExportManifest.exportedIDs(in: destination) == ["item3"])
            #expect(ExportManifest.checksums(in: destination) == ["2024/08/3.mov": digest("d")])
        }
    }

    @Test func runMarkerTracksIncompleteRuns() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            #expect(ExportManifest.hasIncompleteRun(in: destination))
            manifest.markRunFinished()
            #expect(!ExportManifest.hasIncompleteRun(in: destination))
        }
    }

    @Test func layoutIsRecordedAndRead() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            #expect(ExportManifest.layout(in: destination) == nil)
            try manifest.recordLayout(.album)
            #expect(ExportManifest.layout(in: destination) == .album)
        }
    }

    @Test func shortDigestFromACrashIsSkipped() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try manifest.recordChecksums(["2024/07/ok.jpg": String(repeating: "a", count: 64)])
            let checksums = destination.appending(path: ".photo-export/checksums.tsv")
            try Data((try String(contentsOf: checksums, encoding: .utf8) + "2024/07/cut.jpg\tabc").utf8).write(to: checksums)
            #expect(ExportManifest.checksums(in: destination).keys.sorted() == ["2024/07/ok.jpg"])
        }
    }
}

@Suite("Hashing")
struct HashingTests {
    @Test func sha256OfAbcIsCorrect() {
        let hasher = StreamingHasher()
        hasher.update(Data("abc".utf8))
        #expect(hasher.finalizeHex() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func streamingMatchesFileHashForSeveralChunkSizes() throws {
        try withTemporaryDirectory { folder in
            let big = Data((0..<3_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 7)) })
            let url = folder.appending(path: "big.bin")
            try big.write(to: url)
            let fileDigest = try FileHasher.sha256(of: url)
            for chunk in [1, 1000, 65_536, 1 << 20] {
                let hasher = StreamingHasher()
                var offset = 0
                while offset < big.count {
                    let end = min(offset + chunk, big.count)
                    hasher.update(big.subdata(in: offset..<end))
                    offset = end
                }
                #expect(hasher.finalizeHex() == fileDigest, "chunk \(chunk)")
            }
        }
    }
}

@Suite("BackupVerifier")
struct BackupVerifierTests {
    /// Four items: 1 corrupted, 2 missing a live-photo file, 3 intact, 4 recorded without checksums.
    private func makeBackup(in destination: URL) throws {
        let manifest = try ExportManifest(destination: destination)
        try writeFile("alpha photo bytes", to: "2024/07/1.jpg", in: destination)
        try writeFile("beta photo bytes", to: "2024/07/2.jpg", in: destination)
        try writeFile("gamma movie bytes", to: "2024/08/3.mov", in: destination)
        try writeFile("delta old bytes", to: "2024/08/4.jpg", in: destination)
        try manifest.recordExport(of: "item1", files: ["2024/07/1.jpg"])
        try manifest.recordExport(of: "item2", files: ["2024/07/2.jpg", "2024/07/2-live.mov"])
        try manifest.recordExport(of: "item3", files: ["2024/08/3.mov"])
        try manifest.recordExport(of: "item4", files: ["2024/08/4.jpg"])

        var sums: [String: String] = [:]
        for path in ["2024/07/1.jpg", "2024/07/2.jpg", "2024/08/3.mov"] {
            sums[path] = try FileHasher.sha256(of: destination.appending(path: path))
        }
        try writeFile("beta live bytes", to: "2024/07/2-live.mov", in: destination)
        sums["2024/07/2-live.mov"] = try FileHasher.sha256(of: destination.appending(path: "2024/07/2-live.mov"))
        try manifest.recordChecksums(sums)

        try Data("CORRUPTED".utf8).write(to: destination.appending(path: "2024/07/1.jpg"))
        try FileManager.default.removeItem(at: destination.appending(path: "2024/07/2-live.mov"))
    }

    @Test func classifiesVerifiedDamagedUnverifiableAndNotBackedUp() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try makeBackup(in: destination)
            let report = try await BackupVerifier.verify(
                destination: destination, libraryIDs: ["item1", "item2", "item3", "item4", "extra"]
            ) { _, _ in }
            #expect(report.verifiedItemIDs == ["item3"])
            #expect(report.damagedItemIDs == ["item1", "item2"])
            #expect(report.unverifiableItemIDs == ["item4"])
            #expect(report.notBackedUpCount == 1)
            #expect(report.missingFiles == ["2024/07/2-live.mov"])
            #expect(report.damagedFiles == ["2024/07/1.jpg"])
        }
    }

    @Test func itemIDsLimitTheCheck() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try makeBackup(in: destination)
            let limited = try await BackupVerifier.verify(destination: destination, itemIDs: ["item3", "item4"]) { _, _ in }
            #expect(limited.verifiedItemIDs == ["item3"])
            #expect(limited.unverifiableItemIDs == ["item4"])
            #expect(limited.damagedItemIDs.isEmpty)
        }
    }

    @Test func forgettingDamagedItemsDropsTheirRecordsAndChecksums() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try makeBackup(in: destination)
            try ExportManifest.forget(["item1", "item2"], in: destination)
            #expect(ExportManifest.records(in: destination).keys.sorted() == ["item3", "item4"])
            let sums = ExportManifest.checksums(in: destination)
            #expect(sums["2024/07/1.jpg"] == nil && sums["2024/07/2.jpg"] == nil && sums["2024/07/2-live.mov"] == nil)
            #expect(sums["2024/08/3.mov"] != nil)
            #expect(ExportManifest.exportedIDs(in: destination) == ["item3", "item4"])
        }
    }
}

@Suite("ICloudChecksumScanner")
struct ICloudChecksumScannerTests {
    private func scanner(for destination: URL, layout: FolderLayout = .month) throws -> ICloudChecksumScanner {
        ICloudChecksumScanner(destination: destination, manifest: try ExportManifest(destination: destination), layout: layout)
    }

    @Test func recordsIcloudDownloadsOnceAndIgnoresUserFilesAndTempFiles() throws {
        try withTemporaryDirectory { destination in
            try writeFile("photo", to: "2024/07/IMG_0001.HEIC", in: destination)
            try writeFile("partial", to: "2024/07/IMG_0002.HEIC.part", in: destination)
            try writeFile("hidden", to: "2024/07/.DS_Store", in: destination)
            try writeFile("hidden", to: "2024/.hidden/inner.jpg", in: destination)
            try writeFile("mine", to: "Trips/Rome/IMG_0100.JPG", in: destination)
            try writeFile("mine", to: "Docs/report.pdf", in: destination)

            let scanner = try scanner(for: destination)
            #expect(try scanner.scan(destination, settledBefore: nil) == 1)
            // A second scan finds the same file already recorded.
            #expect(try scanner.scan(destination, settledBefore: nil) == 0)

            let records = ExportManifest.records(in: destination)
            #expect(records["icloud:2024/07/IMG_0001.HEIC"] == ["2024/07/IMG_0001.HEIC"])
            #expect(records.count == 1)
            #expect(ExportManifest.checksums(in: destination)["2024/07/IMG_0001.HEIC"] == (try FileHasher.sha256(of: destination.appending(path: "2024/07/IMG_0001.HEIC"))))
        }
    }

    @Test func skipsFilesModifiedAfterTheSettledDate() throws {
        try withTemporaryDirectory { destination in
            let file = try writeFile("photo", to: "2024/07/IMG_0001.HEIC", in: destination)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 3600)], ofItemAtPath: file.path(percentEncoded: false))
            let scanner = try scanner(for: destination)
            #expect(try scanner.scan(destination, settledBefore: .now) == 0)
            #expect(try scanner.scan(destination, settledBefore: nil) == 1)
        }
    }

    @Test func monthLayoutOnlyRecordsYearMonthFolders() throws {
        try withTemporaryDirectory { destination in
            try writeFile("photo", to: "2024/07/IMG_0001.HEIC", in: destination)
            try writeFile("photo", to: "2024/IMG_0002.HEIC", in: destination)
            try writeFile("photo", to: "Trips/2024/07/IMG_0003.HEIC", in: destination)
            #expect(try scanner(for: destination).scan(destination, settledBefore: nil) == 1)
        }
    }

    @Test func albumLayoutRecordsEverythingInTheScannedFolder() throws {
        try withTemporaryDirectory { destination in
            try writeFile("photo", to: "Trips/Rome 2024/IMG_0001.JPG", in: destination)
            #expect(try scanner(for: destination, layout: .album).scan(destination.appending(path: "Trips/Rome 2024"), settledBefore: nil) == 1)
        }
    }

    @Test func fileNamesWithControlCharactersAreNotRecorded() throws {
        try withTemporaryDirectory { destination in
            try writeFile("photo", to: "2024/07/bad\tname.jpg", in: destination)
            try writeFile("photo", to: "2024/07/ok.jpg", in: destination)
            #expect(try scanner(for: destination).scan(destination, settledBefore: nil) == 1)
        }
    }
}
