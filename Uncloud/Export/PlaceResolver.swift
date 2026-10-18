import CoreLocation
import Foundation
import MapKit

enum PlaceLookupError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Place names couldn’t be looked up. Check your internet connection, then choose Resume."
    }
}

/// Turns photo coordinates into `Country/City` folder names.
///
/// Coordinates are grouped into cells of about 10 km so nearby photos share
/// one lookup, and results are cached on disk across runs.
actor PlaceResolver {
    struct Place: Codable, Sendable {
        var country: String?
        var city: String?

        var folderPath: String {
            let parts = [country, city].compactMap { $0.map(Self.sanitized) }.filter { !$0.isEmpty }
            return parts.isEmpty ? PlaceResolver.unknownFolder : parts.joined(separator: "/")
        }

        private static func sanitized(_ name: String) -> String {
            name.components(separatedBy: .controlCharacters).joined(separator: " ")
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        }
    }

    static let unknownFolder = "Unknown Location"
    private static let maxAttempts = 7

    private let cacheURL: URL?
    private var cache: [String: Place]

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        // Names are localized, so keep one cache per language.
        cacheURL = directory?.appending(path: "PlaceCache-\(Locale.current.identifier).json")
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode([String: Place].self, from: data) {
            self.cache = cache
        } else {
            cache = [:]
        }
    }

    /// Returns a folder path such as `Italy/Rome`, waiting out rate limits as needed.
    func folderPath(
        latitude: Double,
        longitude: Double,
        onWait: @Sendable (Duration) -> Void
    ) async throws -> String {
        try await place(latitude: latitude, longitude: longitude, onWait: onWait).folderPath
    }

    /// The country and city at the coordinates, cached like `folderPath`. Browse Backup reads names through this;
    /// an empty place means the coordinates have no address.
    func place(
        latitude: Double,
        longitude: Double,
        onWait: @Sendable (Duration) -> Void
    ) async throws -> Place {
        let key = Self.cellKey(latitude: latitude, longitude: longitude)
        if let place = cache[key] {
            return place
        }

        var delay = Duration.seconds(2)
        for attempt in 1...Self.maxAttempts {
            try Task.checkCancellation()
            do {
                let place = try await Self.lookUp(latitude: latitude, longitude: longitude)
                cache[key] = place
                saveCache()
                return place
            } catch where Self.isNotFound(error) {
                cache[key] = Place()
                saveCache()
                return Place()
            } catch {
                guard attempt < Self.maxAttempts else { break }
                onWait(delay)
                try await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(60))
            }
        }
        throw PlaceLookupError.unavailable
    }

    /// The ~10 km cell a coordinate falls in. Browse Backup groups photos by the same key.
    static func cellKey(latitude: Double, longitude: Double) -> String {
        String(format: "%.1f,%.1f", latitude, longitude)
    }

    private func saveCache() {
        guard let cacheURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    @MainActor
    private static func lookUp(latitude: Double, longitude: Double) async throws -> Place {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        if #available(macOS 26, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { return Place() }
            let address = try await request.mapItems.first?.addressRepresentations
            return Place(country: address?.regionName, city: address?.cityName)
        } else {
            let placemark = try await CLGeocoder().reverseGeocodeLocation(location).first
            return Place(
                country: placemark?.country,
                city: placemark?.locality ?? placemark?.subAdministrativeArea ?? placemark?.administrativeArea
            )
        }
    }

    /// The location has no address (open sea, for example), so retrying won't help.
    private static func isNotFound(_ error: any Error) -> Bool {
        let error = error as NSError
        return (error.domain == MKErrorDomain && error.code == Int(MKError.placemarkNotFound.rawValue))
            || (error.domain == kCLErrorDomain && error.code == CLError.geocodeFoundNoResult.rawValue)
    }
}
