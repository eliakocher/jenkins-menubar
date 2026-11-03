import Foundation
import Observation

/// Where a console log is read from: Jenkins's `progressiveText` in the app, a log in memory in the tests and the gallery.
public struct ConsoleLogSource: Sendable {
    /// Reads the log from a stored byte offset, at most `limit` bytes; nil reads to the end.
    public var read: @Sendable (_ start: Int64, _ limit: Int?) async throws -> ConsoleLogChunk

    public init(read: @escaping @Sendable (_ start: Int64, _ limit: Int?) async throws -> ConsoleLogChunk) {
        self.read = read
    }
}

/// How much of a console log is read at once and kept (PIPE-12).
public struct ConsoleLogLimits: Sendable, Hashable {
    /// the first read, from the start: a log this short shows whole at once, a longer one tells its size
    public var probe: Int
    /// how much a page reads: the tail, and each earlier page
    public var page: Int
    /// the parsed blocks' size, which the view adds one at a time
    public var block: Int
    /// the most text kept; further pages drop the farthest ones, which load again when scrolled back to
    public var maxBytes: Int
    /// the most lines kept, likewise
    public var maxLines: Int
    /// how much of the next page's start an earlier page must end with, to line the two up
    public var overlap: Int
    /// how far past the next page's start an earlier page reads, so that it reaches the overlap
    public var slack: Int

    public init(probe: Int, page: Int, block: Int, maxBytes: Int, maxLines: Int, overlap: Int, slack: Int) {
        self.probe = probe
        self.page = page
        self.block = block
        self.maxBytes = maxBytes
        self.maxLines = maxLines
        self.overlap = overlap
        self.slack = slack
    }

    /// 256 KB first, then pages of 1 MB, at most 16 MB or 200,000 lines kept
    public static let standard = ConsoleLogLimits(
        probe: 256 << 10, page: 1 << 20, block: 256 << 10, maxBytes: 16 << 20, maxLines: 200_000, overlap: 16 << 10,
        slack: 128 << 10)
}

/// A parsed part of the loaded log, which never changes: the view adds and removes whole blocks, at either end.
public struct ConsoleLogBlock: Sendable, Identifiable {
    public let id: Int
    public let slice: ConsoleLogSlice

    public init(id: Int, slice: ConsoleLogSlice) {
        self.id = id
        self.slice = slice
    }
}

/// A build's console log as the build detail's Console Log card shows it (PIPE-12): the tail first, earlier and later
/// pages on demand, the end followed while the build runs, at most ``ConsoleLogLimits/maxBytes`` kept.
///
/// Nothing is read before ``open()``. The log is read in pages, each remembered by the request that read it (its start,
/// the bytes before its first whole line, its length), so a page dropped to save memory reads the same text again.
/// Jenkins's offsets count stored bytes, its text has the hidden notes taken out, so an earlier page can't be cut at an
/// offset: it reads a little past the next page's start and is cut where its text runs into that page's first lines.
///
/// Reading and parsing run off the main actor at a low priority; one request runs at a time.
@Observable @MainActor
public final class ConsoleLogLoader {
    public enum Phase: Equatable, Sendable {
        /// not opened yet
        case idle
        /// the first read is under way
        case loading
        case loaded
        /// the first read failed, with the reason
        case failed(String)
    }

    public private(set) var phase = Phase.idle
    /// the loaded text, in order
    public private(set) var blocks: [ConsoleLogBlock] = []
    /// how many lines come before the first loaded one; nil while the log's start was never read
    public private(set) var linesBefore: Int?
    /// whether there is text before the loaded part
    public private(set) var hasEarlier = false
    /// whether there is text after the loaded part, dropped to save memory
    public private(set) var hasLater = false
    /// whether the log is complete: the build finished writing it
    public private(set) var isFinished = false
    /// the stored log's size at the last answer, in bytes
    public private(set) var size: Int64 = 0
    public private(set) var isLoadingEarlier = false
    public private(set) var isLoadingLater = false
    /// why the last earlier or later page failed; nil once one loads
    public private(set) var pageProblem: String?
    public private(set) var lineCount = 0
    public private(set) var errorCount = 0
    public private(set) var warningCount = 0
    /// the loaded text's size, in bytes
    public private(set) var loadedBytes = 0

    @ObservationIgnored private let source: ConsoleLogSource
    @ObservationIgnored private let limits: ConsoleLogLimits
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var pages: [Page] = []
    /// the loaded pages' indices
    @ObservationIgnored private var loaded: Range<Int> = 0..<0
    /// the last line while the build still writes it: shown once it ends
    @ObservationIgnored private var pending = Data()
    /// where the next read that follows the end starts
    @ObservationIgnored private var end: Int64 = 0
    /// whether the next text at the end starts a page of its own
    @ObservationIgnored private var startsPage = false
    @ObservationIgnored private var isBusy = false
    @ObservationIgnored private var nextBlockID = 0
    @ObservationIgnored private var follower: Int?
    @ObservationIgnored private var nextFollower = 0

    /// One read of the log, remembered so it can be read again.
    private struct Page {
        /// the offset the page was read from
        var start: Int64
        /// the answer's bytes before the page's text: the cut line it started in
        var skip: Int
        /// the text's length, whole lines
        var length: Int
        var lineCount: Int
        /// the text's first ``ConsoleLogLimits/overlap`` bytes, to line an earlier page up with it
        var head: Data
        /// the parsed text; nil while dropped
        var blocks: [ConsoleLogBlock]?
    }

    /// - Parameters:
    ///   - source: where the log is read
    ///   - limits: the sizes of the reads and of what is kept
    ///   - clock: the clock of the polls that follow a running build
    public init(source: ConsoleLogSource, limits: ConsoleLogLimits = .standard, clock: any Clock<Duration> = ContinuousClock()) {
        self.source = source
        self.limits = limits
        self.clock = clock
    }

    // MARK: Reading

    /// Reads the log's end, or the whole log when it is short: once, again after a failure.
    public func open() async {
        switch phase {
        case .loading, .loaded:
            return
        case .idle, .failed:
            break
        }
        phase = .loading
        isBusy = true
        defer { isBusy = false }
        do {
            let probe = try await read(from: 0, limit: limits.probe)
            if probe.isCut {
                let start = max(0, probe.size - Int64(limits.page))
                let tail = try await read(from: start, limit: nil)
                try await installTail(tail, skip: start > 0 ? Self.firstLineEnd(in: tail.body) : 0)
            } else {
                try await installTail(probe, skip: 0)
            }
            phase = .loaded
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(Self.message(of: error))
        }
    }

    /// Loads the page before the loaded part: a dropped one again, or the next one toward the log's start.
    public func loadEarlier() async {
        guard phase == .loaded, hasEarlier, !isBusy else { return }
        isBusy = true
        isLoadingEarlier = true
        defer {
            isBusy = false
            isLoadingEarlier = false
        }
        do {
            if loaded.lowerBound > 0 {
                let index = loaded.lowerBound - 1
                pages[index].blocks = try await reread(pages[index], isLast: false)
                loaded = index..<loaded.upperBound
            } else {
                let page = try await readEarlierPage()
                pages.insert(page, at: 0)
                loaded = 0..<(loaded.upperBound + 1)
            }
            pageProblem = nil
            trim(droppingTop: false)
            publish()
        } catch is CancellationError {
        } catch {
            pageProblem = Self.message(of: error)
        }
    }

    /// Loads the page after the loaded part when one was dropped, or what the running build wrote since the last read.
    public func loadLater() async {
        guard phase == .loaded, !isBusy else { return }
        guard hasLater || !isFinished else { return }
        isBusy = true
        isLoadingLater = hasLater
        defer {
            isBusy = false
            isLoadingLater = false
        }
        do {
            if loaded.upperBound < pages.count {
                let index = loaded.upperBound
                let isLast = index == pages.count - 1
                if isLast {
                    let chunk = try await read(from: pages[index].start, limit: nil)
                    pages[index].blocks = []
                    loaded = loaded.lowerBound..<(index + 1)
                    pending = Data()
                    try await growLastPage(chunk, text: chunk.body.dropFirst(pages[index].skip), replacing: true)
                } else {
                    pages[index].blocks = try await reread(pages[index], isLast: false)
                    loaded = loaded.lowerBound..<(index + 1)
                }
            } else {
                let chunk = try await read(from: end, limit: nil)
                guard chunk.size >= end else {
                    // Jenkins started over at 0: the log was replaced. Read it anew.
                    reset()
                    isBusy = false
                    await open()
                    return
                }
                try await growLastPage(chunk, text: pending + chunk.body, replacing: false)
            }
            pageProblem = nil
            trim(droppingTop: true)
            publish()
        } catch is CancellationError {
        } catch {
            pageProblem = Self.message(of: error)
        }
    }

    /// Follows the end of a running build's log: reads what it wrote every `interval`, until the log is complete or the
    /// calling task is cancelled, as when the card closes or the view goes. Two followers read once.
    ///
    /// - Parameter interval: the time between two reads
    public func follow(every interval: Duration = .seconds(3)) async {
        let me = nextFollower
        nextFollower += 1
        defer {
            if follower == me {
                follower = nil
            }
        }
        while !Task.isCancelled {
            if phase == .loaded, isFinished {
                return
            }
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
            if follower == nil {
                follower = me
            }
            if follower == me, phase == .loaded, !hasLater, !isFinished {
                await loadLater()
            }
        }
    }

    // MARK: Pages

    private func read(from start: Int64, limit: Int?) async throws -> ConsoleLogChunk {
        let source = source
        let task = Task(priority: .utility) { try await source.read(start, limit) }
        var chunk = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        if chunk.body.startIndex != 0 {
            chunk.body = Data(chunk.body)
        }
        size = max(size, chunk.size)
        return chunk
    }

    /// The first page: the text from `skip` to the end, which the build may still be writing.
    private func installTail(_ chunk: ConsoleLogChunk, skip: Int) async throws {
        pages = [Page(start: chunk.start, skip: skip, length: 0, lineCount: 0, head: Data(), blocks: [])]
        loaded = 0..<1
        pending = Data()
        try await growLastPage(chunk, text: chunk.body.dropFirst(skip), replacing: true)
        publish()
    }

    /// Adds the text that runs to the log's end to the last page: its whole lines, and the last line too once the log
    /// is complete.
    private func growLastPage(_ chunk: ConsoleLogChunk, text: Data, replacing: Bool) async throws {
        var whole = Data(text)
        var rest = Data()
        if chunk.hasMore, let lastBreak = whole.lastIndex(of: 0x0A) {
            rest = Data(whole[(lastBreak + 1)...])
            whole = Data(whole[...lastBreak])
        } else if chunk.hasMore {
            rest = whole
            whole = Data()
        }
        end = chunk.size
        isFinished = !chunk.hasMore
        if replacing {
            pages[pages.count - 1].length = 0
            pages[pages.count - 1].lineCount = 0
            pages[pages.count - 1].head = Data()
        }
        if !whole.isEmpty {
            if startsPage {
                // The previous read ended at a line's end, at `chunk.start`: a new page starts there.
                pages.append(Page(start: chunk.start, skip: 0, length: 0, lineCount: 0, head: Data(), blocks: []))
                loaded = loaded.lowerBound..<pages.count
            }
            let index = pages.count - 1
            let previous = pages[index].blocks?.last ?? (index > 0 ? pages[index - 1].blocks?.last : nil)
            let style = previous?.slice.endStyle ?? .plain
            let blocks = try await parse(whole, style: style)
            pages[index].blocks = (pages[index].blocks ?? []) + blocks
            pages[index].length += whole.count
            pages[index].lineCount += blocks.reduce(0) { $0 + $1.slice.lineCount }
            if pages[index].head.count < limits.overlap {
                pages[index].head += whole.prefix(limits.overlap - pages[index].head.count)
            }
        }
        pending = rest
        startsPage = rest.isEmpty && pages[pages.count - 1].length >= limits.page
    }

    /// Reads a page again from what it remembers: the same text, as a log only grows.
    private func reread(_ page: Page, isLast: Bool) async throws -> [ConsoleLogBlock] {
        let wanted = page.skip + page.length
        let chunk = try await read(from: page.start, limit: wanted)
        guard chunk.body.count >= wanted else {
            throw ConsoleLogProblem("The log changed since it was loaded.")
        }
        return try await parse(chunk.body.subdata(in: page.skip..<wanted), style: .plain)
    }

    /// Reads the page before the first one and cuts it where its text runs into the first page's start.
    private func readEarlierPage() async throws -> Page {
        let first = pages[0]
        let start = max(0, first.start - Int64(limits.page))
        let head = windowHead()
        var limit = Int(first.start - start) + first.skip + limits.slack
        for _ in 0..<3 {
            let chunk = try await read(from: start, limit: limit)
            let skip = start > 0 ? Self.firstLineEnd(in: chunk.body) : 0
            let cut: Int?
            if head.isEmpty {
                // Nothing to line up with: the loaded part is empty, and so is the overlap.
                cut = chunk.isCut ? chunk.body.lastIndex(of: 0x0A).map { $0 + 1 } : chunk.body.count
            } else {
                cut = Self.alignment(of: chunk.body, from: skip, with: head, overlap: limits.overlap)
            }
            if let cut {
                let text = chunk.body.subdata(in: skip..<max(skip, cut))
                let blocks = try await parse(text, style: .plain)
                return Page(
                    start: start, skip: skip, length: text.count, lineCount: blocks.reduce(0) { $0 + $1.slice.lineCount },
                    head: text.prefix(limits.overlap), blocks: blocks)
            }
            guard chunk.isCut else { break }
            limit += limits.page
        }
        throw ConsoleLogProblem("The earlier part of the log couldn't be lined up with the loaded part.")
    }

    /// The loaded window's first bytes, over as many pages as it takes.
    private func windowHead() -> Data {
        var head = Data()
        for page in pages {
            head += page.head
            if head.count >= limits.overlap || page.head.count < page.length {
                break
            }
        }
        return head.prefix(limits.overlap)
    }

    private func parse(_ data: Data, style: ConsoleLogStyle) async throws -> [ConsoleLogBlock] {
        let size = limits.block
        let slices = await Task.detached(priority: .utility) {
            ConsoleLogParser.slices(of: data, blockSize: size, style: style)
        }.value
        try Task.checkCancellation()
        return slices.map { slice in
            nextBlockID += 1
            return ConsoleLogBlock(id: nextBlockID, slice: slice)
        }
    }

    /// Drops the farthest pages while more is kept than the limits allow, never the one page left.
    private func trim(droppingTop: Bool) {
        func over() -> Bool {
            let kept = pages[loaded]
            return loaded.count > 1
                && (kept.reduce(0) { $0 + $1.length } > limits.maxBytes || kept.reduce(0) { $0 + $1.lineCount } > limits.maxLines)
        }
        while over() {
            if droppingTop {
                pages[loaded.lowerBound].blocks = nil
                loaded = (loaded.lowerBound + 1)..<loaded.upperBound
            } else {
                let index = loaded.upperBound - 1
                pages[index].blocks = nil
                if index == pages.count - 1 {
                    pending = Data()
                    startsPage = false
                }
                loaded = loaded.lowerBound..<index
            }
        }
    }

    private func reset() {
        pages = []
        loaded = 0..<0
        pending = Data()
        end = 0
        startsPage = false
        phase = .idle
        publish()
    }

    private func publish() {
        let kept = pages[loaded]
        blocks = kept.flatMap { $0.blocks ?? [] }
        lineCount = blocks.reduce(0) { $0 + $1.slice.lineCount }
        var errors = 0
        var warnings = 0
        for block in blocks {
            for kind in block.slice.kinds {
                if kind == .error {
                    errors += 1
                } else if kind == .warning {
                    warnings += 1
                }
            }
        }
        errorCount = errors
        warningCount = warnings
        loadedBytes = kept.reduce(0) { $0 + $1.length }
        let startsAtZero = pages.first.map { $0.start == 0 && $0.skip == 0 } ?? false
        linesBefore = startsAtZero ? pages[..<loaded.lowerBound].reduce(0) { $0 + $1.lineCount } : nil
        hasEarlier = loaded.lowerBound > 0 || !startsAtZero
        hasLater = loaded.upperBound < pages.count
    }

    #if DEBUG
    /// Shows a log's end at once, parsed on the main actor, as ``open()`` would show it: for the gallery, whose
    /// screenshots don't wait for tasks. Debug builds only.
    ///
    /// - Parameter stored: the stored log, notes and all
    /// - Parameter isRunning: whether the build still writes it
    public func preload(stored: Data, isRunning: Bool) {
        let start = max(0, Int64(stored.count) - Int64(limits.page))
        let chunk = ConsoleLogFake.chunk(of: stored, from: start, limit: nil, hasMore: isRunning)
        let skip = start > 0 ? Self.firstLineEnd(in: chunk.body) : 0
        var whole = chunk.body.subdata(in: skip..<chunk.body.count)
        var rest = Data()
        if isRunning, let lastBreak = whole.lastIndex(of: 0x0A) {
            rest = whole.subdata(in: (lastBreak + 1)..<whole.count)
            whole = whole.subdata(in: 0..<(lastBreak + 1))
        }
        let blocks = ConsoleLogParser.slices(of: whole, blockSize: limits.block).map { slice in
            nextBlockID += 1
            return ConsoleLogBlock(id: nextBlockID, slice: slice)
        }
        pages = [Page(
            start: start, skip: skip, length: whole.count, lineCount: blocks.reduce(0) { $0 + $1.slice.lineCount },
            head: whole.prefix(limits.overlap), blocks: blocks)]
        loaded = 0..<1
        pending = rest
        end = chunk.size
        size = chunk.size
        isFinished = !isRunning
        phase = .loaded
        publish()
    }
    #endif

    // MARK: Offsets and lines

    /// Returns where the first whole line starts: after the first line break, or the end when there is none.
    ///
    /// - Parameter data: an answer that starts inside a line
    /// - Returns: the index after the first `\n`
    nonisolated static func firstLineEnd(in data: Data) -> Int {
        data.firstIndex(of: 0x0A).map { $0 - data.startIndex + 1 } ?? data.count
    }

    /// Returns where an earlier answer's text runs into the following text: the first line start from `skip` on where
    /// the answer goes on as `head` begins, over `overlap` bytes or what the two have.
    ///
    /// The first such line start is the longest overlap; a later one would only match where the log repeats itself.
    ///
    /// - Parameters:
    ///   - answer: the earlier answer, read past the following text's start
    ///   - skip: where the answer's first whole line starts
    ///   - head: the following text's first bytes
    ///   - overlap: how many bytes must match, when both have them
    /// - Returns: the index the following text starts at; nil when the answer doesn't reach it
    nonisolated static func alignment(of answer: Data, from skip: Int, with head: Data, overlap: Int) -> Int? {
        let wanted = min(overlap, head.count)
        guard wanted > 0 else { return nil }
        return answer.withUnsafeBytes { (answer: UnsafeRawBufferPointer) -> Int? in
            head.withUnsafeBytes { (head: UnsafeRawBufferPointer) -> Int? in
                guard let base = answer.baseAddress, let headBase = head.baseAddress else { return nil }
                let count = answer.count
                var start = skip
                while start < count {
                    // A line start too close to the answer's end can't show the overlap, and nor can any after it.
                    guard count - start >= wanted else { return nil }
                    if memcmp(base + start, headBase, wanted) == 0 {
                        return start
                    }
                    guard let next = memchr(base + start, 0x0A, count - start) else { return nil }
                    start = base.distance(to: UnsafeRawPointer(next)) + 1
                }
                return nil
            }
        }
    }

    nonisolated static func message(of error: any Error) -> String {
        if let problem = error as? ConsoleLogProblem {
            return problem.message
        }
        return (error as? JenkinsError)?.problem.message ?? error.localizedDescription
    }
}

/// A console log page that couldn't be read for a reason of its own.
struct ConsoleLogProblem: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

extension ConsoleLogParser {
    /// Parses bytes in blocks of about `blockSize`, each ending at a line's end, the style carried from one to the next.
    ///
    /// - Parameters:
    ///   - data: whole lines, the last one maybe without its break
    ///   - blockSize: a block's size; a longer line makes a longer block
    ///   - style: the style before the first byte
    /// - Returns: the blocks' slices, in order
    public static func slices(of data: Data, blockSize: Int, style: ConsoleLogStyle = .plain) -> [ConsoleLogSlice] {
        var slices: [ConsoleLogSlice] = []
        var style = style
        var start = data.startIndex
        while start < data.endIndex {
            var end = min(data.endIndex, start + max(1, blockSize))
            if end < data.endIndex {
                if let lineEnd = data[end...].firstIndex(of: 0x0A) {
                    end = lineEnd + 1
                } else {
                    end = data.endIndex
                }
            }
            let slice = parse(data.subdata(in: start..<end), style: style)
            style = slice.endStyle
            slices.append(slice)
            start = end
        }
        return slices
    }
}
