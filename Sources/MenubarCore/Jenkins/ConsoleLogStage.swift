import Foundation

/// Where a line is among the loaded blocks: the block's id and the line's number in it, from 0. Unlike a line's number in
/// the whole text, it stays right when pages are added or dropped, until its block goes.
public struct ConsoleLogLocation: Sendable, Hashable {
    public var blockID: Int
    public var line: Int

    public init(blockID: Int, line: Int) {
        self.blockID = blockID
        self.line = line
    }
}

/// Finds where a pipeline stage starts in the console log, for a click on the stage in the Stages card (PIPE-12).
///
/// A stage is not a log of its own. Jenkins's `wfapi` has a log per flow node (`…/execution/node/<id>/wfapi/log`), but a
/// stage's node has none, only its steps do (the Pipeline Stage View plugin's REST API page: a stage's `_links` hold
/// `self` only; its `stageFlowNodes` are the steps), so a stage's log would be one request for the stage and one more for
/// each of its steps, in HTML. The console log itself marks each stage with the line `[Pipeline] { (<name>)` (inferred
/// from Pipeline's output; a parallel branch's lines carry a `[branch] ` prefix before it), so the click jumps to that line.
public enum ConsoleLogStage {
    /// Returns the line a stage's block opens with.
    ///
    /// - Parameter name: the stage's name as `wfapi/describe` gives it
    /// - Returns: `[Pipeline] { (name)`
    public static func marker(for name: String) -> String {
        "[Pipeline] { (\(name))"
    }

    /// Returns the first line of a slice that opens the stage: the marker alone on the line, or after a `[…] ` prefix.
    ///
    /// - Parameters:
    ///   - name: the stage's name
    ///   - slice: parsed log text
    /// - Returns: the line's number in the slice, from 0; `nil` when the slice doesn't have it
    public static func firstLine(of name: String, in slice: ConsoleLogSlice) -> Int? {
        let marker = marker(for: name)
        let text = slice.text as NSString
        var from = 0
        while from < text.length {
            let found = text.range(of: marker, options: .literal, range: NSRange(location: from, length: text.length - from))
            guard found.location != NSNotFound else { return nil }
            let line = lineIndex(of: found.location, in: slice.lineStarts)
            let lineStart = slice.lineStarts[line]
            let end = found.location + found.length
            let endsLine = end == text.length || text.character(at: end) == 0x0A || text.character(at: end) == 0x0D
            let prefix = text.substring(with: NSRange(location: lineStart, length: found.location - lineStart))
            if endsLine && (prefix.isEmpty || prefix.hasSuffix("] ")) {
                return line
            }
            from = found.location + 1
        }
        return nil
    }

    private static func lineIndex(of location: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= location {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return max(low, 0)
    }
}

extension ConsoleLogLoader {
    /// Returns where a stage starts in the loaded part of the log.
    ///
    /// - Parameter name: the stage's name
    /// - Returns: the first line that opens it; `nil` when the loaded part doesn't have it
    public func locateLoaded(stage name: String) -> ConsoleLogLocation? {
        for block in blocks {
            if let line = ConsoleLogStage.firstLine(of: name, in: block.slice) {
                return ConsoleLogLocation(blockID: block.id, line: line)
            }
        }
        return nil
    }

    /// Opens the log when it isn't, and returns where a stage starts, reading earlier pages until the line is found or
    /// the log's start is reached.
    ///
    /// The first line that opens the stage counts: a stage name used twice in a build shows its first run. When the
    /// stage isn't found, ``pageProblem`` says so.
    ///
    /// - Parameter name: the stage's name as `wfapi/describe` gives it
    /// - Returns: the line, in a block that is loaded now; `nil` when the log has no such line or can't be read
    public func locate(stage name: String) async -> ConsoleLogLocation? {
        await open()
        // Someone else is opening it: wait for them, up to a minute.
        var waits = 0
        while phase == .loading, waits < 1200 {
            try? await Task.sleep(for: .milliseconds(50))
            waits += 1
        }
        guard phase == .loaded else { return nil }
        // Every page is read at most once on the way up, which the log's size bounds; a guard keeps a log that
        // grows under the reader from looping.
        var steps = Int(size / Int64(max(1, pageSize))) + 4
        while true {
            if let location = locateLoaded(stage: name) {
                return location
            }
            guard hasEarlier, steps > 0, pageProblem == nil else { break }
            steps -= 1
            await loadEarlier()
        }
        if pageProblem == nil {
            report("The start of the stage \"\(name)\" isn't in the log: it may not have started, or the log names it differently.")
        }
        return nil
    }
}
