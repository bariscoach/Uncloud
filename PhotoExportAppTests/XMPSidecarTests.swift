import Foundation
import Testing
@testable import PhotoExportApp

@Suite("XMPSidecar")
struct XMPSidecarTests {
    private static let full = AssetMetadata(
        localIdentifier: "full",
        creationDate: ISO8601DateFormatter().date(from: "2024-07-14T16:03:22Z"),
        modificationDate: ISO8601DateFormatter().date(from: "2024-07-15T09:00:00Z"),
        latitude: 41.8902,
        longitude: -12.4922,
        altitude: -12.345,
        isFavorite: true,
        isHidden: true,
        albums: ["Family", "Trips/Rome & \"Co\" <2024>"]
    )

    private static let minimal = AssetMetadata(
        localIdentifier: "minimal",
        creationDate: nil,
        modificationDate: nil,
        latitude: nil,
        longitude: nil,
        altitude: nil,
        isFavorite: false,
        isHidden: false,
        albums: []
    )

    /// Runs `xmllint --noout` on the text. Returns nil when xmllint can't run here.
    private func xmllintErrors(for xml: String) throws -> String? {
        try withTemporaryDirectory { folder in
            let file = try writeFile(xml, to: "sidecar.xmp", in: folder)
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xmllint")
            process.arguments = ["--noout", file.path(percentEncoded: false)]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = Pipe()
            do {
                try process.run()
            } catch {
                return nil
            }
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return process.terminationStatus == 0 ? "" : text
        }
    }

    @Test func fullMetadataIsWellFormedXML() throws {
        let xml = XMPSidecar.xml(for: Self.full)
        let parser = XMLParser(data: Data(xml.utf8))
        #expect(parser.parse(), "XMLParser: \(parser.parserError?.localizedDescription ?? "")")
        if let errors = try xmllintErrors(for: xml) {
            #expect(errors.isEmpty, "xmllint: \(errors)")
        }
    }

    @Test func minimalMetadataIsWellFormedXML() throws {
        let xml = XMPSidecar.xml(for: Self.minimal)
        let parser = XMLParser(data: Data(xml.utf8))
        #expect(parser.parse())
        if let errors = try xmllintErrors(for: xml) {
            #expect(errors.isEmpty, "xmllint: \(errors)")
        }
    }

    @Test func albumNamesAreEscaped() {
        let xml = XMPSidecar.xml(for: Self.full)
        #expect(xml.contains("&lt;2024&gt;"))
        #expect(xml.contains("&amp;"))
        #expect(!xml.contains("<2024>"))
    }

    @Test func coordinatesAreWrittenWithHemispheres() {
        let xml = XMPSidecar.xml(for: Self.full)
        #expect(xml.contains("N"))
        #expect(xml.contains("W"))
    }

    @Test func minimalMetadataHasNoLocationOrAlbums() {
        let xml = XMPSidecar.xml(for: Self.minimal)
        #expect(!xml.contains("GPS"))
        #expect(!xml.contains("<rdf:li>"))
    }

    @Test func sidecarNameReplacesThePhotoExtension() {
        withTemporaryDirectory { folder in
            let photo = folder.appending(path: "IMG_0001.HEIC")
            #expect(XMPSidecar.sidecarURL(for: photo).lastPathComponent == "IMG_0001.xmp")
        }
    }

    @Test func siblingWithTheSameNameKeepsItsSidecar() throws {
        try withTemporaryDirectory { folder in
            // IMG_0001.JPG and IMG_0001.HEIC share a stem. The first one's sidecar must not be overwritten.
            let heic = folder.appending(path: "IMG_0001.HEIC")
            let jpg = folder.appending(path: "IMG_0001.JPG")
            try writeFile("first", to: "IMG_0001.xmp", in: folder)
            #expect(XMPSidecar.sidecarURL(for: jpg).lastPathComponent == "IMG_0001.JPG.xmp")
            #expect(XMPSidecar.sidecarURL(for: heic).lastPathComponent == "IMG_0001.HEIC.xmp")
            _ = try XMPSidecar.write(Self.minimal, nextTo: jpg)
            #expect(try String(contentsOf: folder.appending(path: "IMG_0001.xmp"), encoding: .utf8) == "first")
        }
    }

    @Test func writeReplacesAnExistingSidecar() throws {
        try withTemporaryDirectory { folder in
            let photo = folder.appending(path: "IMG_0001.HEIC")
            try writeFile("stale", to: "IMG_0001.xmp", in: folder)
            let url = try XMPSidecar.write(Self.minimal, nextTo: photo)
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text == XMPSidecar.xml(for: Self.minimal))
        }
    }
}
