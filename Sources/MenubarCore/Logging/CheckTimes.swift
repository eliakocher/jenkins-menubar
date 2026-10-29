import Foundation

/// One Jenkins check or GitLab load that made requests (LOG-05).
public struct CheckTime: Codable, Sendable, Hashable {
    public var time: Date
    public var source: ActivityEntry.Source
    /// the seconds of the check's requests together
    public var seconds: Double
    public var requests: Int
    public var failed: Int

    public init(time: Date, source: ActivityEntry.Source, seconds: Double, requests: Int, failed: Int) {
        self.time = time
        self.source = source
        self.seconds = seconds
        self.requests = requests
        self.failed = failed
    }
}

/// The check times, JSON Lines, for the Activity chart (LOG-04, LOG-05).
///
/// Once the file is above `maxBytes`, the next record first drops the older half of it (LOG-03).
public actor CheckTimes {
    /// 512 KB
    public static let defaultMaxBytes = 524_288

    public nonisolated let fileURL: URL
    public nonisolated let maxBytes: Int
    private let log: ActivityLog?
    private let now: @Sendable () -> Date
    private let encoder = JSONLines.encoder()
    private let decoder = JSONLines.decoder()
    private var size: Int?

    /// - Parameter log: where each recorded check also gets its summary line
    public init(
        folder: URL,
        fileName: String = "checks.jsonl",
        maxBytes: Int = defaultMaxBytes,
        log: ActivityLog? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = folder.appending(path: fileName)
        self.maxBytes = maxBytes
        self.log = log
        self.now = now
    }

    /// Runs one Jenkins check or GitLab load. When its requests went through a `RequestRecorder`, they are recorded
    /// together as one check time, and logged as "Checked Jenkins: 3 requests, 0.04s together". A check without
    /// requests records nothing.
    ///
    /// The requests are counted in a task-local tally, so a GitLab load that runs during a Jenkins check doesn't mix
    /// with it. Requests sent from child tasks count; requests sent from detached tasks don't.
    public nonisolated(nonsending) func measure<T>(
        _ source: ActivityEntry.Source,
        _ operation: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        let tally = CheckTally()
        do {
            let result = try await CheckTally.current.withValue(tally, operation: operation)
            await finish(tally, source: source)
            return result
        } catch {
            await finish(tally, source: source)
            throw error
        }
    }

    public func append(_ check: CheckTime) {
        guard var line = JSONLines.line(check, encoder: encoder) else {
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
            size = keepNewestHalf()
        }
        if LogFiles.append(line, to: fileURL) {
            size += line.count
        }
        self.size = size
    }

    /// Every check time, oldest first.
    public func all() -> [CheckTime] {
        (try? Data(contentsOf: fileURL)).map { JSONLines.values(CheckTime.self, in: $0, decoder: decoder) } ?? []
    }

    public func totalBytes() -> Int {
        LogFiles.size(of: fileURL)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        size = 0
    }

    private func finish(_ tally: CheckTally, source: ActivityEntry.Source) async {
        let (requests, seconds, failed) = await tally.totals
        guard requests > 0 else {
            return
        }
        append(CheckTime(time: now(), source: source, seconds: seconds, requests: requests, failed: failed))
        let summary = "Checked \(source.displayName): \(requests) request\(requests == 1 ? "" : "s"), \(String(format: "%.2f", seconds))s together"
        await log?.log(.debug, source, summary, outcome: failed == 0 ? .ok("OK") : .failed("\(failed) FAILED"))
    }

    /// Keeps the newer half of the lines, and returns the new size.
    private func keepNewestHalf() -> Int {
        guard let data = try? Data(contentsOf: fileURL) else {
            return 0
        }
        let lines = data.split(separator: 0x0A)
        var kept = Data()
        for line in lines.suffix(lines.count / 2) {
            kept.append(line)
            kept.append(0x0A)
        }
        guard (try? kept.write(to: fileURL, options: .atomic)) != nil else {
            return data.count
        }
        return kept.count
    }
}

/// The requests of the check that runs in the current task. `RequestRecorder` adds to it.
actor CheckTally {
    static let current = TaskLocal<CheckTally?>(wrappedValue: nil)

    private var requests = 0
    private var seconds = 0.0
    private var failed = 0

    var totals: (requests: Int, seconds: Double, failed: Int) {
        (requests, seconds, failed)
    }

    func add(seconds: Double, failed: Bool) {
        requests += 1
        self.seconds += seconds
        if failed {
            self.failed += 1
        }
    }
}

extension ActivityEntry.Source {
    /// "Jenkins", "GitLab", "Alerts", "Settings", "App"
    public var displayName: String {
        switch self {
        case .jenkins: "Jenkins"
        case .gitlab: "GitLab"
        case .alerts: "Alerts"
        case .settings: "Settings"
        case .app: "App"
        }
    }
}
