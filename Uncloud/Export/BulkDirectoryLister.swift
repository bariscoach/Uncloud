import Darwin
import Foundation

/// Lists one folder with `getattrlistbulk`: names, kinds, sizes, modification times and hidden flags in one pass over
/// the folder.
///
/// Why this exists: on exFAT (the FSKit driver used by the owner's USB drive), looking up a name scans the folder in a
/// straight line, so `FileManager.contentsOfDirectory(includingPropertiesForKeys:)` plus `resourceValues` costs time in
/// proportion to the square of the folder's size. One bulk pass reads the same information in linear time.
///
/// The listing includes every entry (hidden files and folders too). Callers filter what they need; `isHidden` is the
/// `UF_HIDDEN` flag, which is what `.skipsHiddenFiles` honored.
enum BulkDirectoryLister {
    struct Entry: Equatable, Sendable {
        let name: String
        let kind: Kind
        /// The data fork's logical length, for `.file` entries. Zero for every other kind.
        let size: Int64
        /// Modification time in seconds since 1970, with nanoseconds.
        let modified: Double
        /// The `UF_HIDDEN` flag.
        let isHidden: Bool
    }

    enum Kind: Sendable {
        case file
        case directory
        case symlink
        case other
    }

    /// The buffer size for one `getattrlistbulk` call. It holds a few thousand typical entries per call.
    static let bufferSize = 256 * 1024

    /// Every entry of `folder`, in the order the file system returns them.
    ///
    /// Throws the POSIX error when the folder can't be opened or read (for example a missing folder, or EACCES).
    /// Falls back to a `FileManager` listing when the volume doesn't support `getattrlistbulk` (ENOTSUP or EINVAL on
    /// the first call). EINTR retries the call. Entries that report a per-entry error are skipped. Cancelling the
    /// calling task stops the listing between buffers.
    static func list(_ folder: URL) throws -> [Entry] {
        let fd = open(folder.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw posixError(errno) }
        defer { close(fd) }

        var attributes = requestedAttributes()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var entries: [Entry] = []
        var isFirstCall = true
        while true {
            try Task.checkCancellation()
            let returned = getattrlistbulk(fd, &attributes, buffer, bufferSize, 0)
            if returned < 0 {
                let code = errno
                if code == EINTR { continue }
                if isFirstCall, code == ENOTSUP || code == EINVAL {
                    return try fileManagerListing(folder)
                }
                throw posixError(code)
            }
            if returned == 0 { break }
            isFirstCall = false

            var offset = 0
            for _ in 0..<Int(returned) {
                // Every record must lie inside the buffer the kernel just filled.
                guard offset + MemoryLayout<UInt32>.size <= bufferSize else { throw posixError(EIO) }
                let record = UnsafeRawPointer(buffer) + offset
                let length = Int(record.loadUnaligned(as: UInt32.self))
                // A record is at least its own length field. Anything smaller would never advance.
                guard length >= MemoryLayout<UInt32>.size, offset + length <= bufferSize else {
                    throw posixError(EIO)
                }
                if let entry = try parse(record, length: length) {
                    entries.append(entry)
                }
                offset += length
            }
        }
        return entries
    }

    // MARK: - getattrlistbulk

    private static func requestedAttributes() -> attrlist {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_FLAGS)
        attributes.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
        return attributes
    }

    /// Parses one record of `length` bytes. The kernel writes the fields in this order, after the length: the
    /// `returned` set, the error code (when asked for), then the common attributes in bit order (name, object type,
    /// modification time, flags), then the file attributes. Each field is read only when its bit is set. Every read is
    /// checked against the record's length, and a field that runs past it is an EIO. Fields are packed on 4-byte
    /// boundaries, so `off_t` and `timespec` may be unaligned; they are read with `loadUnaligned`.
    ///
    /// Returns nil for an entry that can't be listed: one with a non-zero error code, one without a name, and `.` and
    /// `..`.
    private static func parse(_ record: UnsafeRawPointer, length: Int) throws -> Entry? {
        var position = MemoryLayout<UInt32>.size
        func take(_ size: Int) throws -> Int {
            guard position + size <= length else { throw posixError(EIO) }
            let start = position
            position += size
            return start
        }

        let returned = (record + (try take(MemoryLayout<attribute_set_t>.size)))
            .loadUnaligned(as: attribute_set_t.self)

        if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            let errorCode = (record + (try take(MemoryLayout<UInt32>.size))).loadUnaligned(as: UInt32.self)
            if errorCode != 0 { return nil }
        }

        // Name: an attrreference whose data offset is relative to the reference itself.
        guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { return nil }
        let referenceStart = try take(MemoryLayout<attrreference_t>.size)
        let reference = (record + referenceStart).loadUnaligned(as: attrreference_t.self)
        let nameOffset = referenceStart + Int(reference.attr_dataoffset)
        // attr_length includes the terminating NUL; the name, with its NUL, must lie inside the record.
        let nameBytes = Int(reference.attr_length)
        guard nameOffset >= 0, nameBytes >= 1, nameOffset + nameBytes <= length else { throw posixError(EIO) }
        // Invalid UTF-8 bytes decode to U+FFFD, so such a name won't round-trip. FileManager does the same.
        let name = String(
            decoding: UnsafeRawBufferPointer(start: record + nameOffset, count: nameBytes - 1),
            as: UTF8.self
        )
        // The kernel doesn't list these, but readdir does, so a listing must not depend on that.
        guard name != ".", name != ".." else { return nil }

        var typeValue: UInt32 = UInt32(VNON.rawValue)
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            typeValue = (record + (try take(MemoryLayout<UInt32>.size))).loadUnaligned(as: UInt32.self)
        }

        var modified: Double = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            let time = (record + (try take(MemoryLayout<timespec>.size))).loadUnaligned(as: timespec.self)
            modified = modificationSeconds(time)
        }

        var isHidden = false
        if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            let flags = (record + (try take(MemoryLayout<UInt32>.size))).loadUnaligned(as: UInt32.self)
            isHidden = flags & UInt32(UF_HIDDEN) != 0
        }

        var size: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            size = (record + (try take(MemoryLayout<Int64>.size))).loadUnaligned(as: Int64.self)
        }

        let kind = kind(forVnodeType: typeValue)
        return Entry(
            name: name,
            kind: kind,
            size: kind == .file ? size : 0,
            modified: modified,
            isHidden: isHidden
        )
    }

    /// Seconds since 1970 for a timespec, computed the way Foundation does it: seconds since 2001 first, then back to
    /// 1970. That gives the same Double bit for bit as `URLResourceValues.contentModificationDate`'s
    /// `timeIntervalSince1970`, which matters because Browse and the drive snapshot compare these values exactly.
    /// (Checked against FileManager on 3,000 random timestamps with nanoseconds.)
    static func modificationSeconds(_ time: timespec) -> Double {
        let secondsSince2001 = Double(time.tv_sec - 978_307_200) + Double(time.tv_nsec) / 1_000_000_000
        return secondsSince2001 + 978_307_200
    }

    private static func kind(forVnodeType type: UInt32) -> Kind {
        switch type {
        case UInt32(VREG.rawValue): return .file
        case UInt32(VDIR.rawValue): return .directory
        case UInt32(VLNK.rawValue): return .symlink
        default: return .other
        }
    }

    private static func posixError(_ code: Int32) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    // MARK: - Fallback

    /// The listing `FileManager` gives, used on volumes without `getattrlistbulk`. Same fields and rules as the bulk
    /// pass. A child that disappears while the folder is being listed is skipped.
    /// Exposed to the tests, which compare it with the bulk pass. Foundation omits AppleDouble `._` files on some
    /// volumes, so this listing can have fewer entries than the bulk pass. Callers skip dot-names either way.
    static func fileManagerListing(_ folder: URL) throws -> [Entry] {
        let keys: [URLResourceKey] = [
            .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            .isHiddenKey,
        ]
        let children = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: []
        )
        return children.compactMap { child in
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { return nil }
            let kind: Kind
            if values.isSymbolicLink == true {
                kind = .symlink
            } else if values.isDirectory == true {
                kind = .directory
            } else if values.isRegularFile == true {
                kind = .file
            } else {
                kind = .other
            }
            return Entry(
                name: child.lastPathComponent,
                kind: kind,
                size: kind == .file ? Int64(values.fileSize ?? 0) : 0,
                modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                // FileManager's isHidden also covers dot-names; the bulk pass reports only the flag. Dot-names are
                // skipped by every caller, so for the others the two agree.
                isHidden: (values.isHidden ?? false) && !child.lastPathComponent.hasPrefix(".")
            )
        }
    }
}
