import SwiftUI

/// Where ``SectionNav`` jumps to: a ``DetailCard`` is `id`'d by its title.
struct SectionTarget: Hashable {
    let title: String
}

/// The titles of the cards a page shows, in the order of the page; every ``DetailCard`` adds its own.
struct SectionTitlesKey: PreferenceKey {
    static let defaultValue: [String] = []

    static func reduce(value: inout [String], nextValue: () -> [String]) {
        value += nextValue()
    }
}

/// The cards a page shows and how to jump to one; set by ``View/sectionNavigation(proxy:)``, read by ``SectionNav``.
struct SectionNavContext: @unchecked Sendable {
    var titles: [String] = []
    var jump: (String) -> Void = { _ in }
}

private struct SectionNavKey: EnvironmentKey {
    static let defaultValue = SectionNavContext()
}

extension EnvironmentValues {
    var sectionNav: SectionNavContext {
        get { self[SectionNavKey.self] }
        set { self[SectionNavKey.self] = newValue }
    }
}

private struct SectionNavigation: ViewModifier {
    let proxy: ScrollViewProxy
    @ViewState private var titles: [String] = []

    func body(content: Content) -> some View {
        content
            .environment(
                \.sectionNav,
                SectionNavContext(titles: titles) { title in
                    withAnimation(.snappy) { proxy.scrollTo(SectionTarget(title: title), anchor: .top) }
                }
            )
            .onPreferenceChange(SectionTitlesKey.self) { titles = $0 }
    }
}

extension View {
    /// Collects the titles of the ``DetailCard``s inside and lets a ``SectionNav`` inside jump to them with `proxy`.
    func sectionNavigation(proxy: ScrollViewProxy) -> some View {
        modifier(SectionNavigation(proxy: proxy))
    }
}

/// A quiet line of the cards a page shows, "Description · Claude · Changes", under a detail's header: each title jumps to
/// its card, secondary, in the accent color on hover. Nothing shows for fewer than two cards.
struct SectionNav: View {
    @Environment(\.sectionNav) private var nav

    var body: some View {
        let titles = nav.titles.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if titles.count >= 2 {
            PillFlowLayout(spacing: 0, lineSpacing: 2) {
                ForEach(Array(titles.enumerated()), id: \.element) { index, title in
                    HStack(spacing: 0) {
                        SectionNavButton(title: title) { nav.jump(title) }
                        if index < titles.count - 1 {
                            Text(verbatim: "·")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 2)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sections")
        }
    }
}

private struct SectionNavButton: View {
    let title: String
    let action: () -> Void
    @ViewState private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.callout.weight(.medium))
                .foregroundStyle(isHovered ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Jump to \(title)")
    }
}
