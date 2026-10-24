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
        sidecar(for: mediaName, in: Index(jsonNames: jsonNames, mediaNames: mediaNames))
    }

    /// The names of one folder, indexed for matching. Build it once per folder and match every file in it against it:
    /// a folder of thousands of photos then costs a few lookups per file, not a pass over every name.
    struct Index: Sendable {
        fileprivate struct Sidecar: Sendable {
            let name: String
            let counter: String?
        }

        /// Sidecars keyed by their stem: the name without `.json`, and without a duplicate counter.
        fileprivate let sidecarsByStem: [String: [Sidecar]]
        /// Media names keyed by their stem: the name without its extension.
        fileprivate let mediaByStem: [String: [String]]

        init(jsonNames: Set<String>, mediaNames: Set<String>) {
            var sidecars: [String: [Sidecar]] = [:]
            for json in jsonNames where json.hasSuffix(".json") && !TakeoutSidecarMatcher.isAlbumMetadata(json) {
                let (stem, counter) = TakeoutSidecarMatcher.splitCounter(String(json.dropLast(".json".count)))
                sidecars[stem, default: []].append(Sidecar(name: json, counter: counter))
            }
            var media: [String: [String]] = [:]
            for name in mediaNames {
                media[TakeoutSidecarMatcher.splitExtension(name).stem, default: []].append(name)
            }
            sidecarsByStem = sidecars
            mediaByStem = media
        }
    }

    /// The sidecar name for `mediaName` among the folder's names in `index`, or nil.
    static func sidecar(for mediaName: String, in index: Index) -> String? {
        let (stem, ext) = splitExtension(mediaName)
        let (unCountedStem, counter) = splitCounter(stem)
        // Rule 2: an edited copy shares the sidecar of the original.
        var baseStem = unCountedStem
        if baseStem.hasSuffix(edited), baseStem.count > edited.count {
            baseStem.removeLast(edited.count)
        }
        let name = ext.map { baseStem + "." + $0 } ?? baseStem

        if let match = matchJSON(name: name, counter: counter, in: index) {
            return match
        }

        // Rule 4: a live-photo movie uses the sidecar of an image with the same stem. The first such image, by name,
        // whose sidecar matches wins.
        guard let ext, movieExtensions.contains(ext.lowercased()) else { return nil }
        for sibling in (index.mediaByStem[stem] ?? []).sorted() {
            let (_, siblingExt) = splitExtension(sibling)
            guard let siblingExt, imageExtensions.contains(siblingExt.lowercased()) else { continue }
            if let match = sidecar(for: sibling, in: index) {
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
    private static func matchJSON(name: String, counter: String?, in index: Index) -> String? {
        // Only a stem that is a prefix of `name + supplemental` can match, so those are the only lookups made.
        let target = name + supplemental
        var fallback: String?
        var stem = ""
        for character in target {
            stem.append(character)
            for sidecar in index.sidecarsByStem[stem] ?? [] where sidecar.counter == counter {
                if stem == name {
                    return sidecar.name
                }
                if stem.count >= name.count || sidecar.name.count >= truncatedMinLength {
                    // The first such name in sorted order, as before.
                    fallback = min(fallback ?? sidecar.name, sidecar.name)
                }
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
