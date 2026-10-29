import AppKit
import MenubarCore

/// The colors and fonts of the Activity details' text (LOG-02): a code editor's palette, one color per kind of token,
/// each with a light and a dark value, picked by the view's appearance.
@MainActor
enum SyntaxStyle {
    /// the small monospaced font of the old Logs
    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)

    /// The attributes of a kind of span.
    static func attributes(of kind: SyntaxKind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .jsonKey: [.foregroundColor: key]
        case .jsonString: [.foregroundColor: string]
        case .jsonNumber: [.foregroundColor: number]
        case .jsonKeyword: [.foregroundColor: keyword]
        case .jsonPunctuation: [.foregroundColor: punctuation]
        case .resultSuccess: [.foregroundColor: success, .font: boldFont]
        case .resultFailure: [.foregroundColor: failure, .font: boldFont]
        case .resultUnstable: [.foregroundColor: unstable, .font: boldFont]
        case .resultAborted: [.foregroundColor: aborted, .font: boldFont]
        case .headerName: [.foregroundColor: key]
        case .httpMethod: [.foregroundColor: keyword, .font: boldFont]
        case .notKept: [.foregroundColor: NSColor.secondaryLabelColor]
        case .note: [.foregroundColor: NSColor.secondaryLabelColor]
        }
    }

    /// Returns the text as an attributed string: monospaced, in the label color, with the spans colored. One pass over
    /// the spans; the text isn't searched.
    static func attributedString(_ styled: StyledText) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: styled.text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        // Each kind's attributes are built once, not per span.
        var cache: [SyntaxKind: [NSAttributedString.Key: Any]] = [:]
        result.beginEditing()
        for span in styled.spans {
            let attributes = cache[span.kind] ?? attributes(of: span.kind)
            cache[span.kind] = attributes
            result.addAttributes(attributes, range: NSRange(location: span.range.lowerBound, length: span.range.count))
        }
        result.endEditing()
        return result
    }

    // The palette, light then dark. Blue keys, teal strings, violet numbers, pink keywords and a quiet gray for the
    // punctuation; the results are the semantic colors, bold, so they stand out from the strings around them.
    static let key = color(light: "#2457B8", dark: "#8AB4FF")
    static let string = color(light: "#0E7490", dark: "#67D4E8")
    static let number = color(light: "#7C3AED", dark: "#C4A1FF")
    static let keyword = color(light: "#C2185B", dark: "#FF8FB8")
    static let punctuation = color(light: "#8C919B", dark: "#6E7480")
    static let success = color(light: "#16803C", dark: "#5BDB84")
    static let failure = color(light: "#D1242F", dark: "#FF7B72")
    static let unstable = color(light: "#C26A00", dark: "#FFB04D")
    static let aborted = color(light: "#6B7280", dark: "#A0A7B4")

    private static func color(light: String, dark: String) -> NSColor {
        let light = NSColor(hex: light)
        let dark = NSColor(hex: dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
