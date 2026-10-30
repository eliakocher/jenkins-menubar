import MenubarCore
import SwiftUI

/// A detail column as a scrolling page in the merge request detail's language: the header and the cards stacked with
/// 24 pt between them, 20 pt from the edges, the full width used or the limit of Settings → General's Content Width. Another item starts at the top, with its own
/// disclosures; the content gets the scroll proxy, so a header chip can jump to its card.
struct DetailPage<Content: View>: View {
    /// the shown item: a new one scrolls back to the top
    let id: AnyHashable
    @ViewBuilder var content: (ScrollViewProxy) -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    content(proxy)
                }
                .sectionNavigation(proxy: proxy)
                .pageContentWidth()
            }
            .id(id)
        }
    }
}

/// The header of a detail page, as the merge request and build details have it: a top line with the state badge and the
/// reference, the ⋯ menu at its end; the title, large, wrapping and selectable; a byline, such as the people and the
/// age; the chips that link or jump, wrapping when narrow; and a quiet footer, such as the labels.
struct DetailHeader<Badges: View, MenuItems: View, Byline: View, Chips: View, Footer: View>: View {
    let title: String
    /// the full title, for the tooltip, when the shown one is shortened
    var titleHelp: String?
    /// the top line's start: the state badge, the reference, a tag
    @ViewBuilder var badges: Badges
    /// the ⋯ menu's items; an empty builder shows no menu
    @ViewBuilder var menu: MenuItems
    @ViewBuilder var byline: Byline
    /// the chips, each a ``DetailChip``, laid out in lines
    @ViewBuilder var chips: Chips
    @ViewBuilder var footer: Footer

    var body: some View {
        // A part with nothing in it, such as a chip strip without chips, takes no room and no gap.
        CollapsingStack(spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                badges
                Spacer(minLength: 8)
                if MenuItems.self != EmptyView.self {
                    DetailMoreMenu { menu }
                }
            }
            Text(verbatim: title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(titleHelp ?? "")
            byline
            PillFlowLayout(spacing: 6, lineSpacing: 6) {
                chips
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            footer
            SectionNav()
                .padding(.leading, -6)
        }
    }
}

/// The parts of a header from top to bottom, leading-aligned, the full width each; a part of no height gets no gap.
private struct CollapsingStack: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width
        var height: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            guard size.height > 0 else { continue }
            height += (height > 0 ? spacing : 0) + size.height
            widest = max(widest, size.width)
        }
        return CGSize(width: width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        var placed = false
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if size.height > 0, placed {
                y += spacing
            }
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: size.height))
            if size.height > 0 {
                y += size.height
                placed = true
            }
        }
    }
}

/// The header's ⋯ menu: the links and actions the chips and the toolbar don't show.
struct DetailMoreMenu<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

/// People as overlapping avatars, then their names: "Alex Doe", "Alex Doe and Jane Kim", "Alex Doe and 2 others". Each
/// avatar is cut out of the one before by a ring of the background, as the system's stacks of people are.
struct PeopleLine: View {
    let people: [MergeRequest.Person]
    var size: CGFloat = 18
    /// the most avatars shown; the names say how many more
    var maxAvatars = 4

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: -size * 0.2) {
                ForEach(Array(people.prefix(maxAvatars).enumerated()), id: \.offset) { index, person in
                    InitialsAvatar(name: person.name, username: person.username, size: size)
                        .background(Circle().fill(.background).padding(-1.5))
                        .zIndex(Double(index))
                }
            }
            Text(verbatim: Self.names(people))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(people.map(\.displayName).formatted(.list(type: .and)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(people.map(\.displayName).formatted(.list(type: .and)))
    }

    /// "Alex Doe", "Alex Doe and Jane Kim", "Alex Doe and 2 others"
    static func names(_ people: [MergeRequest.Person]) -> String {
        switch people.count {
        case 0: ""
        case 1: people[0].displayName
        case 2: "\(people[0].displayName) and \(people[1].displayName)"
        default: "\(people[0].displayName) and \(people.count - 1) others"
        }
    }
}

extension View {
    /// Puts a detail's main link in the window's toolbar, as the merge request and build details do: "Open in GitLab",
    /// "Open Build".
    ///
    /// - Parameters:
    ///   - title: the button's title
    ///   - help: the tooltip, like "Open Work Item #31"
    ///   - action: opens the page
    func detailPrimaryAction(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: action) {
                    Label(title, systemImage: "arrow.up.forward.app")
                }
                .help(help)
            }
        }
    }
}
