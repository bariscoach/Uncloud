import Foundation

/// The fields Uncloud reads from a Google Takeout JSON sidecar. Unknown keys are ignored, and a field that is
/// missing or malformed reads as nil rather than failing the whole file.
struct TakeoutMetadata: Decodable, Sendable, Equatable {
    var title: String?
    var description: String?
    var photoTakenTime: Timestamp?
    var creationTime: Timestamp?
    var geoData: GeoPoint?
    var geoDataExif: GeoPoint?
    var favorited: Bool?
    var url: String?

    /// A Takeout time: `timestamp` is seconds since 1970, written as a string (numbers are accepted too).
    struct Timestamp: Decodable, Sendable, Equatable {
        var seconds: TimeInterval

        var date: Date { Date(timeIntervalSince1970: seconds) }

        private enum Key: String, CodingKey { case timestamp }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            if let text = try? container.decode(String.self, forKey: .timestamp), let value = TimeInterval(text) {
                seconds = value
            } else {
                seconds = try container.decode(TimeInterval.self, forKey: .timestamp)
            }
        }
    }

    /// A Takeout location. Google writes 0/0 when it has no location, so both values are optional here.
    struct GeoPoint: Decodable, Sendable, Equatable {
        var latitude: Double?
        var longitude: Double?
        var altitude: Double?

        /// True when the point has both coordinates and they are not the 0/0 placeholder.
        var isUsable: Bool {
            guard let latitude, let longitude else { return false }
            return latitude != 0 || longitude != 0
        }
    }

    /// A usable location read from a sidecar.
    struct Coordinate: Sendable, Equatable {
        var latitude: Double
        var longitude: Double
        var altitude: Double?
    }

    /// Parses one sidecar. Returns nil for malformed JSON or a top-level value that is not an object.
    static func parse(_ data: Data) -> TakeoutMetadata? {
        try? JSONDecoder().decode(TakeoutMetadata.self, from: data)
    }

    /// When the photo was taken: `photoTakenTime`, else `creationTime`.
    var takenDate: Date? {
        (photoTakenTime ?? creationTime)?.date
    }

    /// The location to use: `geoData` unless it is 0/0, else `geoDataExif` unless it is 0/0, else nil.
    var coordinate: Coordinate? {
        for point in [geoData, geoDataExif] {
            if let point, point.isUsable, let latitude = point.latitude, let longitude = point.longitude {
                return Coordinate(latitude: latitude, longitude: longitude, altitude: point.altitude)
            }
        }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        photoTakenTime = try? container.decodeIfPresent(Timestamp.self, forKey: .photoTakenTime)
        creationTime = try? container.decodeIfPresent(Timestamp.self, forKey: .creationTime)
        geoData = try? container.decodeIfPresent(GeoPoint.self, forKey: .geoData)
        geoDataExif = try? container.decodeIfPresent(GeoPoint.self, forKey: .geoDataExif)
        favorited = try? container.decodeIfPresent(Bool.self, forKey: .favorited)
        url = try? container.decodeIfPresent(String.self, forKey: .url)
    }

    private enum Key: String, CodingKey {
        case title, description, photoTakenTime, creationTime, geoData, geoDataExif, favorited, url
    }
}
