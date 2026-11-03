import Foundation

/// A color of the console's ANSI SGR codes (PIPE-12).
public enum ConsoleLogColor: Hashable, Sendable {
    /// one of xterm's 256: 0–7 the standard colors, 8–15 their bright ones, 16–231 the cube, 232–255 the greys
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

/// How a stretch of console text looks, from its ANSI SGR codes (PIPE-12).
public struct ConsoleLogStyle: Hashable, Sendable {
    public struct Traits: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let bold = Traits(rawValue: 1 << 0)
        public static let faint = Traits(rawValue: 1 << 1)
        public static let italic = Traits(rawValue: 1 << 2)
        public static let underline = Traits(rawValue: 1 << 3)
        public static let inverse = Traits(rawValue: 1 << 4)
        public static let strikethrough = Traits(rawValue: 1 << 5)
    }

    public var foreground: ConsoleLogColor?
    public var background: ConsoleLogColor?
    public var traits: Traits

    public init(foreground: ConsoleLogColor? = nil, background: ConsoleLogColor? = nil, traits: Traits = []) {
        self.foreground = foreground
        self.background = background
        self.traits = traits
    }

    /// the text's own look, with no code in effect
    public static let plain = ConsoleLogStyle()

    public var isPlain: Bool { self == .plain }
}

/// A stretch of console text in one ANSI style; text outside the runs is plain.
public struct ConsoleLogRun: Hashable, Sendable {
    /// where the run starts in its slice's text, in UTF-16 code units, as `NSString` counts
    public var location: Int
    public var length: Int
    public var style: ConsoleLogStyle

    public init(location: Int, length: Int, style: ConsoleLogStyle) {
        self.location = location
        self.length = length
        self.style = style
    }
}

/// What a console line is about, for its highlight (PIPE-12).
public enum ConsoleLogLineKind: UInt8, Sendable {
    case plain
    /// a `[Pipeline]` step line, shown dimmed
    case pipeline
    /// an error, a failure or an exception
    case error
    /// a warning, or an unstable or aborted build
    case warning
    /// `BUILD SUCCESS`, `Finished: SUCCESS`
    case success
}

/// Console text ready to show: the text without escapes and notes, its ANSI runs, its lines and their kinds.
public struct ConsoleLogSlice: Sendable {
    public var text: String
    /// the text's length in UTF-16 code units
    public var utf16Count: Int
    /// where each line starts in the text, in UTF-16 code units; the first is 0
    public var lineStarts: [Int]
    /// each line's kind, one per line
    public var kinds: [ConsoleLogLineKind]
    /// the styled stretches, in order, never overlapping
    public var runs: [ConsoleLogRun]
    /// the style in effect after the text, which the text after it starts in
    public var endStyle: ConsoleLogStyle

    public init(
        text: String, utf16Count: Int, lineStarts: [Int], kinds: [ConsoleLogLineKind], runs: [ConsoleLogRun],
        endStyle: ConsoleLogStyle
    ) {
        self.text = text
        self.utf16Count = utf16Count
        self.lineStarts = lineStarts
        self.kinds = kinds
        self.runs = runs
        self.endStyle = endStyle
    }

    public var lineCount: Int { kinds.count }
}

/// Turns raw console bytes into a ``ConsoleLogSlice`` (PIPE-12).
///
/// - ANSI SGR codes become runs; every other escape (cursor moves, erasing, OSC titles and links) is taken out.
/// - Jenkins's hidden console notes, `ESC[8mha:…ESC[0m`, are taken out whole: Jenkins strips them from
///   `progressiveText` itself, so this is the guard for a log that still has them.
/// - `\r\n` ends a line; a lone `\r`, a progress bar redrawing itself, starts the line over, as a terminal shows it.
/// - Other control characters but the tab are dropped; bytes that aren't UTF-8 become U+FFFD.
public enum ConsoleLogParser {
    /// Parses console bytes.
    ///
    /// - Parameters:
    ///   - data: the bytes, whole lines best: a cut line is parsed as a line of its own
    ///   - style: the style in effect before the bytes, the previous slice's ``ConsoleLogSlice/endStyle``
    /// - Returns: the slice
    public static func parse(_ data: Data, style: ConsoleLogStyle = .plain) -> ConsoleLogSlice {
        // Decoding repairs what isn't UTF-8, so the byte loop below works on valid UTF-8 only.
        var text = String(decoding: data, as: UTF8.self)
        return text.withUTF8 { bytes in
            var state = State(capacity: bytes.count, style: style)
            state.run(bytes)
            return state.finish()
        }
    }

    /// Returns a line's kind from its text, without escapes.
    ///
    /// `[Pipeline]` lines are dimmed whatever they say. Otherwise the strongest word decides: `ERROR`, `FAILURE`,
    /// `FAILED`, `FATAL`, `SEVERE`, `error:`, `fatal:`, `ERR!`, `Caused by:` and a word ending in `Exception` are errors;
    /// `WARNING`, `WARN`, `UNSTABLE`, `ABORTED` and `warning:` are warnings; `SUCCESS` is a success. Counts like
    /// `Errors: 0` or `0 errors` are not errors.
    ///
    /// - Parameter line: the line's UTF-8 bytes, without its line break
    /// - Returns: the kind
    public static func kind(of line: UnsafeBufferPointer<UInt8>) -> ConsoleLogLineKind {
        let count = line.count
        if count >= 10, contains(pipelineMark, in: line, within: 48) {
            return .pipeline
        }
        var best = ConsoleLogLineKind.plain
        var index = 0
        while index < count {
            let byte = line[index]
            guard isWordByte(byte) else {
                index += 1
                continue
            }
            let start = index
            while index < count, isWordByte(line[index]) {
                index += 1
            }
            let word = UnsafeBufferPointer(rebasing: line[start..<index])
            let next: UInt8 = index < count ? line[index] : 0
            switch kind(ofWord: word, next: next, rest: UnsafeBufferPointer(rebasing: line[index...])) {
            case .error?:
                return .error
            case .warning?:
                best = .warning
            case .success? where best == .plain:
                best = .success
            default:
                break
            }
        }
        return best
    }

    // MARK: Words

    private static let pipelineMark = Array("[Pipeline]".utf8)

    private static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x5F
    }

    private static func kind(ofWord word: UnsafeBufferPointer<UInt8>, next: UInt8, rest: UnsafeBufferPointer<UInt8>)
        -> ConsoleLogLineKind?
    {
        let colon: UInt8 = 0x3A
        // Most words are neither: the first letter rules them out quickly.
        switch word.first {
        case 0x45:  // E
            if equals(word, "ERROR") { return .error }
            if equals(word, "ERR"), next == 0x21 { return .error }
            if equals(word, "Error"), next == colon { return .error }
        case 0x46:  // F
            if equals(word, "FAILURE") || equals(word, "FAILED") || equals(word, "FATAL") { return .error }
        case 0x53:  // S
            if equals(word, "SEVERE") { return .error }
            if equals(word, "SUCCESS") || equals(word, "SUCCESSFUL") { return .success }
        case 0x57:  // W
            if equals(word, "WARNING") || equals(word, "WARN") { return .warning }
            if equals(word, "Warning"), next == colon { return .warning }
        case 0x55:  // U
            if equals(word, "UNSTABLE") { return .warning }
        case 0x41:  // A
            if equals(word, "ABORTED") { return .warning }
        case 0x43:  // C
            if equals(word, "Caused"), starts(rest, with: " by:") { return .error }
        case 0x65:  // e
            if equals(word, "error"), next == colon { return .error }
        case 0x66:  // f
            if equals(word, "fatal"), next == colon { return .error }
        case 0x77:  // w
            if equals(word, "warning"), next == colon { return .warning }
        default:
            break
        }
        if word.count >= 9, ends(word, with: "Exception") {
            return .error
        }
        return nil
    }

    private static func equals(_ word: UnsafeBufferPointer<UInt8>, _ literal: StaticString) -> Bool {
        word.count == literal.utf8CodeUnitCount && memcmp(word.baseAddress, literal.utf8Start, word.count) == 0
    }

    private static func ends(_ word: UnsafeBufferPointer<UInt8>, with literal: StaticString) -> Bool {
        let length = literal.utf8CodeUnitCount
        guard word.count >= length, let base = word.baseAddress else { return false }
        return memcmp(base + (word.count - length), literal.utf8Start, length) == 0
    }

    private static func starts(_ bytes: UnsafeBufferPointer<UInt8>, with literal: StaticString) -> Bool {
        let length = literal.utf8CodeUnitCount
        guard bytes.count >= length, let base = bytes.baseAddress else { return false }
        return memcmp(base, literal.utf8Start, length) == 0
    }

    private static func contains(_ needle: [UInt8], in line: UnsafeBufferPointer<UInt8>, within limit: Int) -> Bool {
        let end = min(line.count, limit + needle.count) - needle.count
        guard end >= 0, let base = line.baseAddress else { return false }
        return needle.withUnsafeBufferPointer { needle in
            var index = 0
            while index <= end {
                if base[index] == needle[0], memcmp(base + index, needle.baseAddress, needle.count) == 0 {
                    return true
                }
                index += 1
            }
            return false
        }
    }

    // MARK: The byte loop

    private struct State {
        var output: [UInt8] = []
        var utf16 = 0
        var lineStartByte = 0
        var lineStartUTF16 = 0
        var style: ConsoleLogStyle
        var runStart = 0
        var runs: [ConsoleLogRun] = []
        var lineStarts: [Int] = []
        var kinds: [ConsoleLogLineKind] = []

        init(capacity: Int, style: ConsoleLogStyle) {
            output.reserveCapacity(capacity)
            self.style = style
            lineStarts.reserveCapacity(capacity / 64)
            kinds.reserveCapacity(capacity / 64)
        }

        mutating func run(_ bytes: UnsafeBufferPointer<UInt8>) {
            let count = bytes.count
            var index = 0
            while index < count {
                let byte = bytes[index]
                switch byte {
                case 0x0A:
                    endLine(newline: true)
                    index += 1
                case 0x0D:
                    let next: UInt8 = index + 1 < count ? bytes[index + 1] : 0x0A
                    if next != 0x0A && next != 0x0D {
                        clearLine()
                    }
                    index += 1
                case 0x1B:
                    index = escape(bytes, at: index)
                case 0x09:
                    emit(byte)
                    index += 1
                case 0x00..<0x20, 0x7F:
                    index += 1
                default:
                    emit(byte)
                    index += 1
                }
            }
        }

        mutating func finish() -> ConsoleLogSlice {
            if output.count > lineStartByte {
                endLine(newline: false)
            }
            closeRun()
            return ConsoleLogSlice(
                text: String(decoding: output, as: UTF8.self), utf16Count: utf16, lineStarts: lineStarts, kinds: kinds,
                runs: runs, endStyle: style)
        }

        @inline(__always)
        mutating func emit(_ byte: UInt8) {
            output.append(byte)
            // A lead byte starts a character: one UTF-16 unit, two from U+10000 on (a 4-byte lead).
            if byte & 0xC0 != 0x80 {
                utf16 += byte >= 0xF0 ? 2 : 1
            }
        }

        mutating func endLine(newline: Bool) {
            let kind = output.withUnsafeBufferPointer { buffer in
                ConsoleLogParser.kind(of: UnsafeBufferPointer(rebasing: buffer[lineStartByte...]))
            }
            kinds.append(kind)
            lineStarts.append(lineStartUTF16)
            if newline {
                // The line break carries no style, so a background doesn't paint past the text.
                closeRun()
                output.append(0x0A)
                utf16 += 1
                runStart = utf16
            }
            lineStartByte = output.count
            lineStartUTF16 = utf16
        }

        /// A lone carriage return: what the line had so far goes, its styles with it.
        mutating func clearLine() {
            closeRun()
            output.removeSubrange(lineStartByte...)
            utf16 = lineStartUTF16
            while let last = runs.last, last.location + last.length > lineStartUTF16 {
                if last.location >= lineStartUTF16 {
                    runs.removeLast()
                } else {
                    runs[runs.count - 1].length = lineStartUTF16 - last.location
                    break
                }
            }
            runStart = utf16
        }

        mutating func closeRun() {
            if !style.isPlain, utf16 > runStart {
                if let last = runs.last, last.style == style, last.location + last.length == runStart {
                    runs[runs.count - 1].length += utf16 - runStart
                } else {
                    runs.append(ConsoleLogRun(location: runStart, length: utf16 - runStart, style: style))
                }
            }
            runStart = utf16
        }

        mutating func setStyle(_ new: ConsoleLogStyle) {
            if new != style {
                closeRun()
                style = new
            }
        }

        /// Reads the escape sequence at `start` and returns the index after it.
        mutating func escape(_ bytes: UnsafeBufferPointer<UInt8>, at start: Int) -> Int {
            let count = bytes.count
            guard start + 1 < count else { return count }
            switch bytes[start + 1] {
            case 0x5B:  // [ : a control sequence
                var index = start + 2
                let parameters = index
                while index < count, (0x20...0x3F).contains(bytes[index]) {
                    index += 1
                }
                guard index < count else { return count }
                let final = bytes[index]
                guard (0x40...0x7E).contains(final) else {
                    // Not a sequence after all: what was read goes, the rest is text.
                    return index
                }
                if final == 0x6D {  // m
                    let parameterBytes = UnsafeBufferPointer(rebasing: bytes[parameters..<index])
                    if parameterBytes.count == 1, parameterBytes[0] == 0x38, startsNote(bytes, at: index + 1) {
                        return skipNote(bytes, from: index + 1)
                    }
                    setStyle(Self.apply(parameterBytes, to: style))
                }
                return index + 1
            case 0x5D, 0x50, 0x58, 0x5E, 0x5F:  // ] P X ^ _ : a string, up to BEL or ESC \
                var index = start + 2
                while index < count {
                    let byte = bytes[index]
                    if byte == 0x07 {
                        return index + 1
                    }
                    if byte == 0x1B, index + 1 < count, bytes[index + 1] == 0x5C {
                        return index + 2
                    }
                    if byte == 0x0A {
                        return index
                    }
                    index += 1
                }
                return count
            case 0x28, 0x29, 0x2A, 0x2B:  // ( ) * + : a character set, one more byte
                return min(count, start + 3)
            default:
                return start + 2
            }
        }

        /// Whether a console note's `ha:` follows its `ESC[8m`.
        func startsNote(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
            index + 2 < bytes.count && bytes[index] == 0x68 && bytes[index + 1] == 0x61 && bytes[index + 2] == 0x3A
        }

        /// Skips a note up to its `ESC[0m`, or to the end of the line when it has none.
        func skipNote(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
            let count = bytes.count
            var index = start
            while index < count {
                let byte = bytes[index]
                if byte == 0x1B, index + 3 < count, bytes[index + 1] == 0x5B, bytes[index + 2] == 0x30, bytes[index + 3] == 0x6D {
                    return index + 4
                }
                if byte == 0x0A {
                    return index
                }
                index += 1
            }
            return count
        }

        /// Applies the parameters of an SGR code (`ESC[…m`), `;` or `:` between them, an empty one meaning 0.
        static func apply(_ parameters: UnsafeBufferPointer<UInt8>, to style: ConsoleLogStyle) -> ConsoleLogStyle {
            var values: [Int] = []
            var current: Int?
            for byte in parameters {
                switch byte {
                case 0x30...0x39:
                    current = min((current ?? 0) * 10 + Int(byte - 0x30), 100_000)
                case 0x3B, 0x3A:
                    values.append(current ?? 0)
                    current = nil
                default:
                    // A private marker such as `?` or `>`: not a style.
                    return style
                }
            }
            values.append(current ?? 0)
            var style = style
            var index = 0
            func color(at index: inout Int) -> ConsoleLogColor? {
                guard index + 1 < values.count else { return nil }
                switch values[index + 1] {
                case 5 where index + 2 < values.count:
                    index += 2
                    return .indexed(UInt8(clamping: values[index]))
                case 2 where index + 4 < values.count:
                    index += 4
                    return .rgb(UInt8(clamping: values[index - 2]), UInt8(clamping: values[index - 1]), UInt8(clamping: values[index]))
                default:
                    index = values.count
                    return nil
                }
            }
            while index < values.count {
                let value = values[index]
                switch value {
                case 0: style = .plain
                case 1: style.traits.insert(.bold)
                case 2: style.traits.insert(.faint)
                case 3: style.traits.insert(.italic)
                case 4: style.traits.insert(.underline)
                case 7: style.traits.insert(.inverse)
                case 9: style.traits.insert(.strikethrough)
                case 22: style.traits.subtract([.bold, .faint])
                case 23: style.traits.remove(.italic)
                case 24: style.traits.remove(.underline)
                case 27: style.traits.remove(.inverse)
                case 29: style.traits.remove(.strikethrough)
                case 30...37: style.foreground = .indexed(UInt8(value - 30))
                case 38: style.foreground = color(at: &index) ?? style.foreground
                case 39: style.foreground = nil
                case 40...47: style.background = .indexed(UInt8(value - 40))
                case 48: style.background = color(at: &index) ?? style.background
                case 49: style.background = nil
                case 90...97: style.foreground = .indexed(UInt8(value - 90 + 8))
                case 100...107: style.background = .indexed(UInt8(value - 100 + 8))
                default: break
                }
                index += 1
            }
            return style
        }
    }
}
