import Foundation
import Testing
@testable import Uncloud

@Suite("AppleDouble classifier")
struct AppleDoubleTests {
    /// Loads `Fixtures/AppleDouble/<name>.bin`, the byte-exact companions written by an independent encoder.
    private static func fixture(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AppleDouble/\(name).bin")
        guard let data = try? Data(contentsOf: url) else {
            fatalError("AppleDouble fixture \(name).bin is missing")
        }
        return data
    }

    private static func isKeep(_ verdict: AppleDouble.Verdict) -> Bool {
        if case .keep = verdict { return true }
        return false
    }

    @Test func quarantineOnlyIsDeletable() {
        let data = Self.fixture("quarantine-only")
        #expect(AppleDouble.classify(data) == .quarantineOnly)
        #expect(AppleDouble.attributeNames(data) == ["com.apple.quarantine"])
    }

    @Test func emptyCompanionIsDeletable() {
        let data = Self.fixture("empty")
        #expect(AppleDouble.classify(data) == .empty)
        #expect(AppleDouble.attributeNames(data) == [])
    }

    @Test func everyOtherFixtureIsKept() {
        let kept = [
            "quarantine-provenance",   // quarantine plus a second attribute
            "quarantine-tags",         // quarantine plus Finder tags
            "finder-info-colour",      // a colour label in Finder info, no attributes
            "finder-info-quarantine",  // Finder info plus quarantine
            "resource-fork",           // ten bytes of resource fork
            "truncated",               // cut off inside the attribute table
            "wrong-magic",
            "wrong-version",
            "little-endian",           // every integer field little-endian, so the big-endian magic is wrong
            "name-not-terminated",     // attribute name without its NUL
            "offset-beyond-end",       // attribute value past the end of the file
            "stray-byte",              // one non-zero byte no structure explains
            "no-finder-entry",         // resource fork entry only
        ]
        for name in kept {
            let verdict = AppleDouble.classify(Self.fixture(name))
            #expect(Self.isKeep(verdict), "\(name) should be kept, got \(verdict)")
        }
    }

    @Test func keptReasonsNameTheCause() {
        #expect(AppleDouble.classify(Self.fixture("finder-info-colour")) == .keep(reason: "Finder info is set"))
        #expect(AppleDouble.classify(Self.fixture("resource-fork"))
            == .keep(reason: "resource fork holds 10 bytes"))
        #expect(AppleDouble.classify(Self.fixture("quarantine-provenance"))
            == .keep(reason: "attribute com.apple.provenance"))
        #expect(AppleDouble.classify(Self.fixture("wrong-magic")) == .keep(reason: "wrong magic"))
    }

    @Test func attributeNamesListEveryAttributeInOrder() {
        #expect(AppleDouble.attributeNames(Self.fixture("quarantine-provenance"))
            == ["com.apple.quarantine", "com.apple.provenance"])
        #expect(AppleDouble.attributeNames(Self.fixture("quarantine-tags"))
            == ["com.apple.quarantine", "com.apple.metadata:_kMDItemUserTags"])
        #expect(AppleDouble.attributeNames(Self.fixture("finder-info-colour")) == [])
    }

    @Test func malformedBytesHaveNoAttributeNames() {
        #expect(AppleDouble.attributeNames(Self.fixture("wrong-magic")) == nil)
        #expect(AppleDouble.attributeNames(Self.fixture("little-endian")) == nil)
        #expect(AppleDouble.attributeNames(Self.fixture("truncated")) == nil)
        #expect(AppleDouble.attributeNames(Data()) == nil)
    }

    @Test func everyTruncationOfTheDeletableFileIsKept() {
        let full = Self.fixture("quarantine-only")
        for length in 0..<full.count {
            let verdict = AppleDouble.classify(full.prefix(length))
            #expect(Self.isKeep(verdict), "a \(length)-byte prefix must be kept, got \(verdict)")
        }
    }

    @Test func everySingleByteChangeNeverMakesAnUnknownFileDeletable() {
        // A changed byte may still be a valid quarantine-only file (for example, a different value byte). The
        // invariant is that a deletable verdict only ever comes with the quarantine attribute as the one attribute.
        let full = Self.fixture("quarantine-only")
        for index in full.indices {
            var changed = full
            changed[index] ^= 0xFF
            switch AppleDouble.classify(changed) {
            case .quarantineOnly:
                #expect(AppleDouble.attributeNames(changed) == ["com.apple.quarantine"], "byte \(index)")
            case .empty:
                #expect(AppleDouble.attributeNames(changed) == [], "byte \(index)")
            case .keep:
                break
            }
        }
    }

    @Test func sizeCapIsEnforced() {
        var padded = Self.fixture("quarantine-only")
        // Trailing zero bytes are unexplained but harmless, so the file stays deletable right up to the cap.
        padded.append(Data(count: AppleDouble.maxCompanionBytes - padded.count))
        #expect(padded.count == AppleDouble.maxCompanionBytes)
        #expect(AppleDouble.classify(padded) == .quarantineOnly)

        padded.append(0)
        #expect(Self.isKeep(AppleDouble.classify(padded)))
    }

    @Test func trailingNonZeroByteIsKept() {
        var data = Self.fixture("quarantine-only")
        data.append(0x01)
        #expect(Self.isKeep(AppleDouble.classify(data)))
    }

    @Test func deletableAttributesHoldOnlyQuarantine() {
        #expect(AppleDouble.deletableAttributes == ["com.apple.quarantine"])
    }
}
