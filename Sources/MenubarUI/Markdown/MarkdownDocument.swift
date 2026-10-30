import Foundation
import Markdown

/// A description's Markdown as the blocks ``MarkdownView`` draws, with the safety rules applied (WIN-02).
///
/// Parsed by swift-markdown (GitHub Flavored Markdown: tables, task lists, strikethrough). The rules:
/// - a link is a link only when it resolves to an `http` or `https` URL; any other scheme, `menubar-monitor://` and
///   `file:` included, shows its text as plain text;
/// - an image is never loaded: it becomes a link to its URL, under the same rule;
/// - raw HTML shows as text, never rendered. HTML comments are left out, as GitLab hides them (the templates' hints),
///   and `<br>` breaks the line, as it does in GitLab's table cells.
///
/// The inline text carries Foundation's attributes only: `link` and `inlinePresentationIntent`. The view styles them.
struct MarkdownDocument: Hashable, Sendable {
    var blocks: [MarkdownBlock]

    /// whether nothing is left to show
    var isEmpty: Bool { blocks.isEmpty }

    /// - Parameters:
    ///   - text: the Markdown
    ///   - base: the item's page, which relative links and images resolve against; `nil` keeps them as text
    init(parsing text: String, base: URL?) {
        let converter = MarkdownConverter(base: base)
        blocks = converter.blocks(Document(parsing: text).children)
    }

    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    /// The document without its first block when that is a heading with the text of `title`, compared without regard to
    /// case and surrounding space: a description that starts with "Description" under a card titled "Description".
    func droppingLeadingHeading(titled title: String) -> MarkdownDocument {
        guard case .heading(_, let text)? = blocks.first else {
            return self
        }
        let heading = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard heading.compare(title.trimmingCharacters(in: .whitespacesAndNewlines), options: .caseInsensitive) == .orderedSame
        else {
            return self
        }
        return MarkdownDocument(blocks: Array(blocks.dropFirst()))
    }

    /// Returns whether a URL may open in the browser: `http` and `https` with a host.
    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return url.host() != nil
    }
}

/// A block of a description.
indirect enum MarkdownBlock: Hashable, Sendable {
    /// `#` to `######`, level 1 to 6
    case heading(level: Int, AttributedString)
    case paragraph(AttributedString)
    case list(MarkdownList)
    /// a fenced or indented code block, without its last line break
    case code(language: String?, String)
    case quote([MarkdownBlock])
    case table(MarkdownTable)
    /// raw HTML, shown as text
    case rawText(String)
    case rule
}

/// A bulleted, numbered or task list.
struct MarkdownList: Hashable, Sendable {
    /// whether the items are numbered, from `start`
    var isOrdered: Bool
    var start: Int
    var items: [Item]

    struct Item: Hashable, Sendable {
        /// `- [ ]` is false, `- [x]` true; `nil` for an item without a box
        var isChecked: Bool?
        var blocks: [MarkdownBlock]
    }
}

/// A table, its cells as inline text.
struct MarkdownTable: Hashable, Sendable {
    enum Alignment: Hashable, Sendable {
        case leading, center, trailing
    }

    /// one per column
    var alignments: [Alignment]
    var header: [AttributedString]
    /// each as wide as `alignments`, filled with empty cells
    var rows: [[AttributedString]]
}

/// Turns swift-markdown's tree into ``MarkdownBlock`` values.
private struct MarkdownConverter {
    let base: URL?

    func blocks(_ children: MarkupChildren) -> [MarkdownBlock] {
        children.compactMap(block)
    }

    private func block(_ markup: any Markup) -> MarkdownBlock? {
        switch markup {
        case let heading as Heading:
            return .heading(level: heading.level, inline(heading.children))
        case let paragraph as Paragraph:
            let text = inline(paragraph.children)
            return text.characters.allSatisfy(\.isWhitespace) ? nil : .paragraph(text)
        case let list as UnorderedList:
            return .list(MarkdownList(isOrdered: false, start: 1, items: list.listItems.map(item)))
        case let list as OrderedList:
            return .list(MarkdownList(isOrdered: true, start: Int(list.startIndex), items: list.listItems.map(item)))
        case let code as CodeBlock:
            var text = code.code
            if text.hasSuffix("\n") {
                text.removeLast()
            }
            let language = code.language.flatMap { $0.isEmpty ? nil : $0 }
            return .code(language: language, text)
        case let quote as BlockQuote:
            let inner = blocks(quote.children)
            return inner.isEmpty ? nil : .quote(inner)
        case let table as Markdown.Table:
            return .table(self.table(table))
        case let html as HTMLBlock:
            let text = Self.withoutComments(html.rawHTML).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .rawText(text)
        case is ThematicBreak:
            return .rule
        default:
            // Block directives and the like aren't parsed with the default options; anything else shows as its source.
            let text = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .rawText(text)
        }
    }

    private func item(_ item: ListItem) -> MarkdownList.Item {
        MarkdownList.Item(isChecked: item.checkbox.map { $0 == .checked }, blocks: blocks(item.children))
    }

    private func table(_ table: Markdown.Table) -> MarkdownTable {
        let alignments: [MarkdownTable.Alignment] = table.columnAlignments.map {
            switch $0 {
            case .center: .center
            case .right: .trailing
            case .left, nil: .leading
            }
        }
        let width = alignments.count
        func cells(_ cells: some Sequence<Markdown.Table.Cell>) -> [AttributedString] {
            var row = cells.map { inline($0.children) }
            if row.count < width {
                row += Array(repeating: AttributedString(), count: width - row.count)
            }
            return Array(row.prefix(max(width, 1)))
        }
        return MarkdownTable(alignments: alignments, header: cells(table.head.cells), rows: table.body.rows.map { cells($0.cells) })
    }

    // MARK: - Inline text

    private func inline(_ children: MarkupChildren) -> AttributedString {
        children.reduce(into: AttributedString()) { $0 += inline($1) }
    }

    private func inline(_ markup: any Markup) -> AttributedString {
        switch markup {
        case let text as Markdown.Text:
            return Self.linkingWebAddresses(in: text.string)
        case is SoftBreak:
            return AttributedString(" ")
        case is LineBreak:
            return AttributedString("\n")
        case let code as InlineCode:
            return AttributedString(code.code, attributes: AttributeContainer().inlinePresentationIntent(.code))
        case let emphasis as Emphasis:
            return adding(.emphasized, to: inline(emphasis.children))
        case let strong as Strong:
            return adding(.stronglyEmphasized, to: inline(strong.children))
        case let strikethrough as Strikethrough:
            return adding(.strikethrough, to: inline(strikethrough.children))
        case let link as Markdown.Link:
            let text = inline(link.children)
            guard let url = resolve(link.destination) else {
                return text
            }
            var linked = text.characters.isEmpty ? AttributedString(url.absoluteString) : text
            linked.link = url
            return linked
        case let image as Markdown.Image:
            return imageLink(image)
        case let html as InlineHTML:
            return AttributedString(Self.inlineHTML(html.rawHTML))
        default:
            // Inline attributes, symbol links and the like: their text.
            return AttributedString((markup as? any PlainTextConvertibleMarkup)?.plainText ?? markup.format())
        }
    }

    /// "Image: shot.png" as a link to the image, which is never loaded: GitLab's uploads need the user's login. The
    /// alt text names it, or the file name when the alt text is empty or GitLab's default "image".
    private func imageLink(_ image: Markdown.Image) -> AttributedString {
        let url = resolve(image.source)
        let alt = image.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = url?.lastPathComponent ?? image.source.map { ($0 as NSString).lastPathComponent } ?? ""
        let name = alt.isEmpty || alt.caseInsensitiveCompare("image") == .orderedSame ? fileName : alt
        var text = AttributedString("Image: \(name.isEmpty ? "untitled" : name)")
        text.link = url
        return text
    }

    private func adding(_ intent: InlinePresentationIntent, to text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs {
            text[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(intent)
        }
        return text
    }

    // MARK: - Links

    /// Returns the URL a link or image opens: absolute, or resolved against the item's page as GitLab does; `nil`
    /// when it isn't `http` or `https`, which shows it as text.
    func resolve(_ destination: String?) -> URL? {
        guard let destination = destination?.trimmingCharacters(in: .whitespaces), !destination.isEmpty else {
            return nil
        }
        let url: URL?
        if let absolute = URL(string: destination), absolute.scheme != nil {
            url = absolute
        } else if let base {
            url = Self.resolve(destination, against: base)
        } else {
            url = nil
        }
        return url.flatMap { MarkdownDocument.isWebURL($0) ? $0 : nil }
    }

    /// GitLab's uploads, `/uploads/…`, belong to the project (`<project>/uploads/…`) or the group
    /// (`groups/<group>/-/uploads/…`); other paths that start with `/` belong to the host; the rest to the project.
    private static func resolve(_ destination: String, against base: URL) -> URL? {
        let page = base.absoluteString
        let root = page.range(of: "/-/").map { String(page[..<$0.lowerBound]) } ?? page
        if destination.hasPrefix("/uploads/") {
            let isGroup = (URL(string: root)?.path() ?? "").hasPrefix("/groups/")
            return URL(string: root + (isGroup ? "/-" : "") + destination)
        }
        if destination.hasPrefix("//") || destination.hasPrefix("/") {
            return URL(string: destination, relativeTo: base)?.absoluteURL
        }
        if destination.hasPrefix("#") {
            return URL(string: page + destination)
        }
        return URL(string: destination, relativeTo: URL(string: root + "/"))?.absoluteURL
    }

    /// Plain text with its `http` and `https` addresses as links, as GitLab links them.
    private static func linkingWebAddresses(in string: String) -> AttributedString {
        guard string.contains("http") || string.contains("www."),
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else {
            return AttributedString(string)
        }
        var text = AttributedString()
        var rest = string.startIndex
        for match in detector.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
            guard let url = match.url, MarkdownDocument.isWebURL(url), let range = Range(match.range, in: string),
                range.lowerBound >= rest
            else {
                continue
            }
            text += AttributedString(string[rest..<range.lowerBound])
            var linked = AttributedString(string[range])
            linked.link = url
            text += linked
            rest = range.upperBound
        }
        text += AttributedString(string[rest...])
        return text
    }

    // MARK: - HTML

    /// Raw inline HTML as text: a comment is left out, `<br>` breaks the line.
    private static func inlineHTML(_ html: String) -> String {
        if html.hasPrefix("<!--") {
            return ""
        }
        let tag = html.lowercased().replacingOccurrences(of: " ", with: "")
        return ["<br>", "<br/>"].contains(tag) ? "\n" : html
    }

    /// An HTML block without its comments, which GitLab hides.
    static func withoutComments(_ html: String) -> String {
        html.replacing(/<!--[\s\S]*?(-->|\z)/, with: "")
    }
}
