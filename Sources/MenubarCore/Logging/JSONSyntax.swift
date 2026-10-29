import Foundation

/// What a span of a shown text is, for the colors of the Activity details (LOG-02). Core only names the kinds; the
/// views pick the colors.
public enum SyntaxKind: Sendable, Hashable {
    case jsonKey
    case jsonString
    case jsonNumber
    /// `true`, `false` or `null`
    case jsonKeyword
    /// `{ } [ ] : ,`
    case jsonPunctuation
    /// the string value `"SUCCESS"`, `"FAILURE"`, `"UNSTABLE"` or `"ABORTED"`, with its quotes
    case resultSuccess
    case resultFailure
    case resultUnstable
    case resultAborted
    /// the name of a header, like `Authorization` or `X-Jenkins`
    case headerName
    /// the method of the request line, like `GET`
    case httpMethod
    /// the "(not kept)" after the scheme of `Authorization`
    case notKept
    /// a remark of the app's, not of the server's
    case note
}

/// A part of a text with its kind. The range is in UTF-16 units, so it is an `NSRange` once it gets to AppKit.
public struct SyntaxSpan: Sendable, Hashable {
    public var kind: SyntaxKind
    public var range: Range<Int>

    public init(kind: SyntaxKind, range: Range<Int>) {
        self.kind = kind
        self.range = range
    }
}

/// A text with the kinds of some of its parts; the rest is plain.
public struct StyledText: Sendable, Hashable {
    public var text: String
    /// ascending and without overlap
    public var spans: [SyntaxSpan]

    public init(text: String, spans: [SyntaxSpan] = []) {
        self.text = text
        self.spans = spans
    }
}

/// A `StyledText` put together piece by piece, which keeps the UTF-16 offsets of the spans.
struct StyledTextBuilder {
    private(set) var text = ""
    private(set) var spans: [SyntaxSpan] = []
    private var length = 0

    var result: StyledText {
        StyledText(text: text, spans: spans)
    }

    mutating func append(_ piece: String, kind: SyntaxKind? = nil) {
        let count = piece.utf16.count
        if let kind, count > 0 {
            spans.append(SyntaxSpan(kind: kind, range: length..<length + count))
        }
        text += piece
        length += count
    }

    mutating func append(_ piece: StyledText) {
        spans.append(contentsOf: piece.spans.map { SyntaxSpan(kind: $0.kind, range: $0.range.lowerBound + length..<$0.range.upperBound + length) })
        text += piece.text
        length += piece.text.utf16.count
    }
}

/// One token of JSON text, found by `JSONScanner`.
struct JSONToken {
    enum Kind {
        case key
        case string
        case number
        case keyword
        /// one of `{ } [ ] : ,`
        case punctuation
    }

    var kind: Kind
    /// the token's bytes in the text
    var bytes: Range<Int>
    /// how many UTF-16 units the bytes are
    var utf16Length: Int
}

/// A scanner that reads JSON token by token, without ever needing the whole document: a body that was cut in a string,
/// a number or an object scans up to the cut. It follows JSON's grammar, so it knows a key from a string value, and
/// refuses the text that can't be JSON: a character JSON can't have there, a closing bracket of the wrong kind, a
/// second value after the first.
struct JSONScanner {
    /// the text is not JSON
    struct Invalid: Error {}

    private enum Container {
        case object
        case array
    }

    /// what the grammar allows next
    private enum Expect {
        case value
        case valueOrEnd
        case keyOrEnd
        case key
        case colon
        case commaOrEnd
        case done
    }

    private let bytes: [UInt8]
    private var position = 0
    private var stack: [Container] = []
    private var expect = Expect.value

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Returns the next token.
    ///
    /// - Returns: the token, or nil at the end of the text
    /// - Throws: `Invalid` when the text can't be JSON, not when it stops early
    mutating func next() throws -> JSONToken? {
        while position < bytes.count, Self.isWhitespace(bytes[position]) {
            position += 1
        }
        guard position < bytes.count else {
            return nil
        }
        let start = position
        let byte = bytes[start]
        switch byte {
        case UInt8(ascii: "{"):
            try require(expect == .value || expect == .valueOrEnd)
            stack.append(.object)
            expect = .keyOrEnd
            return punctuation(start)
        case UInt8(ascii: "["):
            try require(expect == .value || expect == .valueOrEnd)
            stack.append(.array)
            expect = .valueOrEnd
            return punctuation(start)
        case UInt8(ascii: "}"):
            try require((expect == .keyOrEnd || expect == .commaOrEnd) && stack.last == .object)
            stack.removeLast()
            endValue()
            return punctuation(start)
        case UInt8(ascii: "]"):
            try require((expect == .valueOrEnd || expect == .commaOrEnd) && stack.last == .array)
            stack.removeLast()
            endValue()
            return punctuation(start)
        case UInt8(ascii: ","):
            try require(expect == .commaOrEnd)
            expect = stack.last == .object ? .key : .value
            return punctuation(start)
        case UInt8(ascii: ":"):
            try require(expect == .colon)
            expect = .value
            return punctuation(start)
        case UInt8(ascii: "\""):
            let isKey = expect == .keyOrEnd || expect == .key
            try require(isKey || expect == .value || expect == .valueOrEnd)
            let length = scanString()
            if isKey {
                expect = .colon
            } else {
                endValue()
            }
            return JSONToken(kind: isKey ? .key : .string, bytes: start..<position, utf16Length: length)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            try require(expect == .value || expect == .valueOrEnd)
            while position < bytes.count, Self.isNumberByte(bytes[position]) {
                position += 1
            }
            endValue()
            return JSONToken(kind: .number, bytes: start..<position, utf16Length: position - start)
        case UInt8(ascii: "a")...UInt8(ascii: "z"):
            try require(expect == .value || expect == .valueOrEnd)
            while position < bytes.count, bytes[position] >= UInt8(ascii: "a"), bytes[position] <= UInt8(ascii: "z") {
                position += 1
            }
            let word = bytes[start..<position]
            // A cut body may end inside `true`.
            let cut = position == bytes.count
            try require(["true", "false", "null"].contains { $0.utf8.elementsEqual(word) || (cut && $0.utf8.starts(with: word)) })
            endValue()
            return JSONToken(kind: .keyword, bytes: start..<position, utf16Length: position - start)
        default:
            throw Invalid()
        }
    }

    private func require(_ condition: Bool) throws {
        if !condition {
            throw Invalid()
        }
    }

    private mutating func endValue() {
        expect = stack.isEmpty ? .done : .commaOrEnd
    }

    private mutating func punctuation(_ start: Int) -> JSONToken {
        position = start + 1
        return JSONToken(kind: .punctuation, bytes: start..<position, utf16Length: 1)
    }

    /// Reads a string from its opening quote to the closing one, or to the end of the text; returns its length in UTF-16
    /// units.
    private mutating func scanString() -> Int {
        var length = 1
        position += 1
        var escaped = false
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            // A continuation byte (10xxxxxx) adds nothing; a 4-byte sequence is a surrogate pair.
            if byte & 0xC0 != 0x80 {
                length += byte >= 0xF0 ? 2 : 1
            }
            if escaped {
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                break
            }
        }
        return length
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\t")
    }

    private static func isNumberByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+")
            || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")
    }
}

/// Indents JSON by two spaces from its tokens, and tells the kind of each token for the colors.
enum JSONIndenter {
    private static let results: [(text: [UInt8], kind: SyntaxKind)] = [
        (Array(#""SUCCESS""#.utf8), .resultSuccess), (Array(#""FAILURE""#.utf8), .resultFailure),
        (Array(#""UNSTABLE""#.utf8), .resultUnstable), (Array(#""ABORTED""#.utf8), .resultAborted),
    ]

    /// Returns the text indented by two spaces, keeping the keys in their order, with the kinds of its tokens.
    ///
    /// The text may stop anywhere, as a body cut at 128 KB does: the output stops there too, without closing anything.
    /// An empty object or array stays `{}` or `[]`.
    ///
    /// - Parameter text: the JSON text
    /// - Returns: the indented text and its spans, or nil when the text isn't JSON
    static func indent(_ text: String) -> StyledText? {
        let bytes = Array(text.utf8)
        var scanner = JSONScanner(bytes: bytes)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + bytes.count / 4)
        var spans: [SyntaxSpan] = []
        // the UTF-16 length of the output so far
        var length = 0
        var depth = 0
        // after `{` or `[`: the next token stays on the line when it closes the container, and starts a new one otherwise
        var justOpened = false
        // after `,`
        var needsBreak = false

        func append(_ byte: UInt8) {
            output.append(byte)
            length += 1
        }
        func newLine(_ depth: Int) {
            append(UInt8(ascii: "\n"))
            for _ in 0..<depth * 2 {
                append(UInt8(ascii: " "))
            }
        }

        do {
            while let token = try scanner.next() {
                let byte = bytes[token.bytes.lowerBound]
                let isClose = token.kind == .punctuation && (byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]"))
                if isClose {
                    depth -= 1
                    if !justOpened {
                        newLine(depth)
                    }
                } else if justOpened || needsBreak {
                    newLine(depth)
                }
                justOpened = false
                needsBreak = false

                let kind: SyntaxKind
                switch token.kind {
                case .key: kind = .jsonKey
                case .number: kind = .jsonNumber
                case .keyword: kind = .jsonKeyword
                case .punctuation: kind = .jsonPunctuation
                case .string:
                    let value = bytes[token.bytes]
                    kind = results.first { $0.text.elementsEqual(value) }?.kind ?? .jsonString
                }
                spans.append(SyntaxSpan(kind: kind, range: length..<length + token.utf16Length))
                output.append(contentsOf: bytes[token.bytes])
                length += token.utf16Length

                if token.kind == .punctuation {
                    switch byte {
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        depth += 1
                        justOpened = true
                    case UInt8(ascii: ","):
                        needsBreak = true
                    case UInt8(ascii: ":"):
                        append(UInt8(ascii: " "))
                    default:
                        break
                    }
                }
            }
        } catch {
            return nil
        }
        guard !output.isEmpty else {
            return nil
        }
        return StyledText(text: String(decoding: output, as: UTF8.self), spans: spans)
    }
}
