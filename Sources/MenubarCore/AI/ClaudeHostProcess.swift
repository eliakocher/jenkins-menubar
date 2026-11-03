import Foundation

/// A running `claude` that a chat card hosts (AI-10): its stdout as lines, its stdin to write to.
public protocol ClaudeHostConnection: AnyObject, Sendable {
    /// stdout, one line at a time without the line break; it finishes when the process ends
    var lines: AsyncStream<Data> { get }
    /// Writes to stdin; nothing happens once the process has ended.
    func send(_ data: Data)
    /// Closes stdin, which ends `claude` once it is done.
    func closeInput()
    /// Ends the process.
    func terminate()
    /// the last lines of stderr
    func stderrTail() -> String
    /// the exit status, once it ended
    func exitStatus() -> Int32?
}

/// Starts the `claude` of a hosted chat.
public protocol ClaudeHostLauncher: Sendable {
    /// Starts a program with an argument list, never a shell line.
    ///
    /// - Parameters:
    ///   - executable: the program
    ///   - arguments: its arguments
    ///   - folder: its working folder
    ///   - environment: variables added to the app's own
    /// - Returns: the connection
    /// - Throws: when it can't start
    func start(executable: URL, arguments: [String], folder: URL, environment: [String: String]) throws
        -> any ClaudeHostConnection
}

/// Starts `claude` with `Process` and pipes.
public struct ProcessHostLauncher: ClaudeHostLauncher {
    public init() {}

    public func start(executable: URL, arguments: [String], folder: URL, environment: [String: String]) throws
        -> any ClaudeHostConnection
    {
        // A write to a pipe whose reader has gone would end the app with SIGPIPE; the write fails quietly instead.
        signal(SIGPIPE, SIG_IGN)
        let connection = ProcessHostConnection()
        try connection.start(executable: executable, arguments: arguments, folder: folder, environment: environment)
        return connection
    }
}

/// The pipes of one `claude` process.
final class ProcessHostConnection: ClaudeHostConnection, @unchecked Sendable {
    /// how much of stderr is kept
    static let stderrLimit = 4_000

    let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var stderr = Data()
    private var inputClosed = false

    init() {
        (lines, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    func start(executable: URL, arguments: [String], folder: URL, environment: [String: String]) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.flush(final: true)
            } else {
                self.receive(chunk)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.lock.withLock {
                self.stderr.append(chunk)
                if self.stderr.count > Self.stderrLimit {
                    self.stderr = self.stderr.suffix(Self.stderrLimit)
                }
            }
        }
        try process.run()
    }

    private func receive(_ chunk: Data) {
        let complete: [Data] = lock.withLock {
            buffer.append(chunk)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(Data(buffer[buffer.startIndex..<newline]))
                buffer = Data(buffer[buffer.index(after: newline)...])
            }
            return lines
        }
        for line in complete where !line.isEmpty {
            continuation.yield(line)
        }
    }

    private func flush(final: Bool) {
        let rest: Data = lock.withLock {
            defer { buffer = Data() }
            return buffer
        }
        if !rest.isEmpty {
            continuation.yield(rest)
        }
        if final {
            process.waitUntilExit()
            continuation.finish()
        }
    }

    func send(_ data: Data) {
        let open = lock.withLock { !inputClosed }
        guard open, process.isRunning else { return }
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    func closeInput() {
        let wasOpen = lock.withLock {
            defer { inputClosed = true }
            return !inputClosed
        }
        if wasOpen {
            try? input.fileHandleForWriting.close()
        }
    }

    func terminate() {
        closeInput()
        if process.isRunning {
            process.terminate()
        }
    }

    func stderrTail() -> String {
        let data = lock.withLock { stderr }
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).suffix(12)
        return lines.joined(separator: "\n")
    }

    func exitStatus() -> Int32? {
        process.isRunning ? nil : process.terminationStatus
    }
}
