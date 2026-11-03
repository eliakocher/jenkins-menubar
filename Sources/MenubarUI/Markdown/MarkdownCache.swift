import AppKit
import SwiftUI

/// Parsed and styled Markdown, kept by its source text, so that a view's `body` only looks it up (WIN-02): a detail's
/// clock, a hover or a streaming answer redraws without parsing again.
@MainActor
enum MarkdownCache {
    private final class Box<Value>: NSObject {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private static let documents: NSCache<NSString, Box<MarkdownDocument>> = {
        let cache = NSCache<NSString, Box<MarkdownDocument>>()
        cache.countLimit = 400
        // About as many characters as the texts kept: a few hundred long descriptions.
        cache.totalCostLimit = 8_000_000
        return cache
    }()

    private static let searches: NSCache<NSString, Box<(MarkdownDocument, Int)>> = {
        let cache = NSCache<NSString, Box<(MarkdownDocument, Int)>>()
        cache.countLimit = 40
        return cache
    }()

    private static let code: NSCache<NSString, Box<AttributedString>> = {
        let cache = NSCache<NSString, Box<AttributedString>>()
        cache.countLimit = 400
        cache.totalCostLimit = 4_000_000
        return cache
    }()

    /// Returns the document for a text, parsed and styled the first time it is asked for.
    ///
    /// - Parameters:
    ///   - text: the Markdown
    ///   - base: the item's page, which relative links and references resolve against
    /// - Returns: the styled document
    static func document(_ text: String, base: URL?) -> MarkdownDocument {
        let key = "\(base?.absoluteString ?? "")\u{1}\(text)" as NSString
        if let found = documents.object(forKey: key) {
            return found.value
        }
        let document = MarkdownDocument(parsing: text, base: base).styledForDisplay()
        documents.setObject(Box(document), forKey: key, cost: text.utf16.count)
        return document
    }

    /// Returns the document for a text with the words of a search marked, and how many marks there are.
    static func searched(_ text: String, base: URL?, query: String) -> (document: MarkdownDocument, matches: Int) {
        let document = document(text, base: base)
        guard !query.allSatisfy(\.isWhitespace) else {
            return (document, 0)
        }
        let key = "\(query)\u{1}\(base?.absoluteString ?? "")\u{1}\(text)" as NSString
        if let found = searches.object(forKey: key) {
            return found.value
        }
        let found = document.highlighting(query)
        searches.setObject(Box((found.document, found.matches)), forKey: key)
        return found
    }

    /// Returns a code block's text in the colors of its language.
    static func highlighted(_ text: String, language: String?) -> AttributedString {
        let key = "\(language ?? "")\u{1}\(text)" as NSString
        if let found = code.object(forKey: key) {
            return found.value
        }
        let highlighted = MarkdownSyntax.highlight(text, language: language)
        code.setObject(Box(highlighted), forKey: key, cost: text.utf16.count)
        return highlighted
    }
}

extension MarkdownDocument {
    /// The document of a text, parsed and styled once per text and kept: what the views show.
    @MainActor
    static func rendered(_ text: String, base: URL?) -> MarkdownDocument {
        MarkdownCache.document(text, base: base)
    }

    /// The document with the inline styles the view draws: inline code on a soft fill in the code color, references
    /// as tinted chips, mentions in the accent color. A search's marks, added later, go over them.
    func styledForDisplay() -> MarkdownDocument {
        MarkdownDocument(blocks: blocks.map(Self.styled))
    }

    private static func styled(_ block: MarkdownBlock) -> MarkdownBlock {
        switch block {
        case .heading(let level, let text):
            return .heading(level: level, styled(text))
        case .paragraph(let text):
            return .paragraph(styled(text))
        case .list(var list):
            list.items = list.items.map { item in
                var item = item
                item.blocks = item.blocks.map(styled)
                return item
            }
            return .list(list)
        case .quote(let blocks):
            return .quote(blocks.map(styled))
        case .callout(let kind, let blocks):
            return .callout(kind, blocks.map(styled))
        case .table(var table):
            table.header = table.header.map(styled)
            table.rows = table.rows.map { $0.map(styled) }
            return .table(table)
        case .code, .rawText, .rule:
            return block
        }
    }

    private static func styled(_ text: AttributedString) -> AttributedString {
        var styled = text
        for run in text.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                styled[run.range].swiftUI.backgroundColor = MarkdownColors.inlineCodeFill
                styled[run.range].swiftUI.foregroundColor = MarkdownColors.inlineCode
            }
            switch run[MarkdownRoleAttribute.self] {
            case .reference?:
                styled[run.range].swiftUI.backgroundColor = MarkdownColors.chipFill
                styled[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
            case .mention?:
                styled[run.range].swiftUI.foregroundColor = Color.accentColor
                styled[run.range].swiftUI.backgroundColor = MarkdownColors.chipFill
            case nil:
                break
            }
        }
        return styled
    }
}

/// The colors of rendered Markdown, the same in every place it shows, light and dark.
enum MarkdownColors {
    /// the fill of inline code: a neutral grey a touch warmer than the card
    static let inlineCodeFill = Color.secondary.opacity(0.14)
    /// inline code's text, the code keywords' magenta
    static let inlineCode = dynamic(light: 0xA32D6E, dark: 0xFF8CC0)
    /// the fill behind a reference or mention: the accent, faint
    static let chipFill = Color.accentColor.opacity(0.13)

    /// A color that follows the appearance it is drawn in.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(rgb: isDark ? dark : light)
            })
    }
}

extension NSColor {
    /// `0xRRGGBB` in sRGB
    fileprivate convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
