import MenubarCore
import SwiftUI

/// The panel's metrics (`docs/design/panel.md`, Metrics).
enum PanelMetrics {
    /// the panel's fixed width
    static let width: CGFloat = 420
    /// the side margins of the rows
    static let margin: CGFloat = 12
    /// the symbol column, kept empty where a row has no symbol
    static let symbolColumn: CGFloat = 16
    /// the least height of a row
    static let rowHeight: CGFloat = 24
}

/// How long a load runs before its spinner shows: 1 s in the app (`docs/design/panel.md`, Sections), none in the
/// gallery, which takes its screenshots after 1 s.
struct PanelSpinnerDelayKey: EnvironmentKey {
    static let defaultValue: Duration = .seconds(1)
}

extension EnvironmentValues {
    var panelSpinnerDelay: Duration {
        get { self[PanelSpinnerDelayKey.self] }
        set { self[PanelSpinnerDelayKey.self] = newValue }
    }
}

/// A clickable row of the panel: full width, and on hover and press a system fill in a concentric shape, inset 6 pt
/// from the edges (`docs/design/panel.md`, Departures 2: no system menu-item row fits).
struct PanelRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelRowButtonBody(configuration: configuration)
    }
}

private struct PanelRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @ViewState private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .panelRowPadding()
            .contentShape(Rectangle())
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .background {
                if isHighlighted {
                    ConcentricRectangle(corners: .concentric(minimum: .fixed(6)), isUniform: true)
                        .fill(.fill.tertiary)
                        .padding(.horizontal, 6)
                }
            }
            .onHover { isHovered = $0 }
    }

    private var isHighlighted: Bool {
        guard isEnabled else {
            return false
        }
        return isHovered || configuration.isPressed
    }
}

extension View {
    /// The margins and the least height of a panel row, for rows that are buttons and rows that aren't alike.
    func panelRowPadding() -> some View {
        padding(.horizontal, PanelMetrics.margin)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, minHeight: PanelMetrics.rowHeight, alignment: .leading)
    }
}

/// A row's symbol column and its lines, first-baseline aligned.
struct PanelRowLayout<Symbol: View, Lines: View>: View {
    @ViewBuilder var symbol: Symbol
    @ViewBuilder var lines: Lines

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            symbol
                .frame(width: PanelMetrics.symbolColumn)
            VStack(alignment: .leading, spacing: 1) {
                lines
            }
            Spacer(minLength: 0)
        }
    }
}

/// One line of parts whose text comes from data, like a work item's reference, slot and title. No part's least width
/// depends on its text, so a long part can't push the row past the panel (review PANEL-03, PANEL-12). When the line
/// has room, every part shows whole. Otherwise a part with a cap (``SwiftUI/View/panelLineCap(_:)``) gets at most that
/// share of the line, a part without one keeps its width (only for fixed text, like " · "), and the last part gets
/// the rest; room the last part doesn't need goes back to the capped parts, in order. The parts truncate as their
/// `truncationMode` says and align on their first baselines.
struct PanelLineLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let parts = measure(proposal.width, subviews)
        let width = parts.reduce(0) { $0 + $1.width }
        return CGSize(width: min(width, proposal.width ?? width), height: Self.height(of: parts))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // The proposal, not the bounds: a line of cut parts can be a little narrower than the proposal, and the parts
        // must get the widths `sizeThatFits` gave them.
        let parts = measure(proposal.width ?? bounds.width, subviews)
        let ascent = parts.map { $0[.firstTextBaseline] }.max() ?? 0
        var x = bounds.minX
        for (subview, part) in zip(subviews, parts) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY + ascent - part[.firstTextBaseline]), anchor: .topLeading,
                proposal: ProposedViewSize(width: part.width, height: part.height))
            x += part.width
        }
    }

    /// Returns each part's dimensions at the width it gets.
    private func measure(_ width: CGFloat?, _ subviews: Subviews) -> [ViewDimensions] {
        guard let last = subviews.last else {
            return []
        }
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let widths = Self.widths(ideals: ideals, caps: subviews.map { $0[PanelLineCapKey.self] }, width: width)
        var parts = zip(subviews.dropLast(), widths).map { $0.dimensions(in: ProposedViewSize(width: $1, height: nil)) }
        // A cut text is a little narrower than its room, since it ends at a whole character, so the last part gets what
        // the others leave.
        let rest = width.map { max(0, $0 - parts.reduce(0) { $0 + $1.width }) } ?? ideals[ideals.count - 1]
        parts.append(last.dimensions(in: ProposedViewSize(width: min(rest, ideals[ideals.count - 1]), height: nil)))
        return parts
    }

    /// Returns the width each part gets.
    ///
    /// - Parameters:
    ///   - ideals: each part's whole width
    ///   - caps: each part's cap, a share of the line from 0 to 1; `nil` for none
    ///   - width: the line's width; `nil` for as wide as the parts want
    /// - Returns: the parts' widths, together no wider than `width` unless the parts without a cap alone are
    private static func widths(ideals: [CGFloat], caps: [CGFloat?], width: CGFloat?) -> [CGFloat] {
        guard let width, ideals.reduce(0, +) > width, let last = ideals.indices.last else {
            return ideals
        }
        var widths = ideals
        for index in ideals.indices.dropLast() {
            if let cap = caps[index] {
                widths[index] = min(ideals[index], max(0, cap * width))
            }
        }
        let rest = max(0, width - widths[..<last].reduce(0, +))
        widths[last] = min(rest, ideals[last])
        var spare = rest - widths[last]
        for index in ideals.indices.dropLast() where caps[index] != nil && spare > 0 {
            let more = min(spare, ideals[index] - widths[index])
            widths[index] += more
            spare -= more
        }
        return widths
    }

    /// Returns the line's height: the parts aligned on their first baselines.
    private static func height(of parts: [ViewDimensions]) -> CGFloat {
        let ascent = parts.map { $0[.firstTextBaseline] }.max() ?? 0
        let descent = parts.map { $0.height - $0[.firstTextBaseline] }.max() ?? 0
        return ascent + descent
    }
}

/// The share of a ``PanelLineLayout`` a part takes at most when the line is short of room; `nil` for none.
private struct PanelLineCapKey: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}

extension View {
    /// Caps a part of a ``PanelLineLayout`` at a share of the line, for when the line is short of room.
    ///
    /// - Parameter share: the most of the line the part takes, from 0 to 1
    /// - Returns: the part, with its cap
    func panelLineCap(_ share: CGFloat) -> some View {
        layoutValue(key: PanelLineCapKey.self, value: share)
    }
}

/// A small spinner that shows only after a load has run for a while, so quick loads don't flicker
/// (`docs/design/panel.md`, Sections).
struct DelayedSpinner: View {
    let isActive: Bool
    @Environment(\.panelSpinnerDelay) private var delay
    @ViewState private var isShown = false

    var body: some View {
        // A ZStack with a zero-size view always exists, so its task runs even while the spinner doesn't show; an empty
        // Group would never start it.
        ZStack {
            Color.clear
                .frame(width: 0, height: 0)
            if isShown {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: isActive) {
            guard isActive else {
                isShown = false
                return
            }
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            isShown = !Task.isCancelled
        }
    }
}
