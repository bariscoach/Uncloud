import Foundation

/// Classifies an AppleDouble companion (`._NAME`): the header macOS writes next to a file on a volume without native
/// extended attributes, such as exFAT or FAT. Only a companion that provably holds nothing but the quarantine flag,
/// or nothing at all, may be deleted. Anything else is `keep`, including any byte the parser does not account for.
enum AppleDouble {
    enum Verdict: Equatable, Sendable {
        /// Holds only attributes in `deletableAttributes`. Safe to delete.
        case quarantineOnly
        /// Valid header, zero Finder info, no resource fork data, no attributes. Safe to delete.
        case empty
        /// Anything else: other attributes, Finder info, resource fork data, or malformed bytes.
        case keep(reason: String)
    }

    /// The only attribute a companion may carry and still be deleted.
    static let deletableAttributes: Set<String> = ["com.apple.quarantine"]

    /// Companions larger than this are never classified as deletable.
    static let maxCompanionBytes = 65_536

    struct Attribute: Equatable, Sendable {
        let name: String
        /// Where the value sits in the file, and how long it runs.
        let offset: Int
        let length: Int
    }

    /// The structure of a companion whose bytes all parse. Policy (what may be deleted) is applied on top of it.
    struct Layout: Equatable, Sendable {
        /// The 32 Finder info bytes.
        var finderInfo: [UInt8]
        /// Length of the resource fork entry (ID 2), or nil when it is absent.
        var resourceForkLength: Int?
        /// Attributes in the order the file lists them. Empty when the Finder info entry has no attribute block.
        var attributes: [Attribute]
    }

    static func classify(_ data: Data) -> Verdict {
        let layout: Layout
        switch parse(data) {
        case .failure(let malformed):
            return .keep(reason: malformed.reason)
        case .success(let parsed):
            layout = parsed
        }
        if layout.finderInfo.contains(where: { $0 != 0 }) {
            return .keep(reason: "Finder info is set")
        }
        if let forkLength = layout.resourceForkLength, forkLength != 0 {
            return .keep(reason: "resource fork holds \(forkLength) bytes")
        }
        if layout.attributes.isEmpty {
            return .empty
        }
        if let other = layout.attributes.first(where: { !deletableAttributes.contains($0.name) }) {
            return .keep(reason: "attribute \(other.name)")
        }
        return .quarantineOnly
    }

    /// The attribute names in the file, in order, for logs and histograms. Nil when the bytes don't parse.
    /// Reports names whatever their policy, so a file that `classify` keeps still shows what it holds.
    static func attributeNames(_ data: Data) -> [String]? {
        guard case .success(let layout) = parse(data) else { return nil }
        return layout.attributes.map(\.name)
    }

    // MARK: - Parsing

    private struct Malformed: Error {
        let reason: String
    }

    private static let magic: UInt32 = 0x0005_1607
    private static let version: UInt32 = 0x0002_0000
    private static let headerSize = 26
    private static let entrySize = 12
    private static let finderInfoEntryID: UInt32 = 9
    private static let resourceForkEntryID: UInt32 = 2
    private static let finderInfoLength = 32
    /// Within the Finder info entry: 32 bytes of Finder info, then 2 pad bytes, then the attribute header.
    private static let attributeHeaderOffset = 34
    private static let attributeMagic: UInt32 = 0x4154_5452 // 'ATTR'
    private static let attributeHeaderSize = 36
    /// Fixed part of an attribute entry: offset, length, flags, name length. The name follows.
    private static let attributeEntryFixedSize = 11
    private static let maxAttributes = 64

    private static func parse(_ data: Data) -> Result<Layout, Malformed> {
        let bytes = [UInt8](data)
        guard bytes.count <= maxCompanionBytes else {
            return .failure(Malformed(reason: "larger than \(maxCompanionBytes) bytes"))
        }
        guard bytes.count >= headerSize else {
            return .failure(Malformed(reason: "shorter than the header"))
        }
        guard u32(bytes, 0) == magic else {
            return .failure(Malformed(reason: "wrong magic"))
        }
        guard u32(bytes, 4) == version else {
            return .failure(Malformed(reason: "wrong version"))
        }
        let entryCount = Int(u16(bytes, 24))
        guard entryCount == 1 || entryCount == 2 else {
            return .failure(Malformed(reason: "\(entryCount) entries"))
        }
        let tableEnd = headerSize + entryCount * entrySize
        guard bytes.count >= tableEnd else {
            return .failure(Malformed(reason: "truncated entry table"))
        }

        var entries: [UInt32: (offset: Int, length: Int)] = [:]
        for index in 0..<entryCount {
            let base = headerSize + index * entrySize
            let id = u32(bytes, base)
            let offset = Int(u32(bytes, base + 4))
            let length = Int(u32(bytes, base + 8))
            guard id == finderInfoEntryID || id == resourceForkEntryID else {
                return .failure(Malformed(reason: "entry \(id) is not Finder info or resource fork"))
            }
            guard entries[id] == nil else {
                return .failure(Malformed(reason: "entry \(id) listed twice"))
            }
            guard offset <= bytes.count, length <= bytes.count - offset else {
                return .failure(Malformed(reason: "entry \(id) lies outside the file"))
            }
            entries[id] = (offset, length)
        }
        guard let finder = entries[finderInfoEntryID] else {
            return .failure(Malformed(reason: "no Finder info entry"))
        }
        guard finder.length >= finderInfoLength else {
            return .failure(Malformed(reason: "Finder info entry shorter than 32 bytes"))
        }

        // Every byte must be explained: the header and entry table, the Finder info, the attribute table and each
        // attribute value are marked. Any other non-zero byte means the file holds something this parser doesn't
        // understand, so it is rejected.
        var covered = [Bool](repeating: false, count: bytes.count)
        mark(0..<tableEnd, in: &covered)
        mark(finder.offset..<(finder.offset + finderInfoLength), in: &covered)
        if let fork = entries[resourceForkEntryID] {
            mark(fork.offset..<(fork.offset + fork.length), in: &covered)
        }

        var attributes: [Attribute] = []
        if finder.length > finderInfoLength {
            let entryEnd = finder.offset + finder.length
            let header = finder.offset + attributeHeaderOffset
            guard header + attributeHeaderSize <= entryEnd else {
                return .failure(Malformed(reason: "Finder info entry too short for an attribute header"))
            }
            guard u32(bytes, header) == attributeMagic else {
                return .failure(Malformed(reason: "no attribute header where Finder info is longer than 32 bytes"))
            }
            let count = Int(u16(bytes, header + 34))
            guard count <= maxAttributes else {
                return .failure(Malformed(reason: "\(count) attributes"))
            }
            mark(header..<(header + attributeHeaderSize), in: &covered)

            var position = header + attributeHeaderSize
            for _ in 0..<count {
                guard position + attributeEntryFixedSize <= entryEnd else {
                    return .failure(Malformed(reason: "attribute table runs past its entry"))
                }
                let valueOffset = Int(u32(bytes, position))
                let valueLength = Int(u32(bytes, position + 4))
                let nameLength = Int(bytes[position + 10])
                let nameStart = position + attributeEntryFixedSize
                guard nameLength >= 2, nameStart + nameLength <= entryEnd else {
                    return .failure(Malformed(reason: "attribute name length \(nameLength) is out of range"))
                }
                guard bytes[nameStart + nameLength - 1] == 0 else {
                    return .failure(Malformed(reason: "attribute name is not NUL-terminated"))
                }
                let nameBytes = bytes[nameStart..<(nameStart + nameLength - 1)]
                guard !nameBytes.contains(0), let name = String(bytes: nameBytes, encoding: .utf8) else {
                    return .failure(Malformed(reason: "attribute name is not a plain UTF-8 string"))
                }
                guard valueOffset <= bytes.count, valueLength <= bytes.count - valueOffset else {
                    return .failure(Malformed(reason: "value of \(name) lies outside the file"))
                }
                attributes.append(Attribute(name: name, offset: valueOffset, length: valueLength))
                mark(valueOffset..<(valueOffset + valueLength), in: &covered)
                mark(position..<(nameStart + nameLength), in: &covered)

                // Entries are padded to a 4-byte boundary. The padding is left unmarked, so it must be zero.
                position = (nameStart + nameLength + 3) & ~3
                guard position <= entryEnd else {
                    return .failure(Malformed(reason: "attribute entry padding runs past its entry"))
                }
            }
        }

        for index in bytes.indices where !covered[index] && bytes[index] != 0 {
            return .failure(Malformed(reason: "unexplained byte at offset \(index)"))
        }

        let finderInfo = Array(bytes[finder.offset..<(finder.offset + finderInfoLength)])
        return .success(Layout(
            finderInfo: finderInfo,
            resourceForkLength: entries[resourceForkEntryID]?.length,
            attributes: attributes
        ))
    }

    private static func mark(_ range: Range<Int>, in covered: inout [Bool]) {
        for index in range {
            covered[index] = true
        }
    }

    /// Big-endian, as XNU writes AppleDouble headers.
    private static func u32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16 | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
    }

    private static func u16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
        UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
    }
}
