import MenubarCore
import SwiftUI

/// The detail's Description section (WIN-02): the selected merge request's or work item's description as rendered
/// Markdown, cut after about 20 lines with "Show More". It loads when the item is selected; while it loads, a small
/// spinner; when it fails, a quiet line with "Try Again"; an empty description shows no section at all.
///
/// It takes the description from `AppModel.descriptions`, or from the gallery's ``DescriptionFixtures``, so the details
/// insert it as one view: `DescriptionSection(source: DescriptionSource(item))`.
struct DescriptionSection: View {
    let source: DescriptionSource

    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.descriptionFixtures) private var fixtures
    /// the item last asked for, so that a failure line or a spinner appearing for the same item doesn't ask again
    @ViewState private var asked: DescriptionSource?

    var body: some View {
        let description = fixtures?.descriptions[source.reference] ?? model?.descriptions.description(of: source)
            ?? .loaded("")
        let document = description.text.map { MarkdownDocument(parsing: $0, base: source.webURL) }
        if let document, !document.isEmpty {
            Section("Description") {
                CollapsibleMarkdown(document: document, startsExpanded: fixtures?.expanded ?? false)
                    .id(source.reference)
                    .task(id: source) { await load() }
            }
        } else if description.isCurrent {
            // An empty description: no header either.
        } else if description.failed {
            Section("Description") {
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
            Section("Description") {
                // A small spinner in the part still loading, never over the pane (OD-01).
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .task(id: source) { await load() }
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
private struct CollapsibleMarkdown: View {
    let document: MarkdownDocument

    @ViewState private var isExpanded: Bool
    /// the height of the whole description, at the width it gets
    @ViewState private var fullHeight: CGFloat = 0

    /// about 20 lines of body text
    private static let cutHeight: CGFloat = 20 * 16
    /// a description that ends within about 4 more lines shows whole
    private static let slack: CGFloat = 4 * 16
    private static let fadeHeight: CGFloat = 56

    init(document: MarkdownDocument, startsExpanded: Bool) {
        self.document = document
        _isExpanded = ViewState(initialValue: startsExpanded)
    }

    private var isCuttable: Bool { fullHeight > Self.cutHeight + Self.slack }
    private var isCut: Bool { isCuttable && !isExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MarkdownView(document: document)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                .frame(height: isCut ? Self.cutHeight : nil, alignment: .top)
                .clipped()
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        if isCut {
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: Self.fadeHeight)
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
