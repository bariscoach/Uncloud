import Foundation

/// Plans the move of a flat backup (`All in One Folder`) into `YYYY/MM` folders (R17a). It is pure: it reads the
/// inputs and returns the plan, and it never touches a file. The executor (R17b) carries the plan out.
///
/// Only top-level files that a record lists move. Unrecorded files, dot files such as `.photo-export`, and
/// recorded paths already inside a folder stay where they are.
enum ReorganizePlanner {
    /// A regular file in the root: its size and modification time (seconds since 1970).
    struct RootFile: Equatable, Sendable {
        var size: Int64
        var modified: Double
    }

    struct Input: Sendable {
        /// `exported.tsv`: record key (with its prefix, such as `icloud-id:`) to the relative paths it lists.
        var records: [String: [String]]
        /// Regular files in the root, by name.
        var rootListing: [String: RootFile]
        /// Names already in each target folder (`YYYY/MM` or `Undated`).
        var targetListings: [String: Set<String>]
        /// Catalog or PhotoKit creation dates, by record key. Used for `icloud-id:` items and Photos-library items.
        /// A Photos-library item with no entry here goes to `Undated/`; EXIF is not read here.
        var createdByKey: [String: Date]
        /// The calendar used to pick the month. The app passes `Calendar.current`.
        var calendar: Calendar
    }

    struct Move: Equatable, Sendable {
        /// Position in the plan, in order of the old name.
        var index: Int
        /// The root name before the move.
        var old: String
        /// The relative path after the move, such as `2024/07/IMG_1.HEIC`.
        var new: String
        /// The record key of the item the file belongs to.
        var key: String
    }

    struct Plan: Equatable, Sendable {
        var moves: [Move]
        /// The target folders used, sorted.
        var months: [String]
        /// Files renamed from `S-N.E` (icloudpd's duplicate suffix, where N is the size) to `S.E`.
        var renamedForICloud: Int
        /// Files that couldn't take their plain name and got a size suffix.
        var collisions: Int
        /// Root files that don't move.
        var staying: Int
    }

    static let undatedFolder = "Undated"

    static func plan(_ input: Input) -> Plan {
        var files: [File] = []
        var claimed = Set<String>()
        // Google Takeout files never move: they're claimed first, so no other item takes their names, and they
        // aren't counted as staying either.
        var googleNames = Set<String>()
        for key in input.records.keys where key.hasPrefix(ExportManifest.googleKeyPrefix) {
            for name in input.records[key] ?? [] where input.rootListing[name] != nil {
                googleNames.insert(name)
            }
        }
        claimed.formUnion(googleNames)
        for key in input.records.keys.sorted() where !key.hasPrefix(ExportManifest.googleKeyPrefix) {
            let names = Set(input.records[key] ?? [])
                .filter { isMovable($0, in: input.rootListing) && !claimed.contains($0) }
                .sorted()
            guard !names.isEmpty else { continue }
            claimed.formUnion(names)

            let itemFolder = folder(for: key, names: names, input)
            let base = files.count
            var item = names.map { name in
                File(old: name, key: key, folder: itemFolder, size: input.rootListing[name]?.size ?? 0)
            }
            // A sidecar follows the media file it belongs to: `<oldName>.xmp` or `<oldStem>.xmp`.
            for index in item.indices where isXMP(item[index].old) {
                let sidecar = item[index].old
                let match = item.indices.first { media in
                    !isXMP(item[media].old)
                        && (sidecar == item[media].old + ".xmp" || sidecar == split(item[media].old).stem + ".xmp")
                }
                if let media = match {
                    item[index].sidecarOf = base + media
                    item[index].followsFullName = sidecar == item[media].old + ".xmp"
                }
            }
            files += item
        }

        // Names are assigned in old-name order. Pass A gives each non-sidecar file its plain name, pass B gives each
        // sidecar its media's name, pass C gives size suffixes to the rest, and pass D finishes the sidecars.
        let order = files.indices.sorted { files[$0].old < files[$1].old }
        var taken = input.targetListings
        var assigned = [String?](repeating: nil, count: files.count)
        var suffixed = Set<Int>()

        func isFree(_ folder: String, _ name: String) -> Bool {
            !(taken[folder]?.contains(name) ?? false)
        }
        func assign(_ index: Int, _ name: String) {
            assigned[index] = name
            taken[files[index].folder, default: []].insert(name)
        }

        for index in order where files[index].sidecarOf == nil {
            let name = plainName(files[index])
            if isFree(files[index].folder, name) { assign(index, name) }
        }
        for index in order where assigned[index] == nil {
            guard let media = files[index].sidecarOf, let mediaName = assigned[media] else { continue }
            let name = sidecarName(files[index], mediaNew: mediaName)
            if isFree(files[index].folder, name) { assign(index, name) }
        }
        for index in order where assigned[index] == nil && files[index].sidecarOf == nil {
            let name = firstFreeSuffixed(of: plainName(files[index]), size: files[index].size) {
                isFree(files[index].folder, $0)
            }
            assign(index, name)
            suffixed.insert(index)
        }
        for index in order where assigned[index] == nil {
            guard let media = files[index].sidecarOf, let mediaName = assigned[media] else { continue }
            let base = sidecarName(files[index], mediaNew: mediaName)
            let name = isFree(files[index].folder, base)
                ? base
                : firstFreeSuffixed(of: base, size: files[index].size) { isFree(files[index].folder, $0) }
            assign(index, name)
            if name != base { suffixed.insert(index) }
        }

        var moves: [Move] = []
        var renamed = 0
        for (position, index) in order.enumerated() {
            let file = files[index]
            guard let name = assigned[index] else { continue }
            moves.append(Move(index: position, old: file.old, new: "\(file.folder)/\(name)", key: file.key))
            if let base = iCloudPlainName(file.old, size: file.size), name == base {
                renamed += 1
            }
        }
        let months = Set(files.map(\.folder)).sorted()
        return Plan(
            moves: moves,
            months: months,
            renamedForICloud: renamed,
            collisions: suffixed.count,
            staying: input.rootListing.count - moves.count - googleNames.count
        )
    }

    // MARK: - Items

    private struct File {
        var old: String
        var key: String
        var folder: String
        var size: Int64
        /// For a sidecar, the index in `files` of its media file. Nil for media and for unmatched files.
        var sidecarOf: Int?
        /// True when the sidecar is `<media name>.xmp`, false when it is `<media stem>.xmp`.
        var followsFullName = false
    }

    private static func isMovable(_ name: String, in listing: [String: RootFile]) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && listing[name] != nil
    }

    private static func folder(for key: String, names: [String], _ input: Input) -> String {
        if key.hasPrefix(ExportManifest.iCloudIDPrefix), let created = input.createdByKey[key] {
            return monthFolder(created, calendar: input.calendar)
        }
        let isICloud = key.hasPrefix(ExportManifest.iCloudIDPrefix)
            || key.hasPrefix(ExportManifest.iCloudPartialPrefix)
            || key.hasPrefix(ExportManifest.iCloudPathPrefix)
        if isICloud {
            // iCloud items always have a date from the file, so they never go to Undated.
            let primary = primaryName(names)
            let modified = input.rootListing[primary]?.modified ?? 0
            return monthFolder(Date(timeIntervalSince1970: modified), calendar: input.calendar)
        }
        guard let created = input.createdByKey[key] else { return undatedFolder }
        return monthFolder(created, calendar: input.calendar)
    }

    /// The file whose date stands for the item: the first still image, else the first video, else the first file.
    private static func primaryName(_ names: [String]) -> String {
        let media = names.filter { !isXMP($0) }
        let stills = media.filter { !isVideo($0) }
        return stills.first ?? media.first ?? names[0]
    }

    private static func monthFolder(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return undatedFolder }
        return pad(year, width: 4) + "/" + pad(month, width: 2)
    }

    private static func pad(_ value: Int, width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    // MARK: - Names

    private static func isXMP(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == "xmp"
    }

    private static func isVideo(_ name: String) -> Bool {
        ["mov", "mp4", "m4v"].contains((name as NSString).pathExtension.lowercased())
    }

    /// The name a sidecar takes once its media has its new name: `<newName>.xmp`, or `<newStem>.xmp` when the
    /// sidecar was named after the media's stem.
    private static func sidecarName(_ sidecar: File, mediaNew: String) -> String {
        sidecar.followsFullName ? mediaNew + ".xmp" : split(mediaNew).stem + ".xmp"
    }

    /// The plain name for a file: `S.E` when it is icloudpd's `S-N.E` (N is its size), else its own name.
    private static func plainName(_ file: File) -> String {
        iCloudPlainName(file.old, size: file.size) ?? file.old
    }

    /// `S.E` for icloudpd's `S-N.E` with N equal to the size, else nil.
    private static func iCloudPlainName(_ name: String, size: Int64) -> String? {
        let (stem, ext) = split(name)
        guard !ext.isEmpty, let dash = stem.lastIndex(of: "-") else { return nil }
        let prefix = stem[..<dash]
        let number = stem[stem.index(after: dash)...]
        guard !prefix.isEmpty, !number.isEmpty, number.allSatisfy(\.isASCII), number.allSatisfy(\.isNumber),
              Int64(number) == size else { return nil }
        return join(String(prefix), ext)
    }

    /// `S-<size>.E`, then `S-<size>_2.E`, `_3` and so on, for the first one that is free.
    private static func firstFreeSuffixed(of base: String, size: Int64, isFree: (String) -> Bool) -> String {
        let (stem, ext) = split(base)
        let first = join("\(stem)-\(size)", ext)
        if isFree(first) { return first }
        var counter = 2
        while true {
            let candidate = join("\(stem)-\(size)_\(counter)", ext)
            if isFree(candidate) { return candidate }
            counter += 1
        }
    }

    /// The stem and extension of a name. The extension is empty when the name has none.
    private static func split(_ name: String) -> (stem: String, ext: String) {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return (name, "") }
        return (String(name.dropLast(ext.count + 1)), ext)
    }

    private static func join(_ stem: String, _ ext: String) -> String {
        ext.isEmpty ? stem : stem + "." + ext
    }
}
