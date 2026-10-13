import AppKit
import SwiftUI

/// The "Why Uncloud" strip: one benefit at a time, moved by the chevrons, the arrow keys, a swipe
/// or a VoiceOver swipe, and wrapping around at both ends. It also advances on its own every few
/// seconds, but holds still whenever someone may be reading: while the pointer is over it, while it
/// has keyboard focus, for a while after a manual move, when the window isn't active, and whenever
/// Reduce Motion or VoiceOver is on.
struct BenefitsCarousel: View {
    static let autoAdvanceInterval: Duration = .seconds(3)
    /// How long a manual move holds the carousel before it advances on its own again.
    static let pauseAfterManualMove: TimeInterval = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var index = 0
    @State private var isHovering = false
    @State private var lastManualMove: Date?
    @FocusState private var isFocused: Bool
    /// Which way the last move went, so the slides travel the same way the chevron points.
    @State private var forward = true

    private let benefits = Benefit.all

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                chevron("chevron.left", label: "Previous Benefit") { move(-1) }
                slideArea
                chevron("chevron.right", label: "Next Benefit") { move(1) }
            }
            dots
        }
        .frame(maxWidth: 460)
        .onHover { isHovering = $0 }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autoAdvanceInterval)
                if shouldAdvanceOnItsOwn {
                    move(1, announces: false, manual: false)
                }
            }
        }
        // Key presses travel up from the focused view, so the arrows work on the slide and on a chevron.
        .onKeyPress(.leftArrow) {
            move(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            move(1)
            return .handled
        }
    }

    private func chevron(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 28)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .help(label)
    }

    /// Every slide is laid out once, hidden, so the strip is as tall as the tallest slide and the page
    /// never jumps. The visible slide is drawn on top of them.
    private var slideArea: some View {
        ZStack {
            ForEach(benefits) { benefit in
                BenefitSlide(benefit: benefit)
                    .hidden()
                    .accessibilityHidden(true)
            }
            BenefitSlide(benefit: benefits[index])
                .id(index)
                .transition(slideTransition)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipped()
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.width < -50 {
                        move(1)
                    } else if value.translation.width > 50 {
                        move(-1)
                    }
                }
        )
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(1, announces: false)
            case .decrement: move(-1, announces: false)
            @unknown default: break
            }
        }
    }

    /// Opacity only under Reduce Motion; otherwise a short slide in the direction of the move.
    private var slideTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        let insertion: Edge = forward ? .trailing : .leading
        let removal: Edge = forward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: insertion).combined(with: .opacity),
            removal: .move(edge: removal).combined(with: .opacity)
        )
    }

    /// Display only: the dots show where you are and are not controls. VoiceOver reads them as one
    /// "Benefit n of 5" element, so there are no hit targets to tap.
    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(benefits.indices, id: \.self) { position in
                Circle()
                    .frame(width: 6, height: 6)
                    .foregroundStyle(position == index ? .primary : .tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Benefit \(index + 1) of \(benefits.count)")
    }

    private var shouldAdvanceOnItsOwn: Bool {
        guard !reduceMotion, !isHovering, !isFocused, controlActiveState == .key,
              !NSWorkspace.shared.isVoiceOverEnabled
        else { return false }
        if let lastManualMove, Date.now.timeIntervalSince(lastManualMove) < Self.pauseAfterManualMove {
            return false
        }
        return true
    }

    /// Moves one slide, wrapping around at the ends. Moves made by keys, chevrons and swipes are
    /// announced to VoiceOver; the adjustable action already speaks for itself.
    private func move(_ step: Int, announces: Bool = true, manual: Bool = true) {
        if manual {
            lastManualMove = .now
        }
        let count = benefits.count
        let next = (index + step + count) % count
        // Set the direction before the index so the outgoing slide keeps the right transition.
        forward = step > 0
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3)) {
            index = next
        }
        if announces {
            let benefit = benefits[next]
            AccessibilityNotification.Announcement("\(benefit.title), Benefit \(next + 1) of \(count)").post()
        }
    }
}

/// One benefit as a slim row: a plain symbol, then the title and one short line. VoiceOver reads it as one element.
private struct BenefitSlide: View {
    let benefit: Benefit

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: benefit.symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(benefit.title)
                    .font(.headline)
                Text(benefit.tagline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// One of the five reasons to use Uncloud. Written as what the app does, not as a comparison with other services.
struct Benefit: Identifiable {
    let title: String
    /// The full sentence, shown in Getting Started.
    let caption: String
    /// One short line, shown on the landing page strip.
    let tagline: String
    let symbol: String
    let tint: Color

    var id: String { title }

    static let all: [Benefit] = [
        Benefit(
            title: "Full-Quality Originals",
            caption: "Copies your originals, edits, Live Photos and RAW files, exactly as they are.",
            tagline: "Originals, edits, Live Photos and RAW, exactly as they are.",
            symbol: "camera.aperture",
            tint: .orange
        ),
        Benefit(
            title: "Organised Your Way",
            caption: "Sorts into folders by month or by album. With the Photos library on this Mac, by place too.",
            tagline: "Sorted into folders by month or by album.",
            symbol: "rectangle.3.group",
            tint: .indigo
        ),
        Benefit(
            title: "Built for Huge Libraries",
            caption: "Handles tens of thousands of photos. Pause, resume, and next time copy only what’s new.",
            tagline: "Pause, resume, and next time copy only what’s new.",
            symbol: "arrow.triangle.2.circlepath",
            tint: .pink
        ),
        Benefit(
            title: "Verified and Automatic",
            caption: "Saves a checksum for every file so you can verify your backup any time, and exports on its own when your drive connects.",
            tagline: "A checksum for every file. Exports when your drive connects.",
            symbol: "checkmark.shield",
            tint: .green
        ),
        Benefit(
            title: "No Detour Through Your Mac",
            caption: "With iCloud Photos, photos stream directly onto your external drive. Nothing is saved on your Mac first.",
            tagline: "Photos stream directly onto your external drive.",
            symbol: "externaldrive.fill",
            tint: .teal
        ),
    ]
}

/// One benefit as an icon with its title and caption, for the Getting Started list.
struct BenefitRow: View {
    let benefit: Benefit

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: benefit.symbol, tint: benefit.tint, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(benefit.title)
                    .font(.headline)
                Text(benefit.caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The privacy reassurance. Used in Getting Started.
struct PrivacyNote: View {
    @Environment(ExportModel.self) private var model
    var showsLearnMore: Bool

    var body: some View {
        VStack(spacing: 8) {
            Label {
                Text("Your photos go straight to your own folder or drive. Your Apple ID password goes only to Apple, through icloudpd, the open-source tool inside Uncloud, and is kept in your Keychain only if you choose.")
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 560)

            if showsLearnMore {
                Button("Learn More…") {
                    model.introSheet = .gettingStarted
                }
                .buttonStyle(.link)
            }
        }
    }
}
