import Foundation

/// What a finished process left behind.
public struct ProcessOutput: Sendable, Hashable {
    public var status: Int32
    public var standardOutput: Data
    public var standardError: Data

    public init(status: Int32, standardOutput: Data = Data(), standardError: Data = Data()) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// Runs a command line tool. `SecurityCLIKeychain` runs `security` through it, so a test can see every command line
/// and check that no secret is on one.
public protocol ProcessRunner: Sendable {
    /// Runs the tool to its end, with `input` on its stdin, and returns its exit status and output.
    func run(_ executable: URL, arguments: [String], input: Data?) async throws -> ProcessOutput

    /// Runs the tool to its end like ``run(_:arguments:input:)``, and hands each line of its stdout to `onOutputLine`
    /// as it comes, without the line break, so a long run like `build.sh` can show its progress. The returned output
    /// still holds all of stdout.
    func run(
        _ executable: URL, arguments: [String], input: Data?, onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessOutput

    /// Runs the tool to its end like ``run(_:arguments:input:)``, but ends it once it has run longer than `timeout`
    /// and throws ``ProcessTimedOut`` then, so a tool that hangs, like `git` on a stuck disk, never holds the caller up.
    func run(_ executable: URL, arguments: [String], input: Data?, timeout: Duration) async throws -> ProcessOutput
}

/// A tool that ran longer than its time limit, and was ended.
public struct ProcessTimedOut: Error, Hashable, Sendable {
    /// the tool's name, like `git`
    public var tool: String

    public init(tool: String) {
        self.tool = tool
    }
}

extension ProcessRunner {
    /// By default there is no limit; fakes answer at once.
    public func run(_ executable: URL, arguments: [String], input: Data?, timeout: Duration) async throws -> ProcessOutput {
        try await run(executable, arguments: arguments, input: input)
    }

    /// By default the lines come all at once, when the tool has ended; fakes that only implement
    /// ``run(_:arguments:input:)`` get this.
    public func run(
        _ executable: URL, arguments: [String], input: Data?, onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessOutput {
        let output = try await run(executable, arguments: arguments, input: input)
        for line in String(decoding: output.standardOutput, as: UTF8.self).split(whereSeparator: \.isNewline) {
            onOutputLine(String(line))
        }
        return output
    }
}

/// Runs the tool as a child process, on a thread of its own, so a slow tool never blocks the caller's actor.
public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ executable: URL, arguments: [String], input: Data?) async throws -> ProcessOutput {
        try await run(executable, arguments: arguments, input: input, lineHandler: nil)
    }

    public func run(
        _ executable: URL, arguments: [String], input: Data?, onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessOutput {
        try await run(executable, arguments: arguments, input: input, lineHandler: onOutputLine)
    }

    public func run(_ executable: URL, arguments: [String], input: Data?, timeout: Duration) async throws -> ProcessOutput {
        try await run(executable, arguments: arguments, input: input, lineHandler: nil, timeout: timeout)
    }

    private func run(
        _ executable: URL, arguments: [String], input: Data?, lineHandler: (@Sendable (String) -> Void)?,
        timeout: Duration? = nil
    ) async throws -> ProcessOutput {
        // Cancelling the calling task ends the tool, so Stop on a Claude answer really stops `claude`.
        let handle = ProcessHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try Self.runToEnd(
                            executable, arguments: arguments, input: input, lineHandler: lineHandler, timeout: timeout,
                            handle: handle)
                    })
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private static func runToEnd(
        _ executable: URL, arguments: [String], input: Data?, lineHandler: (@Sendable (String) -> Void)?,
        timeout: Duration?, handle: ProcessHandle
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        handle.started(process)
        // Ending the tool closes its end of the pipes, so the reads below finish too.
        let limit = timeout.map { ProcessLimit(process, after: $0) }
        defer { limit?.cancel() }

        // stderr is drained on another thread: a tool that fills it while we wait on stdout would never finish.
        let standardError = DrainedPipe(stderr)
        // A tool that ends before reading its input would otherwise make the write raise SIGPIPE, which ends the app.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        if let input {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
        }
        try? stdin.fileHandleForWriting.close()
        let standardOutput = if let lineHandler {
            readLines(stdout.fileHandleForReading, to: lineHandler)
        } else {
            stdout.fileHandleForReading.readDataToEndOfFile()
        }
        process.waitUntilExit()
        if let limit, limit.hasEnded {
            throw ProcessTimedOut(tool: executable.lastPathComponent)
        }
        return ProcessOutput(status: process.terminationStatus, standardOutput: standardOutput, standardError: standardError.data())
    }

    /// Reads a pipe to its end and hands over each line as soon as it is complete. `read(2)` returns what the pipe
    /// holds now, where `readDataToEndOfFile` would wait for the end.
    private static func readLines(_ handle: FileHandle, to lineHandler: @Sendable (String) -> Void) -> Data {
        var all = Data()
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let descriptor = handle.fileDescriptor
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else { break }
            all.append(contentsOf: buffer[..<count])
            pending.append(contentsOf: buffer[..<count])
            while let lineBreak = pending.firstIndex(of: UInt8(ascii: "\n")) {
                lineHandler(line(pending[pending.startIndex..<lineBreak]))
                pending = Data(pending[pending.index(after: lineBreak)...])
            }
        }
        if !pending.isEmpty {
            lineHandler(line(pending))
        }
        return all
    }

    private static func line(_ bytes: Data) -> String {
        var text = String(decoding: bytes, as: UTF8.self)
        if text.hasSuffix("\r") {
            text.removeLast()
        }
        return text
    }
}

/// Lets a cancelled task end the process it waits for: the cancellation may come before the process starts or after.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    // Guarded by `lock`.
    private var process: Process?
    private var isCancelled = false

    /// Remembers the running process, and ends it at once when the task was cancelled before it started.
    func started(_ process: Process) {
        lock.withLock {
            self.process = process
            if isCancelled, process.isRunning {
                process.terminate()
            }
        }
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            if let process, process.isRunning {
                process.terminate()
            }
        }
    }
}

/// Ends a process with SIGTERM once it has run longer than its time limit.
private final class ProcessLimit: @unchecked Sendable {
    private let lock = NSLock()
    // Guarded by `lock`: the timer's thread sets it, the waiting thread reads it.
    private var ended = false
    private var timer: DispatchWorkItem?

    init(_ process: Process, after limit: Duration) {
        let work = DispatchWorkItem { [weak self] in
            self?.end(process)
        }
        timer = work
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// whether the limit ended the process
    var hasEnded: Bool {
        lock.withLock { ended }
    }

    /// Stops the timer, once the process has ended by itself.
    func cancel() {
        timer?.cancel()
    }

    private func end(_ process: Process) {
        lock.withLock {
            guard process.isRunning else { return }
            ended = true
            process.terminate()
        }
    }
}

/// Reads a pipe to its end on a background thread.
private final class DrainedPipe: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    // Written once by the reading thread before `done` is signalled, read only after waiting for it.
    private var result = Data()

    init(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            self.result = handle.readDataToEndOfFile()
            self.done.signal()
        }
    }

    func data() -> Data {
        done.wait()
        return result
    }
}
