import Foundation

/// The kept requests, one JSON file each, named by the time they were saved (LOG-02, LOG-03).
///
/// Only the newest requests that fit in `maxBytes` stay, `maxFiles` at most: each save drops the oldest beyond that.
/// A log entry whose request was dropped finds nothing.
public actor RequestCapture {
    /// 10 MB
    public static let defaultMaxBytes = 10_485_760
    public static let defaultMaxFiles = 1000

    /// the folder of the requests, such as `~/Library/Logs/menubar-monitor/requests`
    public nonisolated let folder: URL
    public nonisolated let maxBytes: Int
    public nonisolated let maxFiles: Int
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder = {
        let encoder = JSONLines.encoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        return encoder
    }()
    private let decoder = JSONLines.decoder()
    /// the kept files, oldest first, read from the folder at the first save
    private var files: [(name: String, bytes: Int)]?

    public init(folder: URL, maxBytes: Int = defaultMaxBytes, maxFiles: Int = defaultMaxFiles, now: @escaping @Sendable () -> Date = { Date() }) {
        self.folder = folder
        self.maxBytes = maxBytes
        self.maxFiles = maxFiles
        self.now = now
    }

    /// Keeps the record and returns its id, for the log entry; nil when it couldn't be written.
    public func save(_ record: RequestRecord) -> String? {
        guard let data = try? encoder.encode(record) else {
            return nil
        }
        let id = Self.id(for: now())
        // Listed before the new file is written, so that it counts once.
        var files = self.files ?? keptFiles()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url(of: id), options: .atomic)
        } catch {
            return nil
        }
        files.append((id, data.count))
        var total = files.reduce(0) { $0 + $1.bytes }
        while !files.isEmpty, files.count > maxFiles || total > maxBytes {
            let oldest = files.removeFirst()
            total -= oldest.bytes
            try? FileManager.default.removeItem(at: url(of: oldest.name))
        }
        self.files = files
        return id
    }

    /// The kept record, or nil when it was dropped or the id isn't one of ours.
    public func record(id: String) -> RequestRecord? {
        guard Self.isID(id), let data = try? Data(contentsOf: url(of: id)) else {
            return nil
        }
        return try? decoder.decode(RequestRecord.self, from: data)
    }

    /// The bytes the kept requests take together.
    public func totalBytes() -> Int {
        (files ?? keptFiles()).reduce(0) { $0 + $1.bytes }
    }

    /// Deletes every kept request.
    public func clear() {
        try? FileManager.default.removeItem(at: folder)
        files = []
    }

    private func keptFiles() -> [(name: String, bytes: Int)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .map { ($0.deletingPathExtension().lastPathComponent, (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            .sorted { $0.0 < $1.0 }
    }

    private func url(of id: String) -> URL {
        folder.appending(path: "\(id).json")
    }

    /// `20261028-121351-042-1a2b3c4d`: the time in UTC to the millisecond, so the names sort by time, then a random part.
    static func id(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let random = UUID().uuidString.prefix(8).lowercased()
        return String(
            format: "%04d%02d%02d-%02d%02d%02d-%03d-%@",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
            (parts.nanosecond ?? 0) / 1_000_000, random
        )
    }

    /// Ids come from the log file, so one is checked before it becomes a path.
    private static func isID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }
}
