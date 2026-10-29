import Foundation

/// One entry of the Activity log, one JSON line in the file (LOG-01).
///
/// Tabs and line breaks in the texts become spaces, and the detail keeps at most 500 characters. No entry ever holds a
/// token: the callers never pass one, and the tests search the log for theirs.
public struct ActivityEntry: Codable, Sendable, Hashable {
    public enum Level: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
        case debug
        case info
        case warning
        case error

        public static func < (lhs: Level, rhs: Level) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    public enum Source: String, Codable, Sendable, Hashable, CaseIterable {
        case jenkins
        case gitlab
        case alerts
        case settings
        case app
    }

    /// How something ended, with a short label: `ok:200`, `failed:TIMEOUT`, `running:RUNNING`. Kept in the file as that
    /// text.
    public struct Outcome: Codable, Sendable, Hashable, CustomStringConvertible {
        public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
            case ok
            case failed
            case warning
            case running
            case neutral
        }

        public var kind: Kind
        public var label: String

        public init(_ kind: Kind, _ label: String) {
            self.kind = kind
            self.label = ActivityEntry.oneLine(label)
        }

        public static func ok(_ label: String) -> Outcome { Outcome(.ok, label) }
        public static func failed(_ label: String) -> Outcome { Outcome(.failed, label) }
        public static func warning(_ label: String) -> Outcome { Outcome(.warning, label) }
        public static func running(_ label: String) -> Outcome { Outcome(.running, label) }
        public static func neutral(_ label: String) -> Outcome { Outcome(.neutral, label) }

        public var description: String {
            "\(kind.rawValue):\(label)"
        }

        public init(from decoder: any Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            self.init(Kind(rawValue: String(parts[0])) ?? .neutral, parts.count > 1 ? String(parts[1]) : "")
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(description)
        }
    }

    /// the most characters a detail keeps
    public static let maxDetailLength = 500

    public var time: Date
    public var level: Level
    public var source: Source
    public var message: String
    public var detail: String?
    public var outcome: Outcome?
    /// the id of the request this entry is about, in `RequestCapture`
    public var requestID: String?
    /// the project the entry is about, by its name; only while there are several projects (plan Phase 13)
    public var project: String?

    public init(
        time: Date, level: Level, source: Source, message: String, detail: String? = nil, outcome: Outcome? = nil,
        requestID: String? = nil, project: String? = nil
    ) {
        self.project = project
        self.time = time
        self.level = level
        self.source = source
        self.message = Self.oneLine(message)
        self.detail = detail.map { String(Self.oneLine($0).prefix(Self.maxDetailLength)) }
        self.outcome = outcome
        self.requestID = requestID
    }

    enum CodingKeys: String, CodingKey {
        case time, level, source, message, detail, outcome
        case requestID = "request"
        case project
    }

    static func oneLine(_ text: String) -> String {
        String(text.map { $0 == "\t" || $0.isNewline ? " " : $0 })
    }
}

/// The JSON of the log files: one value per line, times in ISO 8601 with the local offset and milliseconds.
enum JSONLines {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(timeStyle(in: .current)))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = try? timeStyle(in: .gmt).parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an ISO 8601 time: \(text)")
            }
            return date
        }
        return decoder
    }

    /// The line for the value, with its line break.
    static func line(_ value: some Encodable, encoder: JSONEncoder) -> Data? {
        guard var data = try? encoder.encode(value) else {
            return nil
        }
        data.append(0x0A)
        return data
    }

    /// The values of the lines that decode; a line cut short by a crash is skipped.
    static func values<T: Decodable>(_ type: T.Type, in data: Data, decoder: JSONDecoder) -> [T] {
        data.split(separator: 0x0A).compactMap { try? decoder.decode(type, from: Data($0)) }
    }

    private static func timeStyle(in timeZone: TimeZone) -> Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: timeZone)
    }
}

/// File operations of the logs, which never throw: a log that can't be written must not stop a check.
enum LogFiles {
    /// The file's size in bytes, 0 when it isn't there.
    static func size(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// The line break to write before the first line after launch: a line that a crash cut short has none, and the
    /// next line would join it and be lost with it.
    static func lineBreakToMend(_ url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Data()
        }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else {
            return Data()
        }
        try? handle.seek(toOffset: end - 1)
        return (try? handle.read(upToCount: 1)) == Data([0x0A]) ? Data() : Data([0x0A])
    }

    /// Appends to the file, creating it and its folder when needed. Returns whether it worked.
    @discardableResult
    static func append(_ data: Data, to url: URL) -> Bool {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return manager.createFile(atPath: url.path, contents: data)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return false
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }
}
