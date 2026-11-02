import SwiftUI

/// How wide the central content of a detail page may get (the user's wish, 2026-10-30): the whole width of the window
/// (default), or a limit, Wide or Comfortable or a Custom number of points, so the cards don't stretch across a big
/// window. A per-user preference, remembered like the reading size: the choice under ``choiceKey``, the custom width
/// under ``customKey``. Lists, the sidebar and the toolbar are not affected.
enum ContentWidth {
    /// the preferences key of the chosen option
    static let choiceKey = "layout.contentWidth"
    /// the preferences key of the custom width in points
    static let customKey = "layout.customContentWidth"

    /// the custom width's range and step, in points
    static let customRange: ClosedRange<Double> = 800...2000
    static let customStep: Double = 50
    static let defaultCustom: Double = 1200

    enum Choice: String, CaseIterable, Sendable {
        /// the whole width of the window, as before the setting existed
        case full
        /// 1400 pt
        case wide
        /// 1100 pt
        case comfortable
        /// the slider's width
        case custom

        /// The option a stored value stands for; one nobody knows, such as from a newer or an edited preferences file,
        /// is Full Width.
        init(stored: String) {
            self = Choice(rawValue: stored) ?? .full
        }

        var title: String {
            switch self {
            case .full: "Full Width"
            case .wide: "Wide"
            case .comfortable: "Comfortable"
            case .custom: "Custom"
            }
        }
    }

    /// The most points the content gets, or `nil` for the whole width.
    ///
    /// - Parameters:
    ///   - stored: the stored option
    ///   - custom: the stored custom width, which counts only for Custom and is kept inside ``customRange``
    /// - Returns: the limit in points
    static func points(stored: String, custom: Double) -> CGFloat? {
        switch Choice(stored: stored) {
        case .full: nil
        case .wide: 1400
        case .comfortable: 1100
        case .custom: CGFloat(min(max(custom, customRange.lowerBound), customRange.upperBound))
        }
    }
}

/// Limits a page's content to the chosen ``ContentWidth``, centered in the scroll view, so the scroll bar stays at the
/// window's edge and the background fills the rest. Narrower windows are not affected. Replaces the page's
/// `.frame(maxWidth: .infinity)`.
private struct PageContentWidth: ViewModifier {
    @AppStorage(ContentWidth.choiceKey) private var stored = ContentWidth.Choice.full.rawValue
    @AppStorage(ContentWidth.customKey) private var custom = ContentWidth.defaultCustom

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: ContentWidth.points(stored: stored, custom: custom) ?? .infinity, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    /// The page's content limited to the chosen content width, with the 20 pt page padding around it. Apply it to the
    /// stack of the header and the cards, inside the `ScrollView`.
    func pageContentWidth() -> some View {
        modifier(PageContentWidth())
    }
}

/// Hands its content the space to leave free on each side so the reading content keeps to the chosen ``ContentWidth``:
/// half of what the measured width has over the limit, none for Full Width and for narrower windows. For the sections
/// whose content scrolls by itself, a `List` or a `Form`, which can't take ``View/pageContentWidth()``: the content
/// takes it as a margin, so the scroll bar stays at the window's edge and the backgrounds and dividers fill the rest.
struct ContentWidthMargins<Content: View>: View {
    @AppStorage(ContentWidth.choiceKey) private var stored = ContentWidth.Choice.full.rawValue
    @AppStorage(ContentWidth.customKey) private var custom = ContentWidth.defaultCustom
    @ViewState private var width: CGFloat = 0
    private let content: (CGFloat) -> Content

    /// - Parameter content: the content, given the margin for each side in points
    init(@ViewBuilder content: @escaping (CGFloat) -> Content) {
        self.content = content
    }

    var body: some View {
        content(ContentWidth.margin(of: width, stored: stored, custom: custom))
            // The width the container has, not the content's: the margin doesn't change it, so nothing loops.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

extension ContentWidth {
    /// The space to leave free on each side of content in a container this wide.
    ///
    /// - Parameters:
    ///   - width: the container's width in points
    ///   - stored: the stored option
    ///   - custom: the stored custom width
    /// - Returns: the margin per side, 0 for Full Width and for a container that isn't wider than the limit
    static func margin(of width: CGFloat, stored: String, custom: Double) -> CGFloat {
        guard let limit = points(stored: stored, custom: custom) else { return 0 }
        return max((width - limit) / 2, 0)
    }
}

extension View {
    /// A self-scrolling `Form` or `List` limited to the chosen content width: the rows are centered with the limit as
    /// their widest, the scroll bar stays at the window's edge. The counterpart of ``pageContentWidth()``.
    func scrollContentWidth() -> some View {
        ContentWidthMargins { margin in
            contentMargins(.horizontal, margin, for: .scrollContent)
        }
    }
}

/// The "Content Width" rows of Settings → General: the options and, for Custom, a slider.
struct ContentWidthRows: View {
    @AppStorage(ContentWidth.choiceKey) private var stored = ContentWidth.Choice.full.rawValue
    @AppStorage(ContentWidth.customKey) private var custom = ContentWidth.defaultCustom

    var body: some View {
        Picker(
            "Content width",
            selection: Binding(
                get: { ContentWidth.Choice(stored: stored) }, set: { stored = $0.rawValue })
        ) {
            ForEach(ContentWidth.Choice.allCases, id: \.self) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .pickerStyle(.menu)
        if ContentWidth.Choice(stored: stored) == .custom {
            LabeledContent("Maximum width") {
                HStack {
                    Slider(value: $custom, in: ContentWidth.customRange, step: ContentWidth.customStep)
                        .frame(minWidth: 140)
                    Text(verbatim: "\(Int(custom)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 60, alignment: .trailing)
                }
            }
        }
    }
}
