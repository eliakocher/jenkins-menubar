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
        let installedPath = folder.file("installed/MegaMonitor.app").path(percentEncoded: false)
        let runner = ScriptedBuild(lines: [
            "Building for production...", "[2 / 8] MenubarCore", "Build complete! (20.12 sec)", "/somewhere/.build/release",
            "installed \(installedPath) (release)",
        ])
        let defaults = TemporaryDefaults()
        let running = try stamp(of: checkout)
        let store = UpdateStore(stamp: running, runner: runner, log: log, home: folder.file("home"), defaults: defaults.defaults)
        #expect(await store.rebuild() == nil, "nothing to rebuild while the checkout is unchanged")
        try folder.write("// changed", to: "checkout/Sources/MenubarCore/A.swift")
        await store.check()
        let newHash = try SourceHash.compute(root: checkout)
        try writeInstalledApp(in: folder, at: "installed/MegaMonitor.app", hash: newHash)

        let app = await store.rebuild()

        // Rebuilder returns a directory URL, whose path ends in a slash: the log line and the handover name the plain
        // path all the same.
        let installed = URL(filePath: installedPath, directoryHint: .isDirectory)
        #expect(app == installed)
        #expect(app?.path(percentEncoded: false).hasSuffix("/") == true)
        #expect(store.state == .installed(installed))
        #expect(!store.offersRebuild)
        await store.check()
        #expect(store.state == .installed(installed), "only the restart is missing")
        let messages = await log.entries().map(\.message)
        #expect(messages.suffix(2) == [
            "Rebuilding the app from \(checkout.path(percentEncoded: false))",
            "Installed the update: \(installedPath), 1.0.7 (8), source hash \(newHash.prefix(12))",
        ])
        let handover = try #require(UpdateHandover.take(from: defaults.defaults, now: Date()))
        #expect(handover.expectedHash == newHash)
        #expect(handover.previousHash == running.sourceHash)
        #expect(handover.installedApp == installedPath)
    }

    @Test(
        "APP-05 a rebuild that installed nothing new never relaunches",
        arguments: [("unchanged", "is still this build"), ("missing", "there is no complete app")])
    func installedNothingNew(kind: String, reason: String) async throws {
        let folder = try TemporaryFolder()
        let checkout = try writeCheckout(in: folder)
        let installedPath = folder.file("installed/MegaMonitor.app").path(percentEncoded: false)
        let running = try stamp(of: checkout)
        if kind == "unchanged" {
            try writeInstalledApp(in: folder, at: "installed/MegaMonitor.app", hash: running.sourceHash)
        }
        let store = UpdateStore(
            stamp: running, runner: ScriptedBuild(lines: ["installed \(installedPath) (release)"]),
            log: ActivityLog(folder: folder.file("Logs")), home: folder.file("home"))
        try folder.write("// changed", to: "checkout/Sources/MenubarCore/A.swift")
        await store.check()

        #expect(await store.rebuild() == nil)
        guard case .failed(let message) = store.state else {
            Issue.record("expected a failure, got \(store.state)")
            return
        }
        #expect(message.contains(reason))
        #expect(store.offersRebuild)
    }

    @Test("APP-05 the start after an update logs whether it took, and offers the update again when it didn't")
    func startAfterUpdate() async throws {
        let folder = try TemporaryFolder()
        let checkout = try writeCheckout(in: folder)
        let old = try stamp(of: checkout)
        try folder.write("// changed", to: "checkout/Sources/MenubarCore/A.swift")
        let new = try stamp(of: checkout)
        let defaults = TemporaryDefaults()
        let installed = "/Users/someone/Applications/MegaMonitor.app"
        let info = { (stamp: BuildStamp, version: String) -> [String: Any] in
            [
                "CFBundleShortVersionString": version, "CFBundleVersion": "8",
                AppIdentity.sourceRootKey: stamp.sourceRoot.path(percentEncoded: false), AppIdentity.sourceHashKey: stamp.sourceHash,
            ]
        }
        let handover = UpdateHandover(
            installedApp: installed, expectedHash: new.sourceHash, previousHash: old.sourceHash,
            previousVersion: "1.0.6 (7)", installedAt: Date())

        // The new build started: it says so, and nothing is offered.
        handover.save(to: defaults.defaults)
        let log = ActivityLog(folder: folder.file("Logs"))
        let updated = UpdateStore(stamp: new, runner: ScriptedBuild(), log: log, defaults: defaults.defaults)
        await updated.launched(bundle: URL(filePath: installed, directoryHint: .isDirectory), info: info(new, "1.0.7"))
        await updated.check()
        #expect(updated.state == .upToDate)
        #expect(await log.entries().map(\.message).last == "Updated from 1.0.6 (7) to 1.0.7 (8)")

        // An old copy at another path started instead: the failure names both paths and the rebuild is offered.
        handover.save(to: defaults.defaults)
        let oldLog = ActivityLog(folder: folder.file("OldLogs"))
        let stillOld = UpdateStore(stamp: old, runner: ScriptedBuild(), log: oldLog, defaults: defaults.defaults)
        await stillOld.launched(bundle: URL(filePath: "/Applications/MegaMonitor.app", directoryHint: .isDirectory), info: info(old, "1.0.6"))
        guard case .failed(let reason) = stillOld.state else {
            Issue.record("expected a failure, got \(stillOld.state)")
            return
        }
        #expect(reason.contains("/Applications/MegaMonitor.app") && reason.contains(installed))
        #expect(stillOld.offersRebuild)
        await stillOld.check()
        #expect(stillOld.state == .failed(reason: reason), "the failure stays while the checkout is unchanged")
        let entries = await oldLog.entries()
        #expect(entries.first?.message.hasPrefix("Started 1.0.6 (8) from /Applications/MegaMonitor.app") == true)
        #expect(entries.last?.level == .warning)
    }

    @Test("APP-05 a check asked for while one runs runs again after it")
    func checkDuringCheck() async throws {
        let stamp = BuildStamp(sourceRoot: URL(filePath: "/checkout"), sourceHash: "built")
        let hashes = HashScript(["built", "pulled"])
        let store = UpdateStore(
            stamp: stamp, runner: ScriptedBuild(), log: nil, home: URL(filePath: "/home"), defaults: nil, settle: .zero,
            now: { Date() }, hasher: { _ in await hashes.next() })

        let first = Task { await store.check() }
        await hashes.waitForCall(1)
        await store.check()
        await hashes.release()
        await first.value

        #expect(await hashes.calls == 2)
        #expect(store.state == .updateReady)
    }

    @Test("APP-05 the checkout's changes start one check once they settle")
    func settlesBeforeChecking() async throws {
        let stamp = BuildStamp(sourceRoot: URL(filePath: "/checkout"), sourceHash: "built")
        let hashes = HashScript(["pulled"], gated: false)
        let store = UpdateStore(
            stamp: stamp, runner: ScriptedBuild(), log: nil, home: URL(filePath: "/home"), defaults: nil,
            settle: .milliseconds(100), now: { Date() }, hasher: { _ in await hashes.next() })

        for _ in 0..<5 {
            store.checkoutDidChange()
        }
        for _ in 0..<100 where store.state != .updateReady {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.state == .updateReady)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await hashes.calls == 1)
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

    /// Writes a bundle like the one `build.sh --install` leaves: Info.plist with version and stamp, and an executable.
    private func writeInstalledApp(in folder: TemporaryFolder, at path: String, hash: String) throws {
        let info: [String: Any] = [
            "CFBundleExecutable": "MegaMonitor", "CFBundleShortVersionString": "1.0.7", "CFBundleVersion": "8",
            AppIdentity.sourceRootKey: "/checkout", AppIdentity.sourceHashKey: hash,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try folder.write(String(decoding: plist, as: UTF8.self), to: "\(path)/Contents/Info.plist")
        let executable = try folder.write("#!/bin/sh", to: "\(path)/Contents/MacOS/MegaMonitor")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path(percentEncoded: false))
    }

    /// Answers the store's hashes in order, the last one again once they run out; while gated, each answer waits for
    /// ``release()``.
    private actor HashScript {
        private var hashes: [String]
        private var gated: Bool
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var calls = 0

        init(_ hashes: [String], gated: Bool = true) {
            self.hashes = hashes
            self.gated = gated
        }

        func next() async -> String? {
            calls += 1
            if gated {
                await withCheckedContinuation { waiting.append($0) }
            }
            if hashes.count > 1 {
                return hashes.removeFirst()
            }
            return hashes.first
        }

        func waitForCall(_ count: Int) async {
            while calls < count {
                await Task.yield()
            }
        }

        func release() {
            gated = false
            waiting.forEach { $0.resume() }
            waiting = []
        }
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
