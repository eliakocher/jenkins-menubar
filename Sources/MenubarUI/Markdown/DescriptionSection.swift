import MenubarCore
import SwiftUI

/// The detail's Description section (WIN-02): the selected merge request's or work item's description as rendered
/// Markdown, cut after about 20 lines with "Show More". It loads when the item is selected; while it loads, a
/// skeleton; when it fails, a quiet line with "Try Again"; an empty description shows no section at all.
///
/// It takes the description from `AppModel.descriptions`, or from the gallery's ``DescriptionFixtures``, so the details
/// insert it as one view: `DescriptionSection(source: DescriptionSource(item))`.
struct DescriptionSection: View {
    let source: DescriptionSource
    /// whether it is a card of the merge request detail's ScrollView rather than a `Form`'s section
    var inCard = false

    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.descriptionFixtures) private var fixtures
    /// the item last asked for, so that a failure line or a spinner appearing for the same item doesn't ask again
    @ViewState private var asked: DescriptionSource?

    var body: some View {
        let description = fixtures?.descriptions[source.reference] ?? model?.descriptions.description(of: source)
            ?? .loaded("")
        // A first heading that repeats the card's title is dropped.
        let document = description.text.map {
            MarkdownDocument(parsing: $0, base: source.webURL).droppingLeadingHeading(titled: "Description")
        }
        if let document, !document.isEmpty {
            container(showsSizeButtons: true) {
                CollapsibleMarkdown(document: document, startsExpanded: fixtures?.expanded ?? false)
                    .id(source.reference)
                    .task(id: source) { await load() }
            }
        } else if description.isCurrent {
            // An empty description: no header either.
        } else if description.failed {
            container {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("The description couldn't be loaded")
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        asked = nil
                        Task { await load() }
                    }
                    .buttonStyle(.link)
                }
                .task(id: source) { await load() }
            }
        } else {
            container {
                // Skeleton lines in the card's own chrome, about as tall as a short description.
                SkeletonLines(count: 4)
                    .task(id: source) { await load() }
            }
        }
    }

    /// A `Form`'s section, or the merge request detail's card.
    @ViewBuilder
    private func container(showsSizeButtons: Bool = false, @ViewBuilder _ content: () -> some View) -> some View {
        if inCard {
            DetailCard("Description", symbol: "text.alignleft", width: .fullWidth, content: content) {
                if showsSizeButtons {
                    MarkdownSizeButtons()
                }
            }
        } else {
            Section {
                content()
            } header: {
                HStack {
                    Text("Description")
                    Spacer(minLength: 8)
                    if showsSizeButtons {
                        MarkdownSizeButtons()
                    }
                }
            }
        }
    }

    /// Asks the store once per item and update: a new selection or a newer update of the item asks again.
    private func load() async {
        guard fixtures == nil, let model, asked != source else {
            return
        }
        asked = source
        await model.descriptions.load(source)
    }
}

/// The description cut to about 20 lines behind a soft fade, with "Show More" and "Show Less". A description only a few
/// lines longer isn't cut.
struct CollapsibleMarkdown: View {
    let document: MarkdownDocument

    @ViewState private var isExpanded: Bool
    /// the height of the whole description, at the width it gets
    @ViewState private var fullHeight: CGFloat = 0

    @AppStorage(MarkdownReadingSize.key) private var sizeStep = MarkdownReadingSize.defaultStep

    /// the lines after which the text is cut: 20 for a description, fewer for a comment
    private let lines: Int
    /// about `lines` lines of body text, at the reading size
    private var cutHeight: CGFloat { CGFloat(lines) * 16 * scale }
    /// a text that ends within a few more lines shows whole: 4 after 20 lines, 1 after 4
    private var slack: CGFloat { CGFloat(max(1, lines / 5)) * 16 * scale }
    private var fadeHeight: CGFloat { lines < 8 ? 28 : 56 }

    private var scale: CGFloat { MarkdownReadingSize.scale(forStep: sizeStep) }

    init(document: MarkdownDocument, startsExpanded: Bool, lines: Int = 20) {
        self.document = document
        self.lines = lines
        _isExpanded = ViewState(initialValue: startsExpanded)
    }

    private var isCuttable: Bool { fullHeight > cutHeight + slack }
    private var isCut: Bool { isCuttable && !isExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MarkdownView(document: document)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                .frame(height: isCut ? cutHeight : nil, alignment: .top)
                .clipped()
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        if isCut {
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: fadeHeight)
                        }
                    }
                }
            if isCuttable {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Show Less" : "Show More")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .imageScale(.small)
                    }
                }
                .buttonStyle(.link)
            }
        }
    }
}

/// The descriptions the gallery shows in place of the store's, by reference, and whether they show whole.
struct DescriptionFixtures: Sendable {
    var descriptions: [String: ItemDescription]
    var expanded = false
}

private struct DescriptionFixturesKey: EnvironmentKey {
    static let defaultValue: DescriptionFixtures? = nil
}

extension EnvironmentValues {
    /// the gallery's descriptions; `nil` in the app, which takes the store's
    var descriptionFixtures: DescriptionFixtures? {
        get { self[DescriptionFixturesKey.self] }
        set { self[DescriptionFixturesKey.self] = newValue }
    }
}
