import AppKit
import SwiftUI
import Testing
@testable import Uncloud

/// Renders the signed-out screens (Welcome, Sign Up, Sign In, Code and the Code error) to PNG attachments, light and
/// dark, at the default window size and the minimum. Runs only when UNCLOUD_ACCOUNT_SNAPSHOTS is set. The PNGs are
/// exported from the result bundle with `xcrun xcresulttool`, as for the other snapshot suites.
@MainActor
@Suite("AccountSnapshot")
struct AccountSnapshotTests {
    private static let sizes = [NSSize(width: 1_000, height: 700), NSSize(width: 760, height: 500)]

    @Test func rendersSignedOutScreens() async throws {
        guard ProcessInfo.processInfo.environment["UNCLOUD_ACCOUNT_SNAPSHOTS"] != nil else { return }
        var images: [(String, NSImage)] = []

        for state in try await Self.states() {
            for size in Self.sizes {
                for scheme in [ColorScheme.light, .dark] {
                    let window = RootView()
                        .environment(state.model)
                    let name = "\(state.name)-\(Int(size.width))-\(Self.name(scheme))"
                    let image = try #require(await Self.renderTitledWindow(window, size: size, scheme: scheme))
                    images.append((name, image))
                }
            }
        }

        for (name, image) in images {
            Attachment.record(try Self.png(image), named: "\(name).png")
        }
    }

    /// Each signed-out screen, built the way the app reaches it: the model's own actions, against the preview service.
    private static func states() async throws -> [(name: String, model: AccountModel)] {
        func fresh() -> AccountModel {
            let defaults = isolatedDefaults()
            let service = PreviewAccountService(store: PreviewAccountStore(defaults: defaults), now: { Date() })
            // The clock is the real one, so the resend countdown the views draw matches the live app.
            return AccountModel(mode: .preview, service: service, tokens: DefaultsAccountTokenStore(defaults: defaults), defaults: defaults)
        }

        let welcome = fresh()
        let signUp = fresh()
        signUp.show(.signUp)
        let signIn = fresh()
        signIn.show(.signIn)

        let code = fresh()
        await code.submitEmail("name@example.com", intent: .signUp)

        let codeError = fresh()
        await codeError.submitEmail("name@example.com", intent: .signUp)
        await codeError.submitCode("000000")

        return [
            ("welcome", welcome),
            ("signup", signUp),
            ("signin", signIn),
            ("code", code),
            ("code-error", codeError),
        ]
    }

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

    /// Renders a view in a titled window, so the window's frame and title bar draw as they do in the app.
    private static func renderTitledWindow<V: View>(_ view: V, size: NSSize, scheme: ColorScheme) async -> NSImage? {
        let page = view
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
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<25 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }
        defer { window.close() }
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
