import Foundation

/// How far a save of the whole console log has come (PIPE-12).
public struct ConsoleLogSaveProgress: Sendable, Equatable {
    /// the part of the log's stored size read so far, from 0 to 1
    public var fraction: Double
    /// the text read so far, in bytes
    public var bytes: Int64

    public init(fraction: Double, bytes: Int64) {
        self.fraction = fraction
        self.bytes = bytes
    }
}

/// What a finished save wrote.
public struct ConsoleLogSaveResult: Sendable, Equatable {
    /// the file's size in bytes
    public var bytes: Int64
    /// whether the build had finished writing its log; `false` saved the log as far as it had come
    public var isComplete: Bool

    public init(bytes: Int64, isComplete: Bool) {
        self.bytes = bytes
        self.isComplete = isComplete
    }
}

/// Saves a build's whole console log to a file, read in pages and never held whole in memory (PIPE-12, "Save…").
///
/// Jenkins's `progressiveText` can't be cut at an end offset, and the text it sends has the hidden notes taken out, so
/// no page's end tells where the next one starts. So the log is read as the Console Log card reads it going up: the end
/// first, then each earlier page, lined up with the page after it by the lines they share
/// (``ConsoleLogLoader/alignment(of:from:with:overlap:)``). Each page goes to a file of its own in a temporary folder
/// as it arrives; at the end they are joined, in order, into the destination. Memory holds one page at a time. The text
/// is what the card shows: the notes taken out, the ANSI codes kept, as in Jenkins's `consoleText`.
///
/// A line repeated through the whole overlap (16 KB of identical lines) can't be told from the boundary: the page then
/// ends at its first copy. Real logs don't do this.
///
/// Nothing of the text is logged; the reads go through the source, which records their path only.
public enum ConsoleLogSaver {
    /// Saves the log.
    ///
    /// The destination is written as a hidden file beside it and moved into place when it is whole, so a cancel or a
    /// failure leaves the file that was there untouched and no half-written log.
    ///
    /// - Parameters:
    ///   - source: where the log is read
    ///   - destination: the file to write; replaced when it exists
    ///   - limits: the sizes of the reads; a page is ``ConsoleLogLimits/page``
    ///   - progress: called after each page, off the main actor
    /// - Returns: what was written
    /// - Throws: `CancellationError` when the task is cancelled, the source's error when a read fails, a
    ///   ``ConsoleLogProblem`` when a page can't be lined up with the one after it, or a file error
    public static func save(
        source: ConsoleLogSource, to destination: URL, limits: ConsoleLogLimits = .standard,
        progress: @Sendable (ConsoleLogSaveProgress) -> Void = { _ in }
    ) async throws -> ConsoleLogSaveResult {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appending(path: "megamonitor-log-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).partial")
        defer {
            try? fileManager.removeItem(at: work)
            try? fileManager.removeItem(at: partial)
        }

        var parts: [URL] = []
        var bytes: Int64 = 0
        func store(_ text: Data) throws {
            let url = work.appending(path: "\(parts.count).part")
            try text.write(to: url)
            parts.append(url)
            bytes += Int64(text.count)
        }

        let probe = try await source.read(0, limits.probe)
        let isComplete: Bool
        if !probe.isCut {
            // Short enough to have come whole.
            try store(probe.body)
            isComplete = !probe.hasMore
            progress(ConsoleLogSaveProgress(fraction: 1, bytes: bytes))
        } else {
            let size = max(probe.size, 1)
            try Task.checkCancellation()
            let tailStart = max(0, probe.size - Int64(limits.page))
            let tail = try await source.read(tailStart, nil)
            isComplete = !tail.hasMore
            var skip = tailStart > 0 ? ConsoleLogLoader.firstLineEnd(in: tail.body) : 0
            var text = tail.body.subdata(in: skip..<tail.body.count)
            try store(text)
            var start = tailStart
            progress(ConsoleLogSaveProgress(fraction: Double(size - start) / Double(size), bytes: bytes))
            while start > 0 {
                try Task.checkCancellation()
                // The page before: read from `limits.page` bytes earlier, up to a little past where the page after starts.
                let earlier = max(0, start - Int64(limits.page))
                let head = text.prefix(limits.overlap)
                var limit = Int(start - earlier) + skip + limits.slack
                var cut: (skip: Int, text: Data)?
                for _ in 0..<3 {
                    let chunk = try await source.read(earlier, limit)
                    let first = earlier > 0 ? ConsoleLogLoader.firstLineEnd(in: chunk.body) : 0
                    if let end = ConsoleLogLoader.alignment(of: chunk.body, from: first, with: Data(head), overlap: limits.overlap) {
                        cut = (first, chunk.body.subdata(in: first..<max(first, end)))
                        break
                    }
                    guard chunk.isCut else { break }
                    limit += limits.page
                }
                guard let cut else {
                    throw ConsoleLogProblem("An earlier part of the log couldn't be lined up with the part after it.")
                }
                try store(cut.text)
                start = earlier
                skip = cut.skip
                text = cut.text
                progress(ConsoleLogSaveProgress(fraction: Double(size - start) / Double(size), bytes: bytes))
            }
        }

        try Task.checkCancellation()
        // The pages were stored last first: join them from the last stored to the first.
        fileManager.createFile(atPath: partial.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        for url in parts.reversed() {
            try handle.write(contentsOf: Data(contentsOf: url))
        }
        try handle.close()
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
        } else {
            try fileManager.moveItem(at: partial, to: destination)
        }
        return ConsoleLogSaveResult(bytes: bytes, isComplete: isComplete)
    }
}
