import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What Browse Backup reads from one file on the drive: where and when it was taken, and the camera. Read-only.
struct BrowseMetadata: Equatable, Sendable {
    var latitude: Double?
    var longitude: Double?
    var date: Date?
    var camera: String?

    var hasLocation: Bool { latitude != nil && longitude != nil }

    /// Reads the file's own metadata: ImageIO for photos (HEIC, JPEG, PNG and RAW), AVFoundation for movies. The
    /// `.xmp` sidecar fills in a missing location or date, since Uncloud writes its GPS values there too.
    static func read(of url: URL) async -> BrowseMetadata {
        var metadata = isMovie(url) ? await movieMetadata(url) : imageMetadata(url)
        if !metadata.hasLocation || metadata.date == nil,
           let sidecar = sidecarURLs(for: url).first(where: { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }),
           let data = try? Data(contentsOf: sidecar), let xmp = BrowseXMP.parse(data) {
            if !metadata.hasLocation, let latitude = xmp.latitude, let longitude = xmp.longitude {
                metadata.latitude = latitude
                metadata.longitude = longitude
            }
            metadata.date = metadata.date ?? xmp.date
        }
        return metadata
    }

    /// The sidecar names XMPSidecar writes, in the order it prefers them: `IMG_0001.xmp`, then `IMG_0001.HEIC.xmp`.
    static func sidecarURLs(for primaryFile: URL) -> [URL] {
        [primaryFile.deletingPathExtension().appendingPathExtension("xmp"), primaryFile.appendingPathExtension("xmp")]
    }

    static func isMovie(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .movie) == true
    }

    // MARK: - Photos

    private static func imageMetadata(_ url: URL) -> BrowseMetadata {
        var metadata = BrowseMetadata()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return metadata
        }
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
           let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            metadata.latitude = signed(latitude, reference: gps[kCGImagePropertyGPSLatitudeRef] as? String, negative: "S")
            metadata.longitude = signed(longitude, reference: gps[kCGImagePropertyGPSLongitudeRef] as? String, negative: "W")
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        metadata.date = exifDate(
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            offset: exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
        )
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        metadata.camera = cameraName(
            make: tiff?[kCGImagePropertyTIFFMake] as? String,
            model: tiff?[kCGImagePropertyTIFFModel] as? String
        )
        return metadata
    }

    /// A GPS value is a positive magnitude with a reference letter. Without a letter, the sign of the value stands.
    static func signed(_ value: Double, reference: String?, negative: String) -> Double {
        guard let reference else { return value }
        return reference.uppercased() == negative ? -abs(value) : abs(value)
    }

    /// EXIF `yyyy:MM:dd HH:mm:ss`, in the offset the camera recorded, or the current time zone when it didn't.
    static func exifDate(_ text: String?, offset: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = offset.flatMap(timeZone(offset:)) ?? .current
        return formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `+02:00` or `-0530`.
    private static func timeZone(offset: String) -> TimeZone? {
        let text = offset.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
        guard text.count == 5, let sign = text.first, sign == "+" || sign == "-",
              let hours = Int(text.dropFirst().prefix(2)), let minutes = Int(text.suffix(2)) else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    /// "Apple iPhone 15" when the model doesn't already name the make.
    static func cameraName(make: String?, model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if model.isEmpty { return make.isEmpty ? nil : make }
        if make.isEmpty || model.localizedCaseInsensitiveContains(make) { return model }
        return make + " " + model
    }

    // MARK: - Movies

    private static func movieMetadata(_ url: URL) async -> BrowseMetadata {
        var metadata = BrowseMetadata()
        let asset = AVURLAsset(url: url)
        // Location is usually in the QuickTime metadata; the common keys are a fallback.
        let items = ((try? await asset.load(.metadata)) ?? []) + ((try? await asset.load(.commonMetadata)) ?? [])
        let locations = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .quickTimeMetadataLocationISO6709)
        if let text = try? await locations.first?.load(.stringValue),
           let coordinate = parseISO6709(text) {
            metadata.latitude = coordinate.latitude
            metadata.longitude = coordinate.longitude
        }
        let created = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .quickTimeMetadataCreationDate)
        if let value = try? await created.first?.load(.dateValue) {
            metadata.date = value
        }
        return metadata
    }

    /// An ISO 6709 location as QuickTime stores it: signed latitude and longitude, optionally an altitude, then `/`.
    /// `+41.9028+012.4964+050.000/` gives 41.9028, 12.4964. Nil for anything else.
    static func parseISO6709(_ text: String) -> (latitude: Double, longitude: Double)? {
        var body = Substring(text.trimmingCharacters(in: .whitespaces))
        if body.hasSuffix("/") { body = body.dropLast() }
        // Each field starts with its sign, so a sign after the first character starts the next field.
        var fields: [Substring] = []
        var start = body.startIndex
        for index in body.indices where index != body.startIndex && (body[index] == "+" || body[index] == "-") {
            fields.append(body[start..<index])
            start = index
        }
        if start != body.endIndex { fields.append(body[start...]) }
        guard fields.count >= 2, fields.allSatisfy({ $0.first == "+" || $0.first == "-" }),
              let latitude = Double(fields[0]), let longitude = Double(fields[1]),
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return (latitude, longitude)
    }
}

/// The fields Browse Backup reads from an `.xmp` sidecar: the GPS values and dates that `XMPSidecar` writes.
enum BrowseXMP {
    struct Values: Equatable, Sendable {
        var latitude: Double?
        var longitude: Double?
        var date: Date?
    }

    /// Parses the sidecar's `rdf:Description` attributes. Nil when the XML doesn't parse.
    static func parse(_ data: Data) -> Values? {
        let delegate = AttributeReader()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        let attributes = delegate.attributes
        var values = Values()
        if let text = attributes["exif:GPSLatitude"], let latitude = coordinate(text) {
            values.latitude = latitude
        }
        if let text = attributes["exif:GPSLongitude"], let longitude = coordinate(text) {
            values.longitude = longitude
        }
        // Both values or neither: half a location is no location.
        if values.latitude == nil || values.longitude == nil {
            values.latitude = nil
            values.longitude = nil
        }
        let dateText = attributes["xmp:CreateDate"] ?? attributes["photoshop:DateCreated"]
        if let dateText {
            values.date = ISO8601DateFormatter().date(from: dateText)
        }
        return values
    }

    /// `41,53.1234N` (degrees, then decimal minutes, then the hemisphere), as `XMPSidecar` writes it. A plain decimal
    /// with a sign also reads. Nil for anything else.
    static func coordinate(_ text: String) -> Double? {
        var rest = text.trimmingCharacters(in: .whitespaces)
        var sign: Double?
        if let last = rest.last, "NSEW".contains(last) {
            sign = (last == "S" || last == "W") ? -1 : 1
            rest.removeLast()
        }
        let parts = rest.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2, let degrees = Double(parts[0]) else { return nil }
        var magnitude = abs(degrees)
        if parts.count == 2 {
            guard let minutes = Double(parts[1]), minutes >= 0, minutes < 60 else { return nil }
            magnitude += minutes / 60
        }
        let value = (sign ?? (degrees < 0 ? -1 : 1)) * magnitude
        guard abs(value) <= 180 else { return nil }
        return value
    }

    /// Collects the attributes of every element, keeping the first value of each name.
    private final class AttributeReader: NSObject, XMLParserDelegate {
        var attributes: [String: String] = [:]

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            for (name, value) in attributeDict where self.attributes[name] == nil {
                self.attributes[name] = value
            }
        }
    }
}
