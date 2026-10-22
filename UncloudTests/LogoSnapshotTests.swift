import AppKit
import SwiftUI
import Testing
@testable import Uncloud

/// Renders the animated logo at fixed animation states to PNG files for review. Runs only when
/// UNCLOUD_LOGO_SNAPSHOTS names an output folder, for example:
///   TEST_RUNNER_UNCLOUD_LOGO_SNAPSHOTS=<folder> xcodebuild test ...
@MainActor
@Suite("LogoSnapshot")
struct LogoSnapshotTests {
    /// Start, middle, end, and the end frame with the rays turned 45 degrees.
    private static let states: [(name: String, progress: Double, rotation: Double, motion: Double)] = [
        ("start", 0, 0, 0),
        ("middle", 0.5, 20, 0.5),
        ("end", 1, 0, 1),
        ("spin", 1, 45, 1),
    ]

    @Test func rendersAnimatedLogoStates() throws {
        guard let folder = ProcessInfo.processInfo.environment["UNCLOUD_LOGO_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        for state in Self.states {
            let view = AnimatedAppLogoFrame(size: 512,
                                            progress: state.progress,
                                            rotation: state.rotation,
                                            motion: state.motion)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let name = "logo-\(state.name).png"
            // The sandboxed test host can be refused the folder, so the attachment is the fallback.
            try? png.write(to: directory.appending(path: name))
            Attachment.record(png, named: name)
        }
    }
}
