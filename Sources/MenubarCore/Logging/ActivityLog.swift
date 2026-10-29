import Foundation

/// The Activity log: JSON Lines in `~/Library/Logs/menubar-monitor`, where Console.app finds them too (LOG-01, LOG-03).
///
/// Once the file is above `maxBytes`, the next entry starts a new one: the full file becomes `.1`, the older ones move
/// up a number, and the oldest beyond `keptFiles` goes. Writing never fails for the caller: a log that can't be written
/// must not stop a check.
public actor ActivityLog {
    /// 1 MB
    public static let defaultMaxBytes = 1_048_576
    public static let defaultKeptFiles = 5

    public nonisolated let fileURL: URL
    public nonisolated let maxBytes: Int
    /// the files kept, the current one included
    public nonisolated let keptFiles: Int
    private let now: @Sendable () -> Date
    private let encoder = JSONLines.encoder()
    private let decoder = JSONLines.decoder()
    /// the size of the current file, read from the disk at the first write
    private var size: Int?

    public init(
        folder: URL,
        fileName: String = "\(AppIdentity.name).log",
        maxBytes: Int = defaultMaxBytes,
        keptFiles: Int = defaultKeptFiles,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = folder.appending(path: fileName)
        self.maxBytes = maxBytes
        self.keptFiles = max(keptFiles, 1)
        self.now = now
    }

    /// The current file and the older ones, newest first: `menubar-monitor.log`, `.1`, … `.4`.
    public nonisolated var fileURLs: [URL] {
        [fileURL] + (1..<keptFiles).map { fileURL.appendingPathExtension(String($0)) }
    }

    /// Adds an entry with the current time.
    /// the project the entries logged in this task are about, by its name; the Pipelines stores set it while there
    /// are several projects (plan Phase 13)
    @TaskLocal public static var project: String?

    public func log(
        _ level: ActivityEntry.Level,
        _ source: ActivityEntry.Source,
        _ message: String,
        detail: String? = nil,
        outcome: ActivityEntry.Outcome? = nil,
        requestID: String? = nil
    ) {
        append(ActivityEntry(
            time: now(), level: level, source: source, message: message, detail: detail, outcome: outcome,
            requestID: requestID, project: Self.project))
    }

    public func append(_ entry: ActivityEntry) {
        guard var line = JSONLines.line(entry, encoder: encoder) else {
            return
        }
        var size: Int
        if let known = self.size {
            size = known
        } else {
            size = LogFiles.size(of: fileURL)
            line = LogFiles.lineBreakToMend(fileURL) + line
        }
        if size > maxBytes {
            rotate()
            size = 0
        }
        if LogFiles.append(line, to: fileURL) {
            size += line.count
        }
        self.size = size
    }

    /// Every entry of every file, oldest first.
    public func entries() -> [ActivityEntry] {
        fileURLs.reversed().flatMap { url in
            (try? Data(contentsOf: url)).map { JSONLines.values(ActivityEntry.self, in: $0, decoder: decoder) } ?? []
        }
    }

    /// The newest entries, newest first.
    public func recentEntries(limit: Int) -> [ActivityEntry] {
        Array(entries().suffix(limit).reversed())
    }

    /// The bytes all files take together.
    public func totalBytes() -> Int {
        fileURLs.reduce(0) { $0 + LogFiles.size(of: $1) }
    }

    /// Deletes every file. The caller logs what comes next, such as "Cleared the logs" (LOG-04).
    public func clear() {
        for url in fileURLs {
            try? FileManager.default.removeItem(at: url)
        }
        size = 0
    }

    private func rotate() {
        let files = fileURLs
        let manager = FileManager.default
        try? manager.removeItem(at: files[files.count - 1])
        for index in stride(from: files.count - 2, through: 0, by: -1) where manager.fileExists(atPath: files[index].path) {
            try? manager.moveItem(at: files[index], to: files[index + 1])
        }
    }
}
