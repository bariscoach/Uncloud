// readbench: times the ways Uncloud lists a folder. Read-only; it never writes, renames or deletes anything.
//
// Build: swiftc -O Tools/ReadBench/readbench.swift -o /tmp/readbench
// Run:   /tmp/readbench <folder> [all|readdir|bulk|fm|statall|lstat N|lstatlast N]
//
// Methods:
//   readdir    opendir/readdir, names only
//   bulk       getattrlistbulk: names, types, sizes and mtimes in one pass (BulkDirectoryLister)
//   fm         FileManager.contentsOfDirectory with keys and resourceValues (what DriveInventory did)
//   statall    lstat of every visible name (the reference for the size total)
//   lstat N    lstat of the first N visible names, cold
//   lstatlast  lstat of the last N visible names, cold
// "all" runs readdir, bulk, fm and statall, then checks that the counts match and that the bulk byte total equals
// the statall total. Counts are visible entries (names not starting with "."). Use a folder with only regular files
// for the counts to match exactly.

import Foundation
import Darwin

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fail("usage: readbench <folder> [all|readdir|bulk|fm|statall|lstat N|lstatlast N]")
}
let folder = arguments[1]
let mode = arguments.count > 2 ? arguments[2] : "all"
let limit = arguments.count > 3 ? (Int(arguments[3]) ?? 1000) : 1000

struct Measurement {
    let label: String
    let entries: Int
    let bytes: Int64?
    let seconds: Double
}

func measure(_ label: String, _ body: () -> (entries: Int, bytes: Int64?)) -> Measurement {
    let start = Date()
    let result = body()
    return Measurement(label: label, entries: result.entries, bytes: result.bytes, seconds: Date().timeIntervalSince(start))
}

func print(_ measurement: Measurement) {
    var line = measurement.label.padding(toLength: 34, withPad: " ", startingAt: 0)
    line += String(format: "%9d entries  %8.3f s", measurement.entries, measurement.seconds)
    if let bytes = measurement.bytes {
        line += String(format: "  %15lld bytes", bytes)
    }
    Swift.print(line)
}

/// Visible names from readdir. Names are as the file system stores them.
func readdirNames() -> [String] {
    guard let directory = opendir(folder) else { fail("cannot open \(folder): errno \(errno)") }
    defer { closedir(directory) }
    var names: [String] = []
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen)) { String(cString: $0) }
        }
        if name != "." && name != ".." && !name.hasPrefix(".") { names.append(name) }
    }
    return names
}

func readdirMeasurement() -> Measurement {
    measure("readdir (names)") { (readdirNames().count, nil) }
}

/// One getattrlistbulk pass. Visible entries are counted; the byte total covers visible regular files.
func bulkMeasurement() -> Measurement {
    measure("getattrlistbulk") {
        let fd = open(folder, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { fail("cannot open \(folder): errno \(errno)") }
        defer { close(fd) }

        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
        attributes.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        let regularType = UInt32(VREG.rawValue)
        var count = 0
        var totalBytes: Int64 = 0
        while true {
            let returned = getattrlistbulk(fd, &attributes, buffer, bufferSize, 0)
            if returned < 0 { fail("getattrlistbulk failed: errno \(errno)") }
            if returned == 0 { break }

            var record = buffer
            for _ in 0..<Int(returned) {
                let length = Int(record.loadUnaligned(as: UInt32.self))
                var cursor = record + MemoryLayout<UInt32>.size
                let returnedSets = cursor.loadUnaligned(as: attribute_set_t.self)
                cursor += MemoryLayout<attribute_set_t>.size
                let nameReference = cursor
                let nameInfo = nameReference.loadUnaligned(as: attrreference_t.self)
                let namePointer = nameReference + Int(nameInfo.attr_dataoffset)
                cursor += MemoryLayout<attrreference_t>.size
                let name = String(cString: namePointer.assumingMemoryBound(to: CChar.self))
                let type = cursor.loadUnaligned(as: UInt32.self)
                cursor += MemoryLayout<UInt32>.size
                cursor += MemoryLayout<timespec>.size
                if returnedSets.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0, type == regularType {
                    totalBytes += cursor.loadUnaligned(as: Int64.self)
                }
                if !name.hasPrefix(".") { count += 1 }
                record += length
            }
        }
        return (count, totalBytes)
    }
}

/// FileManager listing with keys, the way DriveInventory listed before R2.
func fileManagerMeasurement() -> Measurement {
    measure("FileManager + resourceValues") {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .contentModificationDateKey]
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { fail("contentsOfDirectory failed for \(folder)") }
        var regularBytes: Int64 = 0
        var count = 0
        for child in children {
            count += 1
            if let values = try? child.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                regularBytes += Int64(values.fileSize ?? 0)
            }
        }
        return (count, regularBytes)
    }
}

/// lstat of each name, cold. Byte total covers regular files.
func lstatMeasurement(label: String, names: [String]) -> Measurement {
    measure(label) {
        var status = stat()
        var count = 0
        var totalBytes: Int64 = 0
        for name in names {
            guard lstat(folder + "/" + name, &status) == 0 else { continue }
            count += 1
            if status.st_mode & S_IFMT == S_IFREG { totalBytes += Int64(status.st_size) }
        }
        return (count, totalBytes)
    }
}

let visibleNames = readdirNames()

switch mode {
case "all":
    let readdir = readdirMeasurement()
    let bulk = bulkMeasurement()
    let fileManager = fileManagerMeasurement()
    let statAll = lstatMeasurement(label: "lstat (all visible)", names: visibleNames)
    for measurement in [readdir, bulk, fileManager, statAll] { print(measurement) }
    let countsMatch = readdir.entries == bulk.entries && bulk.entries == fileManager.entries
    let bytesMatch = bulk.bytes == statAll.bytes
    Swift.print("visible count equal across methods: \(countsMatch ? "yes" : "NO")")
    Swift.print("bulk bytes equal lstat sum: \(bytesMatch ? "yes" : "NO")")
    if !countsMatch || !bytesMatch { exit(2) }
case "readdir":
    print(readdirMeasurement())
case "bulk":
    print(bulkMeasurement())
case "fm":
    print(fileManagerMeasurement())
case "statall":
    print(lstatMeasurement(label: "lstat (all visible)", names: visibleNames))
case "lstat":
    print(lstatMeasurement(label: "lstat (first N)", names: Array(visibleNames.prefix(limit))))
case "lstatlast":
    print(lstatMeasurement(label: "lstat (last N)", names: Array(visibleNames.suffix(limit))))
default:
    fail("unknown mode \(mode)")
}
