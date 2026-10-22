import Foundation
import Testing
@testable import Uncloud

/// The String-based parser that `ManifestLines` replaced, kept verbatim as the reference the new parser must match.
private enum OldManifestParser {
    static func readLines(_ data: Data) -> (lines: [Substring], endsMidLine: Bool) {
        guard !data.isEmpty else { return ([], false) }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n")
        let endsMidLine = !text.hasSuffix("\n")
        if endsMidLine {
            lines.removeLast()
        }
        return (lines, endsMidLine)
    }

    static func firstField(of line: Substring) -> String? {
        line.split(separator: "\t", maxSplits: 1).first.map(String.init)
    }

    static func exportedIDs(_ data: Data) -> Set<String> {
        Set(readLines(data).lines.compactMap { firstField(of: $0) })
    }

    static func records(_ data: Data) -> [String: [String]] {
        var records: [String: [String]] = [:]
        for line in readLines(data).lines {
            let fields = line.split(separator: "\t").map(String.init)
            guard let id = fields.first else { continue }
            records[id] = Array(fields.dropFirst())
        }
        return records
    }

    static func checksums(_ data: Data) -> [String: String] {
        var checksums: [String: String] = [:]
        for line in readLines(data).lines {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, fields[1].count == 64, fields[1].allSatisfy(\.isHexDigit) else { continue }
            checksums[String(fields[0])] = String(fields[1])
        }
        return checksums
    }

    static func firstRecordPositions(_ data: Data) -> [String: Int] {
        var positions: [String: Int] = [:]
        for (index, line) in readLines(data).lines.enumerated() {
            if let id = firstField(of: line), positions[id] == nil {
                positions[id] = index
            }
        }
        return positions
    }

    /// The last `limit` records as `[id] + paths`.
    static func recentRecords(_ data: Data, limit: Int) -> [[String]] {
        readLines(data).lines.suffix(limit).compactMap { line in
            let fields = line.split(separator: "\t").map(String.init)
            guard !fields.isEmpty else { return nil }
            return fields
        }
    }
}

/// SplitMix64: a fixed-seed generator, so every run sees the same fixture.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Builds manifest text as raw bytes, so the fixtures can include invalid UTF-8. A class, so helper calls can nest.
private final class FixtureBuilder {
    var rng: SeededGenerator
    var bytes: [UInt8] = []

    init(rng: SeededGenerator) {
        self.rng = rng
    }

    static let pathPieces = [
        "2024/07/IMG_0001.HEIC", "2024/07/Cafe\u{301}.jpg", "2024/07/Café.mov", "2019/🌅 sunset.jpg",
        "x", "IMG_0002 (1).JPG", "中文/照片.png", "y\u{0308}.heic", "2020/a b/c.mov",
    ]

    func text(_ string: String) {
        bytes += string.utf8
    }

    func int(_ range: Range<Int>) -> Int {
        Int.random(in: range, using: &rng)
    }

    func pick(_ items: [String]) -> String {
        items[int(0..<items.count)]
    }

    func path() -> String {
        pick(Self.pathPieces)
    }

    func digest(uppercase: Bool) -> String {
        let digits = Array(uppercase ? "0123456789ABCDEF" : "0123456789abcdef")
        return String((0..<64).map { _ in digits[int(0..<16)] })
    }

    /// One line of `exported.tsv`, ordinary or tricky.
    func journalLine(keySpace: Int) {
        let id = "item\(int(0..<keySpace))"
        let key = int(0..<10) < 3 ? "icloud-id:\(id)" : id
        switch int(0..<100) {
        case 0..<55:
            text(key)
            for _ in 0..<int(1..<4) { text("\t" + path()) }
            text("\n")
        case 55..<62:
            text(key + "\t")
            if int(0..<2) == 0 { text("\t") }
            text(path())
            if int(0..<2) == 0 { text("\t") }
            text("\n")
        case 62..<68:
            text("\t" + key + "\t" + path() + "\n")
        case 68..<74:
            // CR LF is one character to Swift, so the old parser never ended the line here.
            text(key + "\t" + path() + "\r\n")
        case 74..<78:
            text(key)
            bytes += [0xFF, 0xC3]
            text("\t" + path() + "\n")
        case 78..<82:
            text("\n")
        case 82..<88:
            text((int(0..<2) == 0 ? "Cafe\u{301}" : "Café") + "\(id)\t" + path() + "\n")
        default:
            for _ in 0..<int(1..<8) {
                text(pick(["\t", "a", "\r", "\u{FFFD}", "é", "\u{301}", "9", "f", " ", "\t\t"]))
            }
            text("\n")
        }
    }

    /// One line of `checksums.tsv`, ordinary or tricky.
    func checksumLine(pathSpace: Int) {
        let path = "2024/\(int(0..<pathSpace)).jpg"
        let hash = digest(uppercase: int(0..<4) == 0)
        switch int(0..<100) {
        case 0..<70: text(path + "\t" + hash + "\n")
        case 70..<76: text(path + "\t" + String(hash.prefix(63)) + "\n")
        case 76..<80: text(path + "\t" + String(repeating: "z", count: 64) + "\n")
        case 80..<84: text("\t" + path + "\t" + hash + "\n")
        case 84..<88: text(path + "\t\t" + hash + "\n")
        case 88..<91: text(path + "\t" + hash + "\tjunk\n")
        case 91..<94: text(path + "\n")
        case 94..<96: text(path + "\t" + hash + "\r\n")
        default: text(path + "\t" + hash + "é\n")
        }
    }
}

private func generateJournal(lines: Int, seed: UInt64, endsMidLine: Bool) -> Data {
    let builder = FixtureBuilder(rng: SeededGenerator(seed: seed))
    for _ in 0..<lines {
        builder.journalLine(keySpace: max(1, lines / 2))
    }
    if endsMidLine {
        builder.text("item-last\tpartial/no-newline.jpg")
    }
    return Data(builder.bytes)
}

private func generateChecksums(lines: Int, seed: UInt64, endsMidLine: Bool) -> Data {
    let builder = FixtureBuilder(rng: SeededGenerator(seed: seed))
    for _ in 0..<lines {
        builder.checksumLine(pathSpace: max(1, lines / 2))
    }
    if endsMidLine {
        builder.text("2024/last.jpg\t" + String(repeating: "a", count: 20))
    }
    return Data(builder.bytes)
}

/// Compares every parser output for `data` with the old parser's.
private func expectSameParse(_ data: Data) {
    #expect(ManifestLines.parseRecords(data) == OldManifestParser.records(data))
    #expect(ManifestLines.parseIDs(data) == OldManifestParser.exportedIDs(data))
    #expect(ManifestLines.parseChecksums(data) == OldManifestParser.checksums(data))
    let new = ManifestLines.lines(in: data)
    let old = OldManifestParser.readLines(data)
    #expect(new.lines == old.lines.map(String.init))
    #expect(new.endsMidLine == old.endsMidLine)
}

private func writeManifestFile(_ data: Data, named name: String, in destination: URL) throws {
    let folder = destination.appending(path: ".photo-export", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try data.write(to: folder.appending(path: name))
}

private func journalURL(in destination: URL) -> URL {
    destination.appending(path: ".photo-export/exported.tsv")
}

@Suite("ExportManifest parsing")
struct ExportManifestParsingTests {
    @Test func generatedManifestParsesLikeTheOldParser() throws {
        let journal = generateJournal(lines: 10_000, seed: 0xC0FFEE, endsMidLine: true)
        let checksums = generateChecksums(lines: 10_000, seed: 0xBEEF, endsMidLine: true)
        try withTemporaryDirectory { destination in
            try writeManifestFile(journal, named: "exported.tsv", in: destination)
            try writeManifestFile(checksums, named: "checksums.tsv", in: destination)

            #expect(ExportManifest.records(in: destination) == OldManifestParser.records(journal))
            #expect(ExportManifest.exportedIDs(in: destination) == OldManifestParser.exportedIDs(journal))
            #expect(ExportManifest.checksums(in: destination) == OldManifestParser.checksums(checksums))
            #expect(ExportManifest.firstRecordPositions(in: destination) == OldManifestParser.firstRecordPositions(journal))
            #expect(ExportManifest.recentRecords(in: destination, limit: 500).map { [$0.id] + $0.paths }
                == OldManifestParser.recentRecords(journal, limit: 500))
        }
    }

    @Test func generatedManifestWithAFullLastLineParsesLikeTheOldParser() {
        let journal = generateJournal(lines: 5_000, seed: 7, endsMidLine: false)
        let checksums = generateChecksums(lines: 5_000, seed: 8, endsMidLine: false)
        expectSameParse(journal)
        #expect(ManifestLines.parseChecksums(checksums) == OldManifestParser.checksums(checksums))
    }

    @Test func trickyLinesParseLikeTheOldParser() {
        let digest64 = String(repeating: "a", count: 64)
        let cases: [String] = [
            "", "\n", "\n\n", "a", "a\n", "a\n\n", "a\r\n", "a\r\nb\n", "\r\n", "\r", "\r\r\n", "\n\r",
            "\tabc\tdef\n", "abc\t\tdef\n", "abc\t\n", "\t\t\n", "\t\n", "\tabc\n", "abc\t\t\n",
            "id\tp\r\n", "id\tp\r", "id\tp\r\nid2\tq\n",
            "k\t\(digest64)\n", "k\t\(String(repeating: "a", count: 63))\n", "\tk\t\(digest64)\n",
            "k\t\t\(digest64)\n", "k\t\(digest64)\tz\n", "k\t\(digest64)\r\n", "k\t\(digest64)\t\n",
            "k\t\(String(repeating: "A", count: 64))\n", "k\t\(digest64)é\n",
            "k\t\(String(repeating: "０", count: 64))\n", "k\t\(String(repeating: "a", count: 63))\u{301}\n",
            "k\t\(String(repeating: "a", count: 63))\u{0660}\n", "k\t\(String(repeating: "\u{0660}", count: 64))\n",
            "é\tp\n", "e\u{301}\tp\n", "é\tp\ne\u{301}\tq\n", "\u{FFFD}\tp\n", "k\u{0}\tp\n",
            "a\tb\tc\td\te\n", "a\t\tb\n", "\u{301}\tp\n", "x\u{301}\t\u{301}\n",
            "中文\t照片\n", "🌅\t📷\n", "🌅\u{301}\t📷\n",
        ]
        for text in cases {
            expectSameParse(Data(text.utf8))
        }
        let rawCases: [[UInt8]] = [
            [0xFF, 0x09, 0x41, 0x0A],
            [0xE2, 0x82, 0x09, 0x41, 0x0A],
            [0xE2, 0x82],
            [0x41, 0x09, 0xE2, 0x82, 0x0A, 0x42, 0x09, 0x43, 0x0A],
            [0x41, 0x09, 0x0A, 0x0D],
        ]
        for bytes in rawCases {
            expectSameParse(Data(bytes))
        }
    }

    @Test func randomNoiseParsesLikeTheOldParser() {
        let builder = FixtureBuilder(rng: SeededGenerator(seed: 99))
        for _ in 0..<300 {
            for _ in 0..<builder.int(0..<12) {
                let piece = builder.pick(["\t", "\n", "\r", "a", "é", "\u{301}", "\u{FFFD}", "0", "f", " "])
                builder.text(piece)
            }
            if builder.int(0..<4) == 0 { builder.bytes.append(0xFF) }
            expectSameParse(Data(builder.bytes))
            builder.bytes.removeAll()
        }
    }

    @Test func cacheIsUsedUntilTheManifestChanges() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try manifest.recordExport(of: "one", files: ["a.jpg"])
            let journal = journalURL(in: destination)

            let before = ManifestTextCache.parseCount(at: journal)
            #expect(ExportManifest.records(in: destination)["one"] == ["a.jpg"])
            #expect(ExportManifest.records(in: destination)["one"] == ["a.jpg"])
            #expect(ManifestTextCache.parseCount(at: journal) - before == 1)

            try manifest.recordExport(of: "two", files: ["b.jpg"])
            #expect(ExportManifest.records(in: destination)["two"] == ["b.jpg"])
            #expect(ManifestTextCache.parseCount(at: journal) - before == 2)
        }
    }

    @Test func appendByAnotherWriterIsSeen() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try manifest.recordExport(of: "one", files: ["a.jpg"])
            #expect(ExportManifest.records(in: destination).count == 1)

            // Another process appends straight to the file, bypassing ExportManifest.
            let handle = try FileHandle(forWritingTo: journalURL(in: destination))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("two\tb.jpg\n".utf8))
            try handle.close()

            #expect(ExportManifest.records(in: destination)["two"] == ["b.jpg"])
        }
    }

    @Test func replacedFileWithTheSameSizeIsReadAgain() throws {
        try withTemporaryDirectory { destination in
            try writeManifestFile(Data("one\tx.jpg\n".utf8), named: "exported.tsv", in: destination)
            #expect(ExportManifest.records(in: destination)["one"] == ["x.jpg"])

            // The same size, replaced as a whole file (a new inode), as a swapped drive or an atomic rewrite would.
            try Data("one\ty.jpg\n".utf8).write(to: journalURL(in: destination), options: .atomic)
            #expect(ExportManifest.records(in: destination)["one"] == ["y.jpg"])
        }
    }

    @Test func concurrentReadersGetTheSameResult() async throws {
        let journal = generateJournal(lines: 2_000, seed: 3, endsMidLine: true)
        let expected = OldManifestParser.records(journal)
        try await withTemporaryDirectoryAsync { destination in
            try writeManifestFile(journal, named: "exported.tsv", in: destination)
            let agreed = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        (0..<50).allSatisfy { _ in ExportManifest.records(in: destination) == expected }
                    }
                }
                return await group.reduce(true) { $0 && $1 }
            }
            #expect(agreed)
        }
    }

    /// `UNCLOUD_BENCH=1` only. Prints the parse time of a 100,000-line manifest with the old and the new parser.
    @Test func parseTimeFor100kLines() throws {
        guard ProcessInfo.processInfo.environment["UNCLOUD_BENCH"] == "1" else { return }
        let journal = generateJournal(lines: 100_000, seed: 11, endsMidLine: true)
        let checksums = generateChecksums(lines: 100_000, seed: 12, endsMidLine: true)
        let clock = ContinuousClock()

        var oldRecords: [String: [String]] = [:]
        let oldRecordsTime = clock.measure { oldRecords = OldManifestParser.records(journal) }
        var newRecords: [String: [String]] = [:]
        let newRecordsTime = clock.measure { newRecords = ManifestLines.parseRecords(journal) }

        var oldIDs: Set<String> = []
        let oldIDsTime = clock.measure { oldIDs = OldManifestParser.exportedIDs(journal) }
        var newIDs: Set<String> = []
        let newIDsTime = clock.measure { newIDs = ManifestLines.parseIDs(journal) }

        var oldChecksums: [String: String] = [:]
        let oldChecksumsTime = clock.measure { oldChecksums = OldManifestParser.checksums(checksums) }
        var newChecksums: [String: String] = [:]
        let newChecksumsTime = clock.measure { newChecksums = ManifestLines.parseChecksums(checksums) }

        print("R7 parse, 100,000 lines (\(journal.count) bytes journal, \(checksums.count) bytes checksums)")
        print("R7 records   old \(oldRecordsTime)  new \(newRecordsTime)")
        print("R7 ids       old \(oldIDsTime)  new \(newIDsTime)")
        print("R7 checksums old \(oldChecksumsTime)  new \(newChecksumsTime)")

        #expect(newRecords == oldRecords)
        #expect(newIDs == oldIDs)
        #expect(newChecksums == oldChecksums)
    }
}
