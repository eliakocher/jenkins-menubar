import Foundation

/// Rebuilds the app from its checkout and installs it, by running `<checkout>/build.sh --install` (APP-05).
///
/// The app's part, which opens the installed bundle and quits, comes after: ``rebuild(progress:)`` returns the bundle.
public struct Rebuilder: Sendable {
    /// the checkout the app was built from, ``BuildStamp/sourceRoot``
    public let checkout: URL
    private let runner: any ProcessRunner
    private let home: URL

    /// Creates a rebuilder for a checkout.
    ///
    /// - Parameters:
    ///   - checkout: the checkout, whose `build.sh` runs
    ///   - runner: runs `build.sh`; the tests pass a fake
    ///   - home: the home folder whose `Applications` folder `build.sh --install` installs into
    public init(checkout: URL, runner: any ProcessRunner = SystemProcessRunner(), home: URL = URL.homeDirectory) {
        self.checkout = checkout
        self.runner = runner
        self.home = home
    }

    /// the app `build.sh --install` installs, unless its output names another one
    public var defaultInstalledApp: URL {
        home.appending(path: "Applications/\(AppIdentity.bundleFileName)", directoryHint: .isDirectory)
    }

    /// Runs `build.sh --install` to its end. A rebuild takes from a few seconds to about a minute.
    ///
    /// - Parameter progress: called with each step `build.sh` reports, from a background thread
    /// - Returns: the installed app, as `build.sh` names it in its last line
    /// - Throws: a ``RebuildError`` with the reason
    public func rebuild(progress: @escaping @Sendable (RebuildProgress) -> Void = { _ in }) async throws -> URL {
        let script = checkout.appending(path: "build.sh", directoryHint: .notDirectory)
        guard FileManager.default.isExecutableFile(atPath: script.path(percentEncoded: false)) else {
            throw RebuildError(reason: "the checkout has no build.sh at \(script.path(percentEncoded: false))")
        }
        let parser = ProgressParser()
        let output: ProcessOutput
        do {
            output = try await runner.run(script, arguments: ["--install"], input: nil) { line in
                if let step = parser.consume(line) {
                    progress(step)
                }
            }
        } catch {
            throw RebuildError(reason: "build.sh could not be started: \(error.localizedDescription)")
        }
        let standardOutput = String(decoding: output.standardOutput, as: UTF8.self)
        let standardError = String(decoding: output.standardError, as: UTF8.self)
        guard output.status == 0 else {
            throw RebuildError(
                reason: failureReason(standardOutput: standardOutput, standardError: standardError, status: output.status),
                output: Self.tail(standardError + "\n" + standardOutput))
        }
        return installedApp(in: standardOutput)
    }

    /// The bundle of `build.sh`'s last line, "installed <bundle> (release)".
    private func installedApp(in standardOutput: String) -> URL {
        for line in standardOutput.split(whereSeparator: \.isNewline).reversed() {
            if let match = line.wholeMatch(of: /installed (.+\.app) \((?:release|debug)\)/) {
                return URL(filePath: String(match.1), directoryHint: .isDirectory)
            }
        }
        return defaultInstalledApp
    }

    /// The first compiler or script error, else the last line `build.sh` wrote to stderr, else its exit code. Paths in
    /// the checkout are shortened to relative ones.
    private func failureReason(standardOutput: String, standardError: String, status: Int32) -> String {
        let lines = { (text: String) in
            text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let errors = lines(standardOutput) + lines(standardError)
        let reason = errors.first { $0.localizedCaseInsensitiveContains("error:") }
            ?? lines(standardError).last
            ?? "build.sh stopped with exit code \(status)"
        let prefix = checkout.standardizedFileURL.path(percentEncoded: false)
        let relative = reason.replacingOccurrences(of: prefix.hasSuffix("/") ? prefix : prefix + "/", with: "")
        return String(relative.prefix(Self.maxReasonLength))
    }

    /// the most characters of a reason, so the error row and the log line stay readable
    static let maxReasonLength = 300

    /// The last lines of the output, for the log entry's detail.
    private static func tail(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        return lines.suffix(12).joined(separator: "\n")
    }
}

/// How far a rebuild is.
public struct RebuildProgress: Sendable, Hashable {
    /// how much is done, from 0 to 1; nil until `build.sh` reports a count
    public var fraction: Double?
    /// the step, from `build.sh`'s output, like "MenubarCore" or "Compiling MenubarCore Build.swift"
    public var step: String

    public init(fraction: Double?, step: String) {
        self.fraction = fraction
        self.step = step
    }

    /// the progress before `build.sh` has written anything
    public static let starting = RebuildProgress(fraction: nil, step: "Starting build.sh")
}

/// Why a rebuild failed.
public struct RebuildError: Error, Hashable, Sendable, LocalizedError {
    /// the reason the error row shows, like "Sources/MenubarCore/A.swift:3:1: error: expected expression"
    public var reason: String
    /// the last lines of `build.sh`'s output, for the log entry's detail
    public var output: String

    public init(reason: String, output: String = "") {
        self.reason = reason
        self.output = output
    }

    /// the log line, "Update failed: <reason>"
    public var message: String {
        "Update failed: \(reason)"
    }

    public var errorDescription: String? { message }
}

extension Rebuilder {
    /// Turns `build.sh`'s lines into progress. Compiling is most of a rebuild, so SwiftPM's counts, "[5/24] …" or
    /// "[5 / 24] …", fill 0.05 to 0.9 of it; "complete!" is 0.9, and the "installed …" line 1. SwiftPM's total grows
    /// while it plans, so the fraction never goes back.
    final class ProgressParser: @unchecked Sendable {
        // Called only from the one thread that reads build.sh's output.
        private var fraction: Double?

        func consume(_ line: String) -> RebuildProgress? {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let match = text.wholeMatch(of: /\[(\d+)\s*\/\s*(\d+)\]\s*(.*)/), let done = Double(match.1),
               let total = Double(match.2), total > 0 {
                return advance(to: 0.05 + 0.85 * min(done / total, 1), step: String(match.3))
            }
            if text.hasSuffix("complete!") || text.contains("complete! (") {
                return advance(to: 0.9, step: "Putting the app together")
            }
            if text.hasPrefix("installed ") {
                return advance(to: 1, step: "Installed")
            }
            return nil
        }

        private func advance(to value: Double, step: String) -> RebuildProgress {
            let next = max(fraction ?? 0, value)
            fraction = next
            return RebuildProgress(fraction: next, step: step)
        }
    }
}
