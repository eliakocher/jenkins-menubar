import AppKit
import MenubarCore
import SwiftUI

/// The pane's and the flyouts' metrics: a native macOS 26 menu's, in the menu font (`docs/design/panel.md`).
enum MenuMetrics {
    /// the pane's fixed width: an area's summary line fits without cutting in the usual states
    static let paneWidth: CGFloat = 384
    /// the flyout's fixed width: about 50 characters of a title
    static let flyoutWidth: CGFloat = 388
    /// the room between a window's edge and a row's highlight, as a native menu's
    static let inset: CGFloat = 5
    /// the room between a row's highlight and its content
    static let padding: CGFloat = 9
    /// the room above the first row and below the last
    static let edge: CGFloat = 5
    /// the least height of a one-line row
    static let rowHeight: CGFloat = 24
    /// the column every pane row's symbol takes, the areas' and the footer's, so the titles line up
    static let paneSymbol: CGFloat = 22
    /// an area row's least height: two lines, as every area row has, so the three are alike
    static let areaRowHeight: CGFloat = 38
    /// the flyout rows' symbol column
    static let symbolColumn: CGFloat = 18
    /// the flyout's corners, the glass's; a row's highlight is concentric to them
    static let flyoutCorner: CGFloat = 14
    /// the most a flyout grows before it scrolls, below the screen's own limit
    static let flyoutCap: CGFloat = 640
}

/// Whether a row shows the menu highlight: its text and symbols turn white on the accent color.
private struct MenuHighlightKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// whether the row around a view is highlighted, so its grey and colored parts turn white
    var menuHighlighted: Bool {
        get { self[MenuHighlightKey.self] }
        set { self[MenuHighlightKey.self] = newValue }
    }
}

extension View {
    /// A menu row: full width, its content padded as a native menu item's, and while highlighted the system's
    /// selection, the accent color in a rounded shape inset from the window's edges, with white text.
    ///
    /// - Parameters:
    ///   - isHighlighted: whether the row is highlighted
    ///   - corner: the highlight's corner radius; `nil` makes it concentric to the window's corners
    func menuRow(isHighlighted: Bool, corner: CGFloat? = nil) -> some View {
        modifier(MenuRowModifier(isHighlighted: isHighlighted, corner: corner))
    }
}

private struct MenuRowModifier: ViewModifier {
    let isHighlighted: Bool
    let corner: CGFloat?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, MenuMetrics.padding)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, minHeight: MenuMetrics.rowHeight, alignment: .leading)
            .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .environment(\.menuHighlighted, isHighlighted)
            .background {
                if isHighlighted {
                    highlightShape
                }
            }
            .padding(.horizontal, MenuMetrics.inset)
            .contentShape(Rectangle())
            // The menubar's window sizes itself to its content's least height, not its ideal one: a row that could
            // give in would be squeezed to one line and overlap the next (the user's screenshot of 2026-10-29).
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var highlightShape: some View {
        if let corner {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.accentColor)
        } else {
            ConcentricRectangle(corners: .concentric(minimum: .fixed(6)), isUniform: true)
                .fill(Color.accentColor)
        }
    }
}

/// A menu row's grey text: `.secondary`, white while the row is highlighted, as a native menu item's subtitle.
struct MenuSecondaryText: View {
    let text: String
    @Environment(\.menuHighlighted) private var isHighlighted

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: text)
            .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
    }
}

extension MenuTint {
    /// the color to draw with: GitLab's colors follow the appearance (MR-02)
    var color: Color {
        switch self {
        case .build(let state): state.color ?? .primary
        case .gitLab(let color): color.swiftUI
        case .secondary: .secondary
        }
    }
}

/// A status symbol in its color, white while its row is highlighted, as a native menu's images.
struct MenuSymbol: View {
    let name: String
    var tint: MenuTint?
    @Environment(\.menuHighlighted) private var isHighlighted

    var body: some View {
        Image(systemName: name)
            .foregroundStyle(style)
    }

    private var style: AnyShapeStyle {
        if isHighlighted {
            return AnyShapeStyle(.white)
        }
        return tint.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.primary)
    }
}

/// An area's symbol: the sidebar's glyph, monochrome like the footer's symbols (the user, 2026-10-29: "consistent, no
/// colors"), in the same size, color and column, white while its row is highlighted. Outline forms, so the three
/// weigh the same as each other and as the footer's.
struct MenuAreaIcon: View {
    let section: MainWindowSection
    @Environment(\.menuHighlighted) private var isHighlighted

    var body: some View {
        Image(systemName: Self.glyph(of: section))
            .font(.system(size: 13))
            .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: MenuMetrics.paneSymbol)
            .accessibilityHidden(true)
    }

    /// The glyph: the sidebar's symbol in a form that balances with the others.
    static func glyph(of section: MainWindowSection) -> String {
        glyphs[section] ?? section.systemImage
    }

    private static let glyphs: [MainWindowSection: String] = [
        .pipelines: "hammer", .mergeRequests: "arrow.triangle.branch", .workItems: "checklist",
    ]
}

/// A thin progress bar under a running build, in the accent color, white while the row is highlighted (PIPE-02).
/// Without an estimate, a short segment that slides, unless Reduce Motion is on.
struct MenuProgressBar: View {
    let progress: BuildRowModel.Progress
    @Environment(\.menuHighlighted) private var isHighlighted
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(isHighlighted ? AnyShapeStyle(.white.opacity(0.3)) : AnyShapeStyle(.quaternary))
                switch progress {
                case .fraction(let fraction):
                    Capsule()
                        .fill(fill)
                        .frame(width: max(3, proxy.size.width * fraction))
                case .indeterminate:
                    if !reduceMotion {
                        Capsule()
                            .fill(fill)
                            .frame(width: proxy.size.width * 0.3)
                            .offset(x: proxy.size.width * 0.7 * phase)
                    }
                }
            }
        }
        .frame(height: 3)
        .onAppear {
            guard case .indeterminate = progress, !reduceMotion else {
                return
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
        .accessibilityHidden(true)
    }

    private var fill: AnyShapeStyle {
        isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor.gradient)
    }
}

/// A faint tint behind the pane's and the flyout's content, over their glass, so the text stays crisp over a busy
/// window (the user, 2026-10-29): black in the dark appearance, white in the light one. The glass still shows through.
struct MenuBackdropTint<Tint: Shape>: View {
    let shape: Tint
    @Environment(\.colorScheme) private var colorScheme

    /// how strong the tint is, the same for the pane and the flyout so they match; a little stronger in the dark,
    /// where bright windows behind the glass show through more (judged on the gallery's `menu-pane.busy-backdrop`)
    static func strength(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.28 : 0.22
    }

    var body: some View {
        shape.fill(colorScheme == .dark ? Color.black : Color.white)
            .opacity(Self.strength(colorScheme))
    }
}

/// A native menu's separator: a hairline inset from the edges.
struct MenuSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, MenuMetrics.inset + MenuMetrics.padding)
            .padding(.vertical, 5)
    }
}

/// A view that hands the AppKit view at its place to the pane, so the flyout can be put beside the row it belongs to
/// (`MenuFlyoutPlacement`). It draws nothing and takes no clicks.
struct MenuAnchor: NSViewRepresentable {
    let onResolve: @MainActor (NSView) -> Void

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onWindow = onResolve
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.onWindow = onResolve
        if nsView.window != nil {
            onResolve(nsView)
        }
    }

    final class AnchorView: NSView {
        var onWindow: (@MainActor (NSView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                onWindow?(self)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
