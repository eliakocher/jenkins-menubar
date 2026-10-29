import Foundation

/// A program and its arguments, from the Open in IDE command of Settings → Repositories (WS-05).
///
/// The rules for commands (the plan's Phase 16): the command comes only from the user's own Settings; it runs without
/// a shell, the program and each argument apart; `{name}` and `{path}` are replaced inside an argument, so a path with
/// spaces stays one argument and nothing in it is ever read as syntax.
public struct LaunchCommand: Hashable, Sendable {
    /// the program as typed: a name like `code`, or a path like `~/bin/ide`
    public var program: String
    /// the arguments, the placeholders replaced
    public var arguments: [String]

    public init(program: String, arguments: [String]) {
        self.program = program
        self.arguments = arguments
    }

    /// the placeholder for the checkout's folder name, like `develop3`
    public static let namePlaceholder = "{name}"
    /// the placeholder for the checkout's full path
    public static let pathPlaceholder = "{path}"

    /// Builds the command for a checkout.
    ///
    /// - Parameters:
    ///   - line: the command line as typed, like `idea {path}`
    ///   - name: the checkout's name, for `{name}`
    ///   - path: the checkout's path, for `{path}`
    /// - Returns: the command; `nil` for an empty line or an unclosed quote
    public static func make(_ line: String, name: String, path: String) -> LaunchCommand? {
        guard let words = words(of: line), let program = words.first else {
            return nil
        }
        let arguments = words.dropFirst().map { word in
            word.replacingOccurrences(of: namePlaceholder, with: name)
                .replacingOccurrences(of: pathPlaceholder, with: path)
        }
        return LaunchCommand(program: program, arguments: Array(arguments))
    }

    /// Splits a command line into its words, as the user means them: spaces part words; double or single quotes keep
    /// spaces in a word; a backslash keeps the next character. Nothing else is special: no variables, `~`, globs,
    /// pipes or `;`, because no shell ever sees the line.
    ///
    /// - Parameter line: the command line
    /// - Returns: the words; `nil` for an unclosed quote
    public static func words(of line: String) -> [String]? {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                word.append(character)
                escaped = false
                continue
            }
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\" && open == "\"" {
                    escaped = true
                } else {
                    word.append(character)
                }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                inWord = true
            case "\\":
                escaped = true
                inWord = true
            case _ where character.isWhitespace:
                if inWord {
                    words.append(word)
                    word = ""
                    inWord = false
                }
            default:
                word.append(character)
                inWord = true
            }
        }
        guard quote == nil, !escaped else {
            return nil
        }
        if inWord {
            words.append(word)
        }
        return words
    }
}

/// Finds a program's full path the way the user's Terminal would. A GUI app doesn't get the shell's `PATH`, so it asks
/// the user's login shell once for its `PATH` (`zsh -lc` with a fixed script: no user text goes into it), and adds the
/// usual places of command line tools and IDE launchers (WS-05).
public actor ProgramResolver {
    /// the time limit of the login shell
    public static let shellTimeout: Duration = .seconds(5)

    private let runner: any ProcessRunner
    private let home: URL
    private let isExecutable: @Sendable (String) -> Bool
    private var loginPath: [String]?

    /// - Parameters:
    ///   - runner: runs the login shell
    ///   - home: the home folder, for `~` and the usual places in it
    ///   - isExecutable: whether a path is a program that can run
    public init(
        runner: any ProcessRunner, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: @escaping @Sendable (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }
    ) {
        self.runner = runner
        self.home = home
        self.isExecutable = isExecutable
    }

    /// Returns the usual places of command line tools and IDE launchers, which a GUI app's `PATH` lacks.
    ///
    /// - Parameter home: the home folder's path
    /// - Returns: the folders, in the order they are searched after the login shell's `PATH`
    public static func usualPlaces(home: String) -> [String] {
        [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin",
            "\(home)/Library/Application Support/JetBrains/Toolbox/scripts",
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
    }

    /// Returns the folders searched for a program: the login shell's `PATH`, then the usual places, each once.
    public func searchPath() async -> [String] {
        let shell: [String]
        if let loginPath {
            shell = loginPath
        } else {
            shell = await Self.readLoginPath(runner)
            loginPath = shell
        }
        var seen = Set<String>()
        return (shell + Self.usualPlaces(home: home.path(percentEncoded: false).trimmingSuffix("/")))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Returns a program's full path: a path as typed (`~` is the home folder), or the first folder of
    /// ``searchPath()`` that has it.
    ///
    /// - Parameter program: the program as typed
    /// - Returns: the program; `nil` when it isn't found or can't run
    public func resolve(_ program: String) async -> URL? {
        if program.contains("/") {
            guard let path = WorkspaceDiscovery.expand(program, home: home), isExecutable(path) else {
                return nil
            }
            return URL(filePath: path)
        }
        for folder in await searchPath() {
            let path = "\(folder)/\(program)"
            if isExecutable(path) {
                return URL(filePath: path)
            }
        }
        return nil
    }

    /// Asks the login shell for its `PATH`. The script is fixed; what `.zprofile` prints before it is skipped.
    private static func readLoginPath(_ runner: any ProcessRunner) async -> [String] {
        guard let output = try? await runner.run(
            URL(filePath: "/bin/zsh"), arguments: ["-lc", #"printf '\n%s\n' "$PATH""#], input: nil,
            timeout: shellTimeout),
            output.status == 0,
            let line = String(decoding: output.standardOutput, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last else {
            return []
        }
        return line.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        var text = self
        while text.count > 1, text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        return text
    }
}

/// How a launched program ended, or that it still runs.
public enum LaunchOutcome: Hashable, Sendable {
    /// it ended within the wait, with its exit status and the last line it wrote, stdout and stderr together
    case exited(status: Int32, lastLine: String?)
    /// it still runs after the wait, like an IDE that a launcher script runs in the foreground; it is left alone
    case running
}

/// Starts a program the user set up, apart from the app (WS-05).
public protocol ProgramLauncher: Sendable {
    /// Starts a program and waits for it to end, up to `wait`.
    ///
    /// - Parameters:
    ///   - program: the program's full path
    ///   - arguments: its arguments, each one as it is
    ///   - directory: its working folder
    ///   - path: the `PATH` it gets; `nil` keeps the app's
    ///   - wait: how long to wait for it to end
    /// - Returns: how it ended, or that it still runs
    func launch(
        _ program: URL, arguments: [String], directory: URL?, path: [String]?, wait: Duration
    ) async throws -> LaunchOutcome
}

/// Starts programs as child processes whose output goes to a temporary file, not a pipe, so a launcher that leaves an
/// IDE running with the output still open can't hold the app up; a program still running after the wait is left
/// alone, never ended.
public struct SystemProgramLauncher: ProgramLauncher {
    public init() {}

    public func launch(
        _ program: URL, arguments: [String], directory: URL?, path: [String]?, wait: Duration
    ) async throws -> LaunchOutcome {
        let log = FileManager.default.temporaryDirectory
            .appending(path: "menubar-monitor-launch-\(UUID().uuidString).log", directoryHint: .notDirectory)
        FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let path {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = path.joined(separator: ":")
            process.environment = environment
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let ended = LaunchWait()
        process.terminationHandler = { _ in ended.finish() }
        try process.run()
        let seconds = Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18
        guard await ended.wait(seconds: seconds) else {
            return .running
        }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let lastLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
            .map { String($0.prefix(300)) }
        return .exited(status: process.terminationStatus, lastLine: lastLine)
    }
}

/// Waits for a process's end, or for a time, whichever comes first.
private final class LaunchWait: @unchecked Sendable {
    private let lock = NSLock()
    // Guarded by `lock`.
    private var hasEnded = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func finish() {
        resume(with: true)
    }

    /// Returns `true` when the process ended within the time.
    func wait(seconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            let endedAlready = lock.withLock {
                if hasEnded {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if endedAlready {
                continuation.resume(returning: true)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [self] in
                resume(with: false)
            }
        }
    }

    private func resume(with ended: Bool) {
        let waiting: CheckedContinuation<Bool, Never>? = lock.withLock {
            if ended {
                hasEnded = true
            }
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(returning: ended)
    }
}
