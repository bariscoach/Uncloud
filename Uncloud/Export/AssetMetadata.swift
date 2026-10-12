import Photos

/// The library information written to an XMP sidecar.
struct AssetMetadata: Sendable {
    let localIdentifier: String
    let creationDate: Date?
    let modificationDate: Date?
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let isFavorite: Bool
    let isHidden: Bool
    let albums: [String]   // album paths from AlbumIndex, e.g. "Trips/Rome 2024"

    init(
        localIdentifier: String,
        creationDate: Date?,
        modificationDate: Date?,
        latitude: Double?,
        longitude: Double?,
        altitude: Double?,
        isFavorite: Bool,
        isHidden: Bool,
        albums: [String]
    ) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.albums = albums
    }

    init(asset: PHAsset, albums: [String]) {
        localIdentifier = asset.localIdentifier
        creationDate = asset.creationDate
        modificationDate = asset.modificationDate
        latitude = asset.location?.coordinate.latitude
        longitude = asset.location?.coordinate.longitude
        altitude = asset.location?.altitude
        isFavorite = asset.isFavorite
        isHidden = asset.isHidden
        self.albums = albums
    }
}
