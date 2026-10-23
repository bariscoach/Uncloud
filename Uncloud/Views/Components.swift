import SwiftUI

/// A sheet with a title, a content area and a footer of buttons. The footer's buttons are right-aligned and use
/// `Tokens.Sheet.footerControlSize`, so every sheet's bottom edge matches.
struct SheetScaffold<Content: View, Buttons: View>: View {
    let title: String
    let width: CGFloat
    let content: Content
    let buttons: Buttons

    init(
        _ title: String,
        width: CGFloat = Tokens.Sheet.regular,
        @ViewBuilder content: () -> Content,
        @ViewBuilder buttons: () -> Buttons
    ) {
        self.title = title
        self.width = width
        self.content = content()
        self.buttons = buttons()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            Text(title)
                .font(.title2.weight(.semibold))
            content
            HStack(spacing: Tokens.Space.s) {
                Spacer()
                buttons
            }
            .controlSize(Tokens.Sheet.footerControlSize)
        }
        .padding(Tokens.Sheet.padding)
        .frame(width: width)
    }
}

/// A sheet whose content is a grouped `Form`, with a divider above the footer. Use it when the content is settings
/// or choices. Use `SheetScaffold` for everything else.
struct FormSheetScaffold<Content: View, Buttons: View>: View {
    let title: String
    let width: CGFloat
    let minHeight: CGFloat
    let content: Content
    let buttons: Buttons

    init(
        _ title: String,
        width: CGFloat = Tokens.Sheet.regular,
        minHeight: CGFloat = 440,
        @ViewBuilder content: () -> Content,
        @ViewBuilder buttons: () -> Buttons
    ) {
        self.title = title
        self.width = width
        self.minHeight = minHeight
        self.content = content()
        self.buttons = buttons()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Tokens.Sheet.padding)
                .padding(.top, Tokens.Sheet.padding)
                .padding(.bottom, Tokens.Space.s)
            Form {
                content
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: Tokens.Space.s) {
                Spacer()
                buttons
            }
            .controlSize(Tokens.Sheet.footerControlSize)
            .padding(Tokens.Sheet.padding)
        }
        .frame(width: width)
        .frame(minHeight: minHeight)
    }
}

/// A status line with an optional symbol, detail text, progress and actions. It sits at the top or bottom of a pane.
/// On macOS 26 it floats on glass. Before that it is a material strip with a divider. It states the status in words
/// and never relies on colour alone: `symbol` carries the tone along with `tint`.
struct StatusBanner<Actions: View>: View {
    let symbol: String?
    let tint: Color
    let title: String
    let detail: String?
    let progress: Double?
    let actions: Actions

    init(
        symbol: String?,
        tint: Color,
        title: String,
        detail: String? = nil,
        progress: Double? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.detail = detail
        self.progress = progress
        self.actions = actions()
    }

    var body: some View {
        let strip = HStack(spacing: Tokens.Space.m) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text(title)
                    .font(.headline)
                if let detail {
                    Text(detail)
                        .font(Tokens.Font.help)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let progress {
                    ProgressView(value: progress)
                        .tint(tint)
                }
            }
            Spacer(minLength: Tokens.Space.m)
            actions
        }
        .padding(.horizontal, Tokens.Space.l)
        .padding(.vertical, Tokens.Space.m)

        Group {
            // Glass for controls, never for content: the banner floats above the content it describes.
            if #available(macOS 26, *) {
                strip
                    .glassEffect(.regular, in: .rect(cornerRadius: Tokens.Radius.l))
                    .padding(Tokens.Space.s)
            } else {
                strip
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
                    .overlay(alignment: .bottom) {
                        Divider()
                    }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Secondary helper text under a control or a section: callout, secondary colour, wrapping to its width.
struct HelpText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Tokens.Font.help)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Counts in the user's words. Locale-formatted, so "1,234" is "1.234" where that is the convention.
enum Plural {
    /// "1 photo", "2 photos", "1,234 photos".
    static func photos(_ count: Int) -> String {
        let number = count.formatted()
        return count == 1 ? "\(number) photo" : "\(number) photos"
    }
}

/// The Delete from iCloud command, published with `.focusedValue` so the menu item is enabled and opens the sheet only
/// while that window has focus. The action only opens an existing confirmation; it never deletes.
struct CleanupCommandActions {
    let title: String
    let isEnabled: Bool
    let perform: @MainActor () -> Void
}

struct CleanupCommandKey: FocusedValueKey {
    typealias Value = CleanupCommandActions
}

extension FocusedValues {
    var cleanupCommand: CleanupCommandActions? {
        get { self[CleanupCommandKey.self] }
        set { self[CleanupCommandKey.self] = newValue }
    }
}
