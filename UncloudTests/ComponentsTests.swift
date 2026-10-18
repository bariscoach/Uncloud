import AppKit
import SwiftUI
import Testing
@testable import Uncloud

/// The shared components and the tokens they read. Each component renders in light and dark, so a layout that
/// can't draw fails here rather than in a release.
@MainActor
@Suite("Components")
struct ComponentsTests {
    @Test func photosCountsZeroOneAndMany() {
        #expect(Plural.photos(0) == "0 photos")
        #expect(Plural.photos(1) == "1 photo")
        #expect(Plural.photos(2) == "2 photos")
        #expect(Plural.photos(1_234) == "\(1_234.formatted()) photos")
    }

    @Test func reduceMotionTurnsAnimationOff() {
        #expect(Tokens.Motion.animation(true) == nil)
        #expect(Tokens.Motion.animation(false) == Tokens.Motion.standard)
    }

    @Test func componentsRenderInLightAndDark() {
        for scheme in [ColorScheme.light, .dark] {
            let sheet = SheetScaffold("Clean Up iCloud", content: {
                HelpText("Nothing is deleted until you confirm.")
            }, buttons: {
                Button("Cancel") {}
                Button("Continue") {}.buttonStyle(.borderedProminent)
            })
            #expect(Self.drawsContent(sheet, scheme: scheme))

            let form = FormSheetScaffold("Export Options", content: {
                Section { Text("Layout") }
            }, buttons: {
                Button("Done") {}.buttonStyle(.borderedProminent)
            })
            #expect(Self.drawsContent(form, scheme: scheme))

            let banner = StatusBanner(symbol: "exclamationmark.triangle", tint: Tokens.Status.warning, title: "Your backup needs attention", detail: "Open Backup to see what changed.", progress: 0.4) {
                Button("Open") {}
            }
            #expect(Self.drawsContent(banner, scheme: scheme))

            let plain = StatusBanner(symbol: nil, tint: Tokens.Status.neutral, title: "Exporting…") {
                EmptyView()
            }
            #expect(Self.drawsContent(plain, scheme: scheme))
        }
    }

    private static func drawsContent<V: View>(_ view: V, scheme: ColorScheme) -> Bool {
        (render(view, scheme: scheme)?.size.width ?? 0) > 0
    }

    /// Renders the view at a fixed width, or nil if nothing drew.
    private static func render<V: View>(_ view: V, scheme: ColorScheme) -> NSImage? {
        let page = view
            .environment(\.colorScheme, scheme)
            .frame(width: 560)
        let renderer = ImageRenderer(content: page)
        renderer.scale = 2
        return renderer.nsImage
    }
}
