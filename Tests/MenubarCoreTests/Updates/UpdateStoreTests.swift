import Foundation
import Testing

@testable import MenubarCore

/// The update check and the rebuild, on a made-up checkout in a temporary folder. `build.sh` never runs: a scripted
/// runner answers in its place.
@Suite("UpdateStore and Rebuilder")
@MainActor
struct UpdateStoreTests {
    @Test("APP-05 offers the update when the hash differs")
    func offersTheUpdate() async throws {
        let folder = try TemporaryFolder()
        let checkout = try writeCheckout(in: folder)
        let log = ActivityLog(folder: folder.file("Logs"))
        let store = UpdateStore(stamp: try stamp(of: checkout), runner: ScriptedBuild(), log: log, home: folder.file("home"))

        await store.check()
        #expect(store.state == .upToDate)
        #expect(!store.offersRebuild)

        try folder.write("// changed", to: "checkout/Sources/MenubarCore/A.swift")
        await store.check()
        #expect(store.state == .updateReady)
        #expect(store.offersRebuild)
        await store.check()
        #expect(await log.entries().map(\.message) == ["Update ready: the checkout changed since this build"])

        try folder.write("// a", to: "checkout/Sources/MenubarCore/A.swift")
        await store.check()
        #expect(store.state == .upToDate)

        let unstamped = UpdateStore(stamp: nil, runner: ScriptedBuild())
        await unstamped.check()
        #expect(unstamped.state == .upToDate)
        #expect(await unstamped.rebuild() == nil)
    }

    @Test("APP-05 a failed rebuild shows an error and logs it")
    func failedRebuild() async throws {
        let folder = try TemporaryFolder()
        let checkout = try writeCheckout(in: folder)
        let log = ActivityLog(folder: folder.file("Logs"))
        let checkoutPath = checkout.path(percentEncoded: false)
        let runner = ScriptedBuild(
            lines: ["Building for production...", "[3 / 9] MenubarCore", "\(checkoutPath)/Sources/MenubarCore/A.swift:1:4: error: expected expression"],
            status: 1,
            standardError: "Package.swift: MenubarCore: ld: warning: search path not found\n")
        let store = UpdateStore(stamp: try stamp(of: checkout), runner: runner, log: log, home: folder.file("home"))
        try folder.write("// changed", to: "checkout/Sources/MenubarCore/A.swift")
        await store.check()

        let app = await store.rebuild()

        let reason = "Sources/MenubarCore/A.swift:1:4: error: expected expression"
        #expect(app == nil)
        #expect(store.state == .failed(reason: reason))
        #expect(store.offersRebuild)
        #expect(await runner.calls == [[checkout.appending(path: "build.sh").path(percentEncoded: false), "--install"]])
        let failure = try #require(await log.entries().last)
        #expect(failure.level == .error)
        #expect(failure.source == .app)
        #expect(failure.message == "Update failed: \(reason)")
        #expect(failure.detail?.contains("[3 / 9] MenubarCore") == true)

        // The error stays while the checkout is as it was; a new change offers the update again.
        await store.check()
        #expect(store.state == .failed(reason: reason))
        try folder.write("// fixed", to: "checkout/Sources/MenubarCore/A.swift")
        await store.check()
        #expect(store.state == .updateReady)
    }

    @Test("APP-05 a rebuild runs build.sh --install and returns the installed app")
    func successfulRebuild() async throws {
        let folder = try TemporaryFolder()
        let checkout = try writeCheckout(in: folder)
        let log = ActivityLog(folder: folder.file("Logs"))
        let runner = ScriptedBuild(lines: [
            "Building for production...", "[2 / 8] MenubarCore", "Build complete! (20.12 sec)", "/somewhere/.build/release",
            "installed /Users/someone/Applications/MegaMonitor.app (release)",
        ])
        let store = UpdateStore(stamp: try stamp(of: checkout), runner: runner, log: log, home: folder.file("home"))
        #expect(await store.rebuild() == nil, "nothing to rebuild while the checkout is unchanged")
        try folder.write("// changed", to: "checkout/Sources/MenubarCore/A.swift")
        await store.check()

        let app = await store.rebuild()

        let installed = URL(filePath: "/Users/someone/Applications/MegaMonitor.app", directoryHint: .isDirectory)
        #expect(app == installed)
        #expect(store.state == .installed(installed))
        #expect(!store.offersRebuild)
        await store.check()
        #expect(store.state == .installed(installed), "only the restart is missing")
        let messages = await log.entries().map(\.message)
        #expect(messages.suffix(2) == [
            "Rebuilding the app from \(checkout.path(percentEncoded: false))",
            "Installed the update: /Users/someone/Applications/MegaMonitor.app",
        ])
    }

    @Test("APP-05 the rebuild's progress follows SwiftPM's counts")
    func progress() async throws {
        let folder = try TemporaryFolder()
        let checkout = try writeCheckout(in: folder)
        let thin = "\u{2009}"
        let runner = ScriptedBuild(lines: [
            "Building for production...", "[2/8] Compiling MenubarCore A.swift", "[21\(thin)/\(thin)27] MenubarCore",
            "[3 / 30] MenubarUI", "Build complete! (2.23 sec)", "/somewhere/.build/release",
        ])
        let steps = Collector<RebuildProgress>()

        let app = try await Rebuilder(checkout: checkout, runner: runner, home: folder.file("home")).rebuild { steps.append($0) }

        #expect(app == folder.file("home").appending(path: "Applications/MegaMonitor.app", directoryHint: .isDirectory))
        let values = steps.values
        #expect(values.map(\.step) == ["Compiling MenubarCore A.swift", "MenubarCore", "MenubarUI", "Putting the app together"])
        let fractions = values.compactMap(\.fraction)
        #expect(fractions.count == 4)
        #expect(fractions == fractions.sorted(), "a growing total never moves the bar back")
        #expect(abs(fractions[0] - (0.05 + 0.85 * 2 / 8)) < 0.0001)
        #expect(fractions.last == 0.9)
    }

    @Test("APP-05 a checkout without build.sh can't rebuild")
    func noBuildScript() async throws {
        let folder = try TemporaryFolder()
        let runner = ScriptedBuild()
        let rebuilder = Rebuilder(checkout: folder.url, runner: runner)

        await #expect(throws: RebuildError.self) { try await rebuilder.rebuild() }
        #expect(await runner.calls.isEmpty)
    }

    @Test("APP-05 the process runner hands over each line while the tool runs")
    func streamsLines() async throws {
        let folder = try TemporaryFolder()
        let go = folder.file("go").path(percentEncoded: false)
        // The second line only comes once the test has seen the first one, so lines that came only at the end would
        // print "late" instead.
        let script = #"echo first; i=0; while [ ! -e "$1" ] && [ $i -lt 500 ]; do sleep 0.01; i=$((i + 1)); done; [ -e "$1" ] && echo second || echo late"#
        let lines = Collector<String>()

        let output = try await SystemProcessRunner().run(URL(filePath: "/bin/bash"), arguments: ["-c", script, "bash", go], input: nil) { line in
            lines.append(line)
            if line == "first" {
                FileManager.default.createFile(atPath: go, contents: nil)
            }
        }

        #expect(lines.values == ["first", "second"])
        #expect(String(decoding: output.standardOutput, as: UTF8.self) == "first\nsecond\n")
        #expect(output.status == 0)
    }

    private func writeCheckout(in folder: TemporaryFolder) throws -> URL {
        try folder.write("// swift-tools-version: 6.2", to: "checkout/Package.swift")
        let script = try folder.write("#!/bin/bash\nexit 1", to: "checkout/build.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        try folder.write("// a", to: "checkout/Sources/MenubarCore/A.swift")
        try folder.write("png", to: "checkout/icons/menubar.png")
        return folder.file("checkout")
    }

    private func stamp(of checkout: URL) throws -> BuildStamp {
        BuildStamp(sourceRoot: checkout, sourceHash: try SourceHash.compute(root: checkout))
    }

    /// Answers in place of `build.sh` with scripted stdout lines, stderr and exit status, and records each call. It
    /// implements only the plain `run`, so the lines come through the protocol's default, at the end.
    private actor ScriptedBuild: ProcessRunner {
        private let lines: [String]
        private let status: Int32
        private let standardError: String
        /// the executable's path and the arguments of each call
        private(set) var calls: [[String]] = []

        init(lines: [String] = [], status: Int32 = 0, standardError: String = "") {
            self.lines = lines
            self.status = status
            self.standardError = standardError
        }

        func run(_ executable: URL, arguments: [String], input: Data?) async throws -> ProcessOutput {
            calls.append([executable.path(percentEncoded: false)] + arguments)
            return ProcessOutput(
                status: status,
                standardOutput: Data(lines.map { $0 + "\n" }.joined().utf8),
                standardError: Data(standardError.utf8))
        }
    }

    /// Collects values handed over from any thread.
    private final class Collector<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [Value] = []

        func append(_ value: Value) {
            lock.withLock { collected.append(value) }
        }

        var values: [Value] {
            lock.withLock { collected }
        }
    }
}
