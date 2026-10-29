import AppKit
import MenubarCore
import SwiftUI

/// What the pane's rows report: the pointer on a row or off the pane, a click, and the area rows' places for the
/// flyout. The gallery passes ``none``.
struct MenuPaneEvents {
    /// the pointer moved over a row
    var hover: @MainActor (MenuNavigation.PaneRow) -> Void = { _ in }
    /// the pointer left the pane
    var leave: @MainActor () -> Void = {}
    /// a click on a row
    var activate: @MainActor (MenuNavigation.PaneRow) -> Void = { _ in }
    /// an area row's AppKit view, whose frame places the flyout
    var anchor: @MainActor (MainWindowSection, NSView) -> Void = { _, _ in }

    static var none: MenuPaneEvents { MenuPaneEvents() }
}

/// The pane drawn from plain values, a native macOS 26 menu in look (`docs/design/panel.md`): the problem row when
/// there is one, the three area rows with their tinted symbols, summaries, counts and chevrons, then the footer's commands
/// with their symbols and shortcuts. The highlight comes from ``MenuNavigation``, which the pointer and the keys move.
struct MenuPaneContent: View {
    let model: MenuPaneModel
    let navigation: MenuNavigation
    var events = MenuPaneEvents.none
    @ViewState private var isOptionHeld = false

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.problem {
                problemRow(problem)
                MenuSeparator()
            }
            ForEach(model.areas) { area in
                MenuAreaRow(area: area, isHighlighted: navigation.isHighlighted(.area(area.section)))
                    .menuPaneRow(.area(area.section), events: events)
                    .background { MenuAnchor { events.anchor(area.section, $0) } }
                    .modifier(FlyoutTopMark(isOpen: area.section == navigation.openArea))
            }
            if !model.areas.isEmpty {
                MenuSeparator()
            }
            footerRow(.checkNow, "Check Now", symbol: "arrow.clockwise", shortcut: "⌘R", subtitle: model.footer.subtitle)
                .keyboardShortcut("r")
            footerRow(.openWindow, "Open Window", symbol: "macwindow", shortcut: "⌘0")
                .keyboardShortcut("0")
            MenuSeparator()
            footerRow(.settings, "Settings…", symbol: "gearshape", shortcut: "⌘,")
                .keyboardShortcut(",")
            footerRow(.quit, isOptionHeld && model.easterEggs ? EggRules.optionQuit : "Quit", symbol: "power", shortcut: "⌘Q")
                .keyboardShortcut("q")
        }
        .padding(.vertical, MenuMetrics.edge)
        .frame(width: MenuMetrics.paneWidth)
        .fixedSize(horizontal: false, vertical: true)
        // Concentric to the window's corners: the tint fills the system's glass panel edge to edge.
        .background { MenuBackdropTint(shape: ConcentricRectangle()) }
        .onHover { inside in
            if !inside {
                events.leave()
            }
        }
        .onModifierKeysChanged(mask: .option) { _, keys in
            isOptionHeld = !keys.isEmpty
        }
    }

    /// The red row on top: the problem in the label color, and the pane that fixes it as its grey line.
    @ViewBuilder private func problemRow(_ problem: PanelModel.ProblemItem) -> some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProblemSymbol()
                .frame(width: MenuMetrics.paneSymbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: problem.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let help = problem.help {
                    MenuSecondaryText(help)
                        .font(.subheadline)
                }
            }
            Spacer(minLength: 0)
        }
        if problem.pane != nil {
            content
                .menuRow(isHighlighted: navigation.isHighlighted(.problem))
                .menuPaneRow(.problem, events: events)
        } else {
            content
                .menuRow(isHighlighted: false)
        }
    }

    /// A footer command: its symbol in the areas' symbol column, so the titles line up with the areas', its title, the grey
    /// line Check Now has, and the shortcut on the right, as a native menu item.
    private func footerRow(
        _ row: MenuNavigation.PaneRow, _ title: String, symbol: String, shortcut: String, subtitle: String? = nil
    ) -> some View {
        let isHighlighted = navigation.isHighlighted(row)
        return HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: MenuMetrics.paneSymbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                if let subtitle {
                    MenuSecondaryText(subtitle)
                        .font(.subheadline)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            MenuSecondaryText(shortcut)
        }
        .menuRow(isHighlighted: isHighlighted)
        .menuPaneRow(row, events: events)
    }
}

/// An area's overview row: its symbol in the area's hue, the title (with the red marker while it has a problem), the summary in grey with
/// small colored symbols, the count or a spinner while it loads, and the chevron of its flyout.
struct MenuAreaRow: View {
    let area: MenuArea
    let isHighlighted: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            MenuAreaIcon(section: area.section)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(verbatim: area.title)
                    if let problem = area.problem {
                        ProblemSymbol()
                            .help(problem)
                    }
                }
                MenuSummaryLine(parts: area.summary)
                    .font(.callout)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            trailing
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        }
        .frame(minHeight: MenuMetrics.areaRowHeight)
        .menuRow(isHighlighted: isHighlighted)
        .accessibilityElement(children: .combine)
        .accessibilityHint(area.problem ?? "")
    }

    /// The count, or a spinner while a load runs: a native menu item's badge.
    @ViewBuilder private var trailing: some View {
        if area.isLoading {
            // Light on the highlight's accent color.
            DelayedSpinner(isActive: true)
                .controlSize(.mini)
                .environment(\.colorScheme, isHighlighted ? .dark : colorScheme)
        } else if let count = area.count {
            Text(verbatim: String(count))
                .monospacedDigit()
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .fixedSize()
        }
    }
}

/// An area's summary in one line: the pill apart, the counts as one text so the line cuts at its end with "…".
struct MenuSummaryLine: View {
    let parts: [MenuSummaryPart]
    @Environment(\.menuHighlighted) private var isHighlighted

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(pills.enumerated()), id: \.offset) { _, label in
                LabelPill(label: label, style: .compact)
                    .fixedSize()
            }
            text
                .lineLimit(1)
        }
    }

    private var pills: [LabelPillModel] {
        parts.compactMap {
            if case .pill(let label) = $0 { label } else { nil }
        }
    }

    /// The counts and notes joined with " · ", each count's symbol in its color before it.
    private var text: Text {
        // The vibrant secondary label style at full strength, as a native menu item's subtitle; white on the highlight.
        let grey = isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)
        var line = Text(verbatim: "")
        var first = true
        for part in parts {
            let piece: Text
            switch part {
            case .count(let symbol?, let tint, let text):
                let color = isHighlighted ? Color.white : (tint?.color ?? .secondary)
                let image = Text(Image(systemName: symbol)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
                piece = Text("\(image)\(Text(verbatim: "\u{2009}"))\(Text(verbatim: text).foregroundStyle(grey))")
            case .count(nil, _, let text), .note(let text):
                piece = Text(verbatim: text).foregroundStyle(grey)
            case .pill:
                continue
            }
            line = first ? piece : Text("\(line)\(Text(verbatim: " · ").foregroundStyle(grey))\(piece)")
            first = false
        }
        return line
    }
}

/// The app's red problem marker (`Marker.problem`), white while its row is highlighted.
struct ProblemSymbol: View {
    @Environment(\.menuHighlighted) private var isHighlighted

    var body: some View {
        Image(systemName: Marker.problem)
            .fontWeight(.semibold)
            .foregroundStyle(isHighlighted ? Color.white : .red)
            .accessibilityLabel("Problem")
    }
}

extension View {
    /// Makes a view a pane row: a button for clicks and VoiceOver, which reports the pointer on it to the pane.
    func menuPaneRow(_ row: MenuNavigation.PaneRow, events: MenuPaneEvents) -> some View {
        Button {
            events.activate(row)
        } label: {
            self
        }
        .buttonStyle(MenuRowButtonStyle())
        .onContinuousHover { phase in
            if case .active = phase {
                events.hover(row)
            }
        }
    }
}

/// A menu row's button: the row draws its own highlight, so the style adds nothing but the press.
struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension VerticalAlignment {
    /// The top of the area row whose flyout is open, and the top of the flyout's first row: the gallery lines the two
    /// up, as the real flyout is put beside its row.
    enum MenuFlyoutTop: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[.top]
        }
    }

    static let menuFlyoutTop = VerticalAlignment(MenuFlyoutTop.self)
}

/// Marks the open area's row for ``VerticalAlignment/menuFlyoutTop``; other rows leave the guide alone.
private struct FlyoutTopMark: ViewModifier {
    let isOpen: Bool

    func body(content: Content) -> some View {
        if isOpen {
            content.alignmentGuide(.menuFlyoutTop) { $0[.top] }
        } else {
            content
        }
    }
}
