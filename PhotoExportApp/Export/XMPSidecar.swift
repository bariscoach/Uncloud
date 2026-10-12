import Foundation

enum XMPSidecar {
    static func xml(for metadata: AssetMetadata) -> String {
        let namespaces = [
            ("xmlns:xmp", "http://ns.adobe.com/xap/1.0/"),
            ("xmlns:dc", "http://purl.org/dc/elements/1.1/"),
            ("xmlns:photoshop", "http://ns.adobe.com/photoshop/1.0/"),
            ("xmlns:exif", "http://ns.adobe.com/exif/1.0/"),
            ("xmlns:lr", "http://ns.adobe.com/lightroom/1.0/"),
        ]

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current

        var attributes: [(String, String)] = []
        if let date = metadata.creationDate {
            let value = formatter.string(from: date)
            attributes.append(("xmp:CreateDate", value))
            attributes.append(("photoshop:DateCreated", value))
        }
        if let date = metadata.modificationDate {
            attributes.append(("xmp:ModifyDate", formatter.string(from: date)))
        }
        if metadata.isFavorite {
            attributes.append(("xmp:Rating", "5"))
        }
        if let latitude = metadata.latitude, let longitude = metadata.longitude,
           latitude.isFinite, longitude.isFinite {
            attributes.append(("exif:GPSLatitude", gpsCoordinate(latitude, positive: "N", negative: "S")))
            attributes.append(("exif:GPSLongitude", gpsCoordinate(longitude, positive: "E", negative: "W")))
        }
        if let altitude = metadata.altitude, altitude.isFinite {
            let centimetres = Int((abs(altitude) * 100).rounded())
            attributes.append(("exif:GPSAltitude", "\(centimetres)/100"))
            attributes.append(("exif:GPSAltitudeRef", altitude < 0 && centimetres > 0 ? "1" : "0"))
        }

        var subjects = metadata.albums.map { $0.components(separatedBy: "/").last ?? $0 }
        if metadata.isFavorite {
            subjects.append("Favorite")
        }
        if metadata.isHidden {
            subjects.append("Hidden")
        }
        let hierarchy = metadata.albums.map { "Albums|" + $0.replacingOccurrences(of: "/", with: "|") }

        var description = "  <rdf:Description rdf:about=\"\""
        for (name, value) in namespaces + attributes {
            description += "\n    \(name)=\"\(escape(value))\""
        }
        description += ">"

        var lines: [String] = [
            "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>",
            "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">",
            " <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">",
            description,
        ]
        lines += bag("dc:subject", uniqueInOrder(subjects))
        lines += bag("lr:hierarchicalSubject", uniqueInOrder(hierarchy))
        lines += [
            "  </rdf:Description>",
            " </rdf:RDF>",
            "</x:xmpmeta>",
            "<?xpacket end=\"w\"?>",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// `<stem>.xmp` next to `primaryFile` (IMG_0001.HEIC → IMG_0001.xmp), or `<full filename>.xmp`
    /// (IMG_0001.HEIC.xmp) when that name is taken, so two items sharing a stem don't overwrite each other.
    static func sidecarURL(for primaryFile: URL) -> URL {
        let stemmed = primaryFile.deletingPathExtension().appendingPathExtension("xmp")
        if FileManager.default.fileExists(atPath: stemmed.path(percentEncoded: false)) {
            return primaryFile.appendingPathExtension("xmp")
        }
        return stemmed
    }

    /// Writes the sidecar next to `primaryFile`, replacing an existing one, and returns its URL.
    @discardableResult
    static func write(_ metadata: AssetMetadata, nextTo primaryFile: URL) throws -> URL {
        let url = sidecarURL(for: primaryFile)
        try Data(xml(for: metadata).utf8).write(to: url, options: .atomic)
        return url
    }

    /// Degrees, then decimal minutes to four places, e.g. `41,53.1234N`.
    private static func gpsCoordinate(_ value: Double, positive: String, negative: String) -> String {
        let tenThousandthsOfMinute = Int((abs(value) * 600_000).rounded())
        let degrees = tenThousandthsOfMinute / 600_000
        let remainder = tenThousandthsOfMinute % 600_000
        let minutes = remainder / 10_000
        let fraction = String(remainder % 10_000)
        let paddedFraction = String(repeating: "0", count: 4 - fraction.count) + fraction
        return "\(degrees),\(minutes).\(paddedFraction)\(value < 0 ? negative : positive)"
    }

    private static func bag(_ element: String, _ items: [String]) -> [String] {
        guard !items.isEmpty else { return [] }
        let entries: [String] = items.map { "     <rdf:li>\(escape($0))</rdf:li>" }
        return ["   <\(element)>", "    <rdf:Bag>"] + entries + ["    </rdf:Bag>", "   </\(element)>"]
    }

    private static func uniqueInOrder(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0).inserted }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
