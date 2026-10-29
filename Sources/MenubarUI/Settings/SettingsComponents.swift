import AppKit
import MenubarCore
import SwiftUI

/// What a ``StatusLine`` says: it worked, a fact, or a problem (`docs/design/settings.md`, SF Symbols).
public enum StatusKind: Hashable, Sendable {
    /// it worked: signed in, stored, imported
    case ok
    /// a fact, neither ok nor a problem: no token yet, waiting for approval
    case note
    /// a problem
    case problem

    /// the SF Symbol's name
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle"
        case .note: "info.circle"
        case .problem: "exclamationmark.circle"
        }
    }

    /// the symbol's color; the text stays in the label color, so color is never alone
    var color: Color {
        switch self {
        case .ok: .green
        case .note: .secondary
        case .problem: .red
        }
    }
}

/// A status under the control it belongs to: a symbol and a text in the label color, `.callout`, wrapping, without an
/// ending period; an optional button trails it (`docs/design/settings.md`, Shared components).
public struct StatusLine<Trailing: View>: View {
    private let kind: StatusKind
    private let text: String
    private let trailing: Trailing

    /// - Parameters:
    ///   - kind: what it says
    ///   - text: the text, shown as it is
    ///   - trailing: a button after the text, like "Open System Settings…"
    public init(_ kind: StatusKind, _ text: String, @ViewBuilder trailing: () -> Trailing) {
        self.kind = kind
        self.text = text
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.color)
            // Primary also as a `LabeledContent`'s value, which would draw it secondary (review SETTINGS-ACCOUNTS-01).
            Text(verbatim: text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            // Without a button the line keeps its own width, so it can stand as a LabeledContent's value too.
            if Trailing.self != EmptyView.self {
                Spacer(minLength: 8)
                trailing
            }
        }
    }
}

extension StatusLine where Trailing == EmptyView {
    /// - Parameters:
    ///   - kind: what it says
    ///   - text: the text, shown as it is
    public init(_ kind: StatusKind, _ text: String) {
        self.init(kind, text) { EmptyView() }
    }
}

/// The live problems a pane fixes, at the top of the pane before its first section, in the panel's words; they go
/// when fixed (`docs/design/settings.md`, Problem rows). Nothing shows without problems.
public struct SettingsProblemRows: View {
    private let problems: [String]

    /// - Parameter problems: the problems' texts, in order
    public init(_ problems: [String]) {
        self.problems = problems
    }

    public var body: some View {
        if !problems.isEmpty {
            Section {
                ForEach(problems, id: \.self) { problem in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: StatusKind.problem.symbol)
                            .foregroundStyle(StatusKind.problem.color)
                        Text(verbatim: problem)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Returns the texts of the problems that a pane fixes, without repeats: Accounts for a rejected token or a missing
    /// scope, Team for the team values and an unknown job (SET-02). A missing token isn't one: Accounts' token row says
    /// "Missing" already.
    ///
    /// - Parameters:
    ///   - pane: the pane
    ///   - problems: the stores' current problems
    /// - Returns: the texts, in the order of the problems
    public static func texts(for pane: SettingsPane, from problems: [Problem?]) -> [String] {
        var texts: [String] = []
        for case let problem? in problems where SettingsPane.pane(for: problem) == pane {
            if case .noToken = problem {
                continue
            }
            if !texts.contains(problem.message) {
                texts.append(problem.message)
            }
        }
        return texts
    }
}

/// The sizes of the Settings window (`docs/design/settings.md`, Size).
enum SettingsMetrics {
    /// every pane's width
    static let width: CGFloat = 560
    /// what stays free of the screen's visible height for the window's title bar and pane toolbar
    static let screenMargin: CGFloat = 100

    /// Returns a pane's height before its form has measured itself: about its typical state's, so the window opens
    /// close to its size.
    static func estimate(of pane: SettingsPane) -> CGFloat {
        switch pane {
        case .general: 510
        case .jenkins: 310
        case .gitLab: 627
        case .repositories: 560
        case .team: 600
        case .accounts: 620
        }
    }

    /// the most a pane may be high: the screen's visible height without the window's bars; taller content, as with
    /// many labels, scrolls inside the form
    @MainActor static var cap: CGFloat {
        max(estimate(of: .jenkins), (NSScreen.main?.visibleFrame.height ?? 800) - screenMargin)
    }
}

/// A pane's frame in the Settings window: 560 pt wide and as high as its form's content, up to ``SettingsMetrics/cap``,
/// so the window takes each pane's height and grows when a status line appears, and nothing is cut at the bottom
/// (review SETTINGS-01).
///
/// The height is the form's ideal height, measured on the form itself at `fixedSize(vertical:)`, inside a scroll view
/// that gives it the room it asks for. That measurement can't depend on the frame this modifier sets, so the height
/// can't feed back into itself. The first version read the form's own scroll geometry instead: a form that scrolls
/// reports about 12 pt more than one that fits, so every resize changed the next reading, and in the real window that
/// loop made AppKit abort during layout (crash reports of 2026-10-29). Here the outer scroll view scrolls only when the
/// content is taller than ``SettingsMetrics/cap``; the form's own scroll view always has all the room it needs.
struct SettingsPaneFrame: ViewModifier {
    /// the height until the form has measured itself
    let estimate: CGFloat
    @ViewState private var height: CGFloat?

    func body(content: Content) -> some View {
        ScrollView {
            content
                .frame(width: SettingsMetrics.width)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { new in
                    // Rounded up, so a fractional height doesn't cut the last pixel; only a real change is stored.
                    let rounded = new.rounded(.up)
                    if height != rounded {
                        height = rounded
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: SettingsMetrics.width, height: min(height ?? estimate, SettingsMetrics.cap))
    }
}

/// Reports whether a view draws its content cut, narrower than it would be whole, so a tooltip can repeat the full text
/// only then, as an expansion tooltip does (review SETTINGS-03).
private struct TruncationReader: ViewModifier {
    @Binding var isCut: Bool
    @ViewState private var width: CGFloat = 0
    @ViewState private var idealWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                width = $0
                update()
            }
            .background {
                // The same view at its ideal width, never drawn.
                content
                    .fixedSize()
                    .hidden()
                    .accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                        idealWidth = $0
                        update()
                    }
            }
    }

    private func update() {
        let cut = idealWidth > width + 0.5
        if isCut != cut {
            isCut = cut
        }
    }
}

extension View {
    /// Sets `isCut` while the view is narrower than it would be whole, as a truncated text is.
    func readsTruncation(_ isCut: Binding<Bool>) -> some View {
        modifier(TruncationReader(isCut: isCut))
    }
}

/// Lays its subviews out in lines, left to right, starting a new line where the next one doesn't fit, like the label
/// pills of the GitLab pane. A subview wider than the line gets the line's width and truncates.
struct SettingsFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2), anchor: .topLeading,
                    proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> [Line] {
        let available = width ?? .infinity
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > available {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: available, height: nil))
                size.width = min(size.width, available)
            }
            let needed = line.items.isEmpty ? size.width : line.width + spacing + size.width
            if !line.items.isEmpty, needed > available {
                lines.append(line)
                line = Line()
            }
            line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.items.append((index, size))
        }
        if !line.items.isEmpty {
            lines.append(line)
        }
        return lines
    }
}
