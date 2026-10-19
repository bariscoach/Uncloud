import AppKit
import SwiftUI
import Testing
@testable import Uncloud

/// Renders the landing page to PNG files for design review. The PNGs go to the session scratch
/// folder only when that folder exists, so the test passes everywhere else without writing anything.
@MainActor
@Suite("LandingSnapshot")
struct LandingSnapshotTests {
    private static let scratch = URL(
        fileURLWithPath: "/private/tmp/claude-501/-Users-barishiz-Developer-icloud-photo-export/df886b0f-d79a-4d1c-973d-23c5d89614c2/scratchpad",
        isDirectory: true
    )

    @Test func rendersLandingInLightAndDark() async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: Self.scratch.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        let model = ExportModel()
        try save(await render(scheme: .light, model: model), named: "landing-light.png")
        try save(await render(scheme: .dark, model: model), named: "landing-dark.png")
    }

    /// Writes to the scratch folder. The sandboxed test host can be refused there, so it falls back
    /// to its own temporary folder rather than failing the run.
    private func save(_ image: NSImage?, named name: String) throws {
        let image = try #require(image)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        do {
            try png.write(to: Self.scratch.appending(path: name))
        } catch {
            try png.write(to: FileManager.default.temporaryDirectory.appending(path: name))
        }
    }

    /// ImageRenderer leaves out the ScrollView and GeometryReader content, so the page is hosted in an
    /// offscreen window and captured with cacheDisplay, which draws what the window would show.
    private func render(scheme: ColorScheme, model: ExportModel) async -> NSImage? {
        let size = NSSize(width: 1000, height: 700)
        let page = LandingView()
            .environment(model)
            .environment(\.colorScheme, scheme)
            .environment(AccountModel.forTesting())
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: page)
        host.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        // Key window, so prominent buttons draw in the accent colour as they do in the app.
        window.makeKeyAndOrderFront(nil)
        // Give SwiftUI a few run-loop passes to lay the page out before capturing it.
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }

        defer { window.close() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
