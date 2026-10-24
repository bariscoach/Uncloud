import Foundation

/// Finds the Takeout JSON sidecar for a media file. Works on file names within one folder, not on file contents.
enum TakeoutSidecarMatcher {
    private static let supplemental = ".supplemental-metadata"
    private static let edited = "-edited"
    /// Google cuts sidecar names to 51 characters, counting `.json`. Shorter names are not truncations.
    private static let truncatedMinLength = 46
    private static let movieExtensions: Set<String> = ["mp4", "mov"]
    private static let imageExtensions: Set<String> = [
        "heic", "heif", "jpg", "jpeg", "png", "gif", "webp", "dng", "tif", "tiff",
    ]

    /// The sidecar name for `mediaName`, or nil. `jsonNames` and `mediaNames` are the names in the same folder.
    /// `mediaNames` is only used for live-photo movies, which fall back to a same-stem image's sidecar.
    static func sidecar(for mediaName: String, among jsonNames: Set<String>, siblings mediaNames: Set<String> = []) -> String? {
        let (stem, ext) = splitExtension(mediaName)
        let (unCountedStem, counter) = splitCounter(stem)
        // Rule 2: an edited copy shares the sidecar of the original.
        var baseStem = unCountedStem
        if baseStem.hasSuffix(edited), baseStem.count > edited.count {
            baseStem.removeLast(edited.count)
        }
        let name = ext.map { baseStem + "." + $0 } ?? baseStem

        if let match = matchJSON(name: name, counter: counter, among: jsonNames) {
            return match
        }

        // Rule 4: a live-photo movie uses the sidecar of an image with the same stem.
        guard let ext, movieExtensions.contains(ext.lowercased()) else { return nil }
        for sibling in mediaNames.sorted() {
            let (siblingStem, siblingExt) = splitExtension(sibling)
            guard siblingStem == stem, let siblingExt, imageExtensions.contains(siblingExt.lowercased()) else { continue }
            if let match = sidecar(for: sibling, among: jsonNames) {
                return match
            }
        }
        return nil
    }

    /// True for Takeout's per-album `metadata.json`, which describes an album rather than a photo.
    static func isAlbumMetadata(_ jsonName: String) -> Bool {
        jsonName == "metadata.json"
    }

    /// Rule 3. An exact name beats a `.supplemental-metadata` sidecar, and the counters must agree.
    private static func matchJSON(name: String, counter: String?, among jsonNames: Set<String>) -> String? {
        let target = name + supplemental
        var fallback: String?
        for json in jsonNames.sorted() where json.hasSuffix(".json") && !isAlbumMetadata(json) {
            let (stem, jsonCounter) = splitCounter(String(json.dropLast(".json".count)))
            guard jsonCounter == counter, target.hasPrefix(stem) else { continue }
            if stem == name {
                return json
            }
            if stem.count >= name.count || json.count >= truncatedMinLength {
                fallback = fallback ?? json
            }
        }
        return fallback
    }

    /// Splits `IMG_1.JPG` into `IMG_1` and `JPG`. The extension is nil when there is none.
    private static func splitExtension(_ name: String) -> (stem: String, ext: String?) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, nil) }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// Splits a trailing duplicate counter: `IMG_1(1)` into `IMG_1` and `1`.
    private static func splitCounter(_ text: String) -> (String, String?) {
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return (text, nil) }
        let digits = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return (text, nil) }
        return (String(text[..<open]), String(digits))
    }
}
