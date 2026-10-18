import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Uncloud

/// Renders Browse Backup's screens to PNG attachments, in light and dark mode. Runs only when UNCLOUD_BROWSE_SNAPSHOTS
/// is set, so a normal test run writes nothing. The sandboxed test host can't write the scratch folder, so the PNGs
/// are exported from the result bundle with `xcrun xcresulttool`, as the UI refresh snapshots are.
@MainActor
@Suite("BrowseBackupSnapshot")
struct BrowseBackupSnapshotTests {
    /// The map (with the inspector open on one place), the Places list with a photo's details, and the empty states.
    @Test func rendersBrowseScreens() async throws {
        guard ProcessInfo.processInfo.environment["UNCLOUD_BROWSE_SNAPSHOTS"] != nil else { return }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "uncloud-browse-\(UUID().uuidString)", directoryHint: .isDirectory)
        let drive = root.appending(path: "Travel Drive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = try Fixture.make(in: drive)
        let model = ExportModel()
        let browse = BrowseBackup(
            store: BrowseIndexStore(directory: root.appending(path: "Index", directoryHint: .isDirectory)),
            namer: FakeNamer(answers: [:]),
            isExportRunning: { false }
        )
        browse.load(entries: fixture.entries, names: fixture.names, destination: drive, destinationName: "Travel Drive")

        var images: [(String, NSImage)] = []
        for scheme in [ColorScheme.light, .dark] {
            let name = Self.name(scheme)

            // Map, every pin visible, then with the inspector open on Rome's pin.
            browse.mode = .map
            browse.mapSelection = []
            browse.selectedPaths = []
            let map = BrowseBackupView(browse: browse, syncsDestination: false).environment(model)
            images.append(("map-\(name)", try #require(await Self.render(map, size: NSSize(width: 1_000, height: 700), scheme: scheme))))

            browse.mapSelection = [fixture.romeKey]
            browse.selectedPaths = [fixture.romePaths[0]]
            images.append(("map-inspector-\(name)", try #require(await Self.render(map, size: NSSize(width: 1_000, height: 700), scheme: scheme))))

            // Places, with Rome open and one photo selected: the grid and the detail pane.
            browse.mode = .places
            browse.selectedGroupID = fixture.romeGroupID
            browse.mapSelection = []
            browse.selectedPaths = [fixture.romePaths[0]]
            let places = BrowseBackupView(browse: browse, syncsDestination: false).environment(model)
            images.append(("places-\(name)", try #require(await Self.render(places, size: NSSize(width: 1_000, height: 700), scheme: scheme))))
            browse.selectedPaths = []
        }

        // Empty states: no folder, drive not connected, nothing exported yet, and no photo with a location.
        let empty = BrowseBackup(
            store: BrowseIndexStore(directory: root.appending(path: "Empty", directoryHint: .isDirectory)),
            namer: FakeNamer(answers: [:]),
            isExportRunning: { false }
        )
        let disconnected = BrowseBackup(
            store: BrowseIndexStore(directory: root.appending(path: "Disconnected", directoryHint: .isDirectory)),
            namer: FakeNamer(answers: [:]),
            isExportRunning: { false }
        )
        disconnected.update(destination: drive, name: "Travel Drive", isConnected: false)
        let nothing = BrowseBackup(
            store: BrowseIndexStore(directory: root.appending(path: "Nothing", directoryHint: .isDirectory)),
            namer: FakeNamer(answers: [:]),
            isExportRunning: { false }
        )
        nothing.load(entries: [], destination: drive, destinationName: "Travel Drive")
        let noLocation = BrowseBackup(
            store: BrowseIndexStore(directory: root.appending(path: "NoLocation", directoryHint: .isDirectory)),
            namer: FakeNamer(answers: [:]),
            isExportRunning: { false }
        )
        noLocation.load(entries: fixture.noLocationEntries, destination: drive, destinationName: "Travel Drive")
        for scheme in [ColorScheme.light, .dark] {
            let name = Self.name(scheme)
            let states: [(String, BrowseBackup)] = [("nofolder", empty), ("disconnected", disconnected), ("nothing", nothing), ("nolocation", noLocation)]
            for (state, browse) in states {
                let view = BrowseBackupView(browse: browse, syncsDestination: false).environment(model)
                images.append(("\(state)-\(name)", try #require(await Self.render(view, size: NSSize(width: 1_000, height: 700), scheme: scheme))))
            }
            images.append(("indexing-\(name)", try #require(await Self.render(
                IndexingBanner(progress: BrowseBackup.Progress(done: 12_340, total: 48_312), isPaused: false)
                    .frame(width: 720),
                size: NSSize(width: 720, height: 50),
                scheme: scheme
            ))))
            images.append(("indexing-paused-\(name)", try #require(await Self.render(
                IndexingBanner(progress: BrowseBackup.Progress(done: 12_340, total: 48_312), isPaused: true)
                    .frame(width: 720),
                size: NSSize(width: 720, height: 50),
                scheme: scheme
            ))))
        }

        // The map's pins: MapKit doesn't draw annotation layers into an offscreen capture, so the count badge is shown
        // on its own, as the pin draws it.
        for scheme in [ColorScheme.light, .dark] {
            let badges = HStack(spacing: Tokens.Space.m) {
                ForEach([3, 12, 1_240], id: \.self) { count in
                    Image(nsImage: BrowseMapView.Badge.image(count: count))
                }
            }
            .padding(Tokens.Space.l)
            .background(Color(nsColor: .windowBackgroundColor))
            images.append(("map-badges-\(Self.name(scheme))", try #require(await Self.render(badges, size: NSSize(width: 320, height: 60), scheme: scheme))))
        }

        for (name, image) in images {
            Attachment.record(try Self.png(image), named: "\(name).png")
        }
    }

    // MARK: - Helpers

    private static func name(_ scheme: ColorScheme) -> String {
        scheme == .dark ? "dark" : "light"
    }

    private static func png(_ image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// Renders a view inside a titled window, so the toolbar, title and subtitle draw as they do in the app.
    private static func render<V: View>(_ view: V, size: NSSize, scheme: ColorScheme) async -> NSImage? {
        // The shipping accent, as the app sets it at its root and the UI refresh snapshots do.
        let page = NavigationStack { view }
            .accentVariant(.sky)
            .environment(\.colorScheme, scheme)
        let controller = NSHostingController(rootView: page)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(size)
        window.toolbarStyle = .unified
        // Controls draw their selected state only in a key window, and a sidebar-style list only when it has focus.
        // A user looking at the window has both, so the capture does too. Without them the selection draws black offscreen.
        for _ in 0..<30 {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if window.isKeyWindow { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Thumbnails and the map load after layout, so give them time.
        for step in 0..<40 {
            window.contentView?.layoutSubtreeIfNeeded()
            if [5, 15, 25].contains(step) {
                // Each render closes its window, and activation can drift to the next one. Take key and main again.
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.makeMain()
            }
            if step == 5 {
                if let table = Self.firstTable(in: window.contentView) {
                    window.makeFirstResponder(table)
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        defer { window.close() }
        // Let the key state reach the title bar and the list before the capture is drawn.
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        guard let frameView = window.contentView?.superview else { return nil }
        frameView.displayIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func firstTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }

    /// Sample photos on a drive: pictures with GPS in Rome, Sydney and Kyoto, and a few without a location.
    private struct Fixture {
        let entries: [BrowseEntry]
        let noLocationEntries: [BrowseEntry]
        let names: [String: PlaceResolver.Place]
        let romePaths: [String]
        let romeKey: String
        let romeGroupID: String

        static func make(in drive: URL) throws -> Fixture {
            let places: [(name: String, latitude: Double, longitude: Double, count: Int, place: PlaceResolver.Place)] = [
                ("Rome", 41.9028, 12.4964, 5, PlaceResolver.Place(country: "Italy", city: "Rome")),
                ("Sydney", -33.8688, 151.2093, 3, PlaceResolver.Place(country: "Australia", city: "Sydney")),
                ("Kyoto", 35.0116, 135.7681, 2, PlaceResolver.Place(country: "Japan", city: "Kyoto")),
            ]
            var entries: [BrowseEntry] = []
            var names: [String: PlaceResolver.Place] = [:]
            var romePaths: [String] = []
            for place in places {
                names[PlaceResolver.cellKey(latitude: place.latitude, longitude: place.longitude)] = place.place
                for index in 0..<place.count {
                    let path = "2024/07/\(place.name)-\(index).jpg"
                    try writeFixtureImage(
                        at: drive.appending(path: path),
                        latitude: place.latitude + Double(index) * 0.002,
                        longitude: place.longitude + Double(index) * 0.002
                    )
                    if place.name == "Rome" { romePaths.append(path) }
                    entries.append(BrowseEntry(
                        path: path, size: 2_400_000, modified: 1,
                        latitude: place.latitude + Double(index) * 0.002,
                        longitude: place.longitude + Double(index) * 0.002,
                        date: Date(timeIntervalSince1970: 1_720_000_000 + Double(index) * 3_600),
                        camera: "Apple iPhone 15"
                    ))
                }
            }
            var noLocation: [BrowseEntry] = []
            for index in 0..<2 {
                let path = "2023/12/Screenshot-\(index).png"
                try writeFixtureImage(at: drive.appending(path: path), latitude: nil, longitude: nil)
                noLocation.append(BrowseEntry(path: path, size: 180_000, modified: 1, latitude: nil, longitude: nil, date: nil, camera: nil))
            }
            let romeKey = PlaceResolver.cellKey(latitude: 41.9028, longitude: 12.4964)
            return Fixture(
                entries: entries + noLocation,
                noLocationEntries: noLocation,
                names: names,
                romePaths: romePaths.sorted(),
                romeKey: romeKey,
                romeGroupID: "place:Italy › Rome"
            )
        }

        private static func writeFixtureImage(at url: URL, latitude: Double?, longitude: Double?) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let context = try #require(CGContext(
                data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            // A plain gradient, so the thumbnails have something to show.
            let hue = Double(abs(url.lastPathComponent.hashValue) % 100) / 100
            context.setFillColor(red: hue, green: 0.55, blue: 0.85 - hue / 2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.6)
            context.fill(CGRect(x: 20, y: 20, width: 56, height: 56))
            let image = try #require(context.makeImage())
            var properties: [CFString: Any] = [:]
            if let latitude, let longitude {
                properties[kCGImagePropertyGPSDictionary] = [
                    kCGImagePropertyGPSLatitude: abs(latitude),
                    kCGImagePropertyGPSLatitudeRef: latitude < 0 ? "S" : "N",
                    kCGImagePropertyGPSLongitude: abs(longitude),
                    kCGImagePropertyGPSLongitudeRef: longitude < 0 ? "W" : "E",
                ]
            }
            let type = url.pathExtension.lowercased() == "png" ? UTType.png : UTType.jpeg
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}
