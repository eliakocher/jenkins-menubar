import Foundation
import Testing

@testable import MenubarCore

/// install.sh, run only with `--dry-run`, with `HOME` in a temporary folder and a `PATH` that holds nothing but fake
/// tools and four harmless utilities.
///
/// The fakes answer the script's questions (SwiftBar's plugin folder, the keychain, the login items, running
/// processes) from the scenario's variables and record every call. A test fails on any call that would change
/// something, and `rm`, `ln` and the real tools aren't on the `PATH` at all. The script runs from a copy of the
/// checkout whose `build.sh` only records that it ran. So nothing here touches the real `~/Applications`, `~/Library`,
/// `~/bin`, SwiftBar's settings, `launchctl`, `lsregister` or the login keychain.
@Suite("install.sh")
struct InstallScriptTests {
    @Test("APP-07 install.sh builds the app, installs it and opens it")
    func installs() async throws {
        let world = try World()

        let run = try await world.run([])

        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.contains("would run: \(world.checkout.path)/build.sh --install"))
        #expect(run.output.contains("would run: open \(world.home.path)/Applications/MegaMonitor.app"))
        #expect(!run.output.contains("pkill"))
        #expect(!run.output.contains("old menubar-monitor.app"), "no old bundle, so no note")
        #expect(!run.output.contains("--retire-old"), "no old tool, so no hint")
        #expect(run.output.hasSuffix("A dry run: nothing was changed.\n"))
        #expect(run.changes.isEmpty, "\(run.changes)")
    }

    @Test("APP-07 install.sh quits a running copy first and points to --retire-old")
    func quitsARunningCopy() async throws {
        var world = try World()
        try world.makeOldTool()
        world.variables["FAKE_RUNNING"] = "menubar-monitor"
        world.variables["FAKE_PLUGIN_DIR"] = world.oldTool.appending(path: "plugins").path

        let run = try await world.run([])

        #expect(run.status == 0, "\(run.output)")
        let quit = try #require(run.output.range(of: "would run: pkill -x menubar-monitor"))
        let open = try #require(run.output.range(of: "would run: open "))
        #expect(quit.upperBound < open.lowerBound)
        #expect(run.output.contains("./install.sh --retire-old"))
        #expect(run.changes.isEmpty, "\(run.changes)")
    }

    @Test("APP-07 install.sh quits a copy that still runs under the old executable name and notes the old bundle")
    func quitsTheOldName() async throws {
        var world = try World()
        try world.write("<plist/>", to: "Applications/menubar-monitor.app/Contents/Info.plist")
        world.variables["FAKE_RUNNING"] = "menubar-monitor"

        let run = try await world.run([])

        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.contains("would run: pkill -x menubar-monitor"))
        #expect(!run.output.contains("would run: pkill -x MegaMonitor"))
        #expect(run.output.contains("found the old menubar-monitor.app"))
        #expect(run.output.contains("would run: open \(world.home.path)/Applications/MegaMonitor.app"))
        #expect(run.changes.isEmpty, "\(run.changes)")
    }

    @Test("APP-07 the build moves the old bundle away and marks the login item to register again")
    func migratesTheOldBundle() async throws {
        let folder = try TemporaryFolder()
        let home = folder.file("home")
        let fakes = folder.file("fakes")
        try FileManager.default.createDirectory(at: fakes, withIntermediateDirectories: true)
        let oldApp = home.appending(path: "Applications/menubar-monitor.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: oldApp, withIntermediateDirectories: true)
        let script = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "scripts/migrate-old-bundle.sh")
        let btm = fakes.appending(path: "btm.txt")
        try Data("#!/bin/bash\ncat '\(btm.path)'\n".utf8).write(to: fakes.appending(path: "sfltool"))
        try Data("#!/bin/bash\necho \"$@\" >>'\(fakes.path)/lsregister.log'\n".utf8).write(to: fakes.appending(path: "lsregister"))
        for tool in ["sfltool", "lsregister"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakes.appending(path: tool).path)
        }
        let marker = home.appending(path: "Library/Application Support/menubar-monitor/refresh-login-item")

        func migrate(login: String) async throws -> String {
            try Data(login.utf8).write(to: btm)
            try FileManager.default.createDirectory(at: oldApp, withIntermediateDirectories: true)
            let output = try await SystemProcessRunner().run(
                URL(filePath: "/usr/bin/env"),
                arguments: ["-i", "HOME=\(home.path)", "PATH=\(fakes.path):/usr/bin:/bin", "LSREGISTER=\(fakes.path)/lsregister",
                    "/bin/bash", script.path],
                input: nil)
            #expect(output.status == 0)
            return String(decoding: output.standardOutput, as: UTF8.self)
        }
        let on = """
             Disposition: [enabled, allowed, not notified] (0x3)
              Identifier: 2.local.menubar-monitor
                     URL: /Users/501/Applications/menubar-monitor.app
            """
        let off = on.replacingOccurrences(of: "enabled", with: "disabled")

        // Not a login item: the old bundle goes, Launch Services forgets it and no marker is left.
        _ = try await migrate(login: off)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "Applications/menubar-monitor.app").path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try folder.read("fakes/lsregister.log").contains("-u \(home.path)/Applications/menubar-monitor.app"))

        // A login item: the marker tells the new app to register it again.
        let output = try await migrate(login: on)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(output.contains("registers it again"))
    }

    @Test("APP-07 install.sh stops without the Command Line Tools or macOS 26")
    func checksTheRequirements() async throws {
        var world = try World()
        world.variables["FAKE_NO_CLT"] = "1"

        let noTools = try await world.run([])

        #expect(noTools.status == 1)
        #expect(noTools.output.contains("xcode-select --install"))
        #expect(!noTools.output.contains("build.sh"))

        world.variables["FAKE_NO_CLT"] = nil
        world.variables["FAKE_MACOS"] = "15.7"
        let oldMac = try await world.run([])

        #expect(oldMac.status == 1)
        #expect(oldMac.output.contains("needs macOS 26 or later; this Mac runs macOS 15.7"))
        #expect(!oldMac.output.contains("build.sh"))

        let unknown = try await world.run(["--everything"])
        #expect(unknown.status == 2)
        #expect(noTools.changes.isEmpty && oldMac.changes.isEmpty && unknown.changes.isEmpty)
    }

    @Test("APP-07 install.sh --retire-old unlinks the plugin, removes SwiftBar's login item, jenkins-watch and the helper")
    func retiresTheOldTool() async throws {
        var world = try World()
        try world.makeOldTool()
        try world.installApp()
        let plugins = world.home.appending(path: "Plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try world.link(plugins.appending(path: "jenkins.30s.sh"), to: world.oldTool.appending(path: "plugins/jenkins.30s.sh"))
        try world.link(world.home.appending(path: "bin/jenkins-watch"), to: world.oldTool.appending(path: "bin/jenkins-watch"))
        world.variables["FAKE_PLUGIN_DIR"] = "~/Plugins"
        world.variables["FAKE_LOGIN_ITEMS"] = "Docker, SwiftBar"
        world.variables["FAKE_RUNNING"] = "SwiftBar jenkins-notifier"

        let run = try await world.run(["--retire-old"])

        #expect(run.status == 0, "\(run.output)")
        let old = world.oldTool.path
        #expect(run.lines(startingWith: "would run:") == [
            "would run: rm \(plugins.path)/jenkins.30s.sh",
            #"would run: osascript -e 'tell application "System Events" to delete login item "SwiftBar"'"#,
            "would run: pkill -x SwiftBar",
            "would run: rm \(world.home.path)/bin/jenkins-watch",
            "would run: pkill -x jenkins-notifier",
            "would run: lsregister -u '\(old)/notifier/Jenkins Watch.app'",
        ])
        #expect(run.output.contains("hasn't imported from the old tool yet"), "no deleting before the import")
        #expect(run.output.contains("The old tool's folder \(old) can go (a worktree: git worktree remove \(old))."))
        #expect(run.changes.isEmpty, "\(run.changes)")
    }

    @Test("APP-07 install.sh --retire-old stops SwiftBar from using the old tool's own plugin folder")
    func retiresTheOldPluginFolder() async throws {
        var world = try World()
        try world.makeOldTool()
        try world.installApp()
        world.variables["FAKE_PLUGIN_DIR"] = world.oldTool.appending(path: "plugins").path
        world.variables["FAKE_LOGIN_ITEMS"] = "SwiftBar"

        let run = try await world.run(["--retire-old"])

        #expect(run.status == 0, "\(run.output)")
        #expect(run.lines(startingWith: "would run:") == [
            "would run: defaults delete com.ameba.SwiftBar PluginDirectory",
            #"would run: osascript -e 'tell application "System Events" to delete login item "SwiftBar"'"#,
            "would run: lsregister -u '\(world.oldTool.path)/notifier/Jenkins Watch.app'",
        ])
        #expect(run.changes.isEmpty, "\(run.changes)")
    }

    @Test("APP-07 install.sh --retire-old keeps SwiftBar for other plugins and a jenkins-watch that isn't the old one")
    func keepsWhatOthersUse() async throws {
        var world = try World()
        try world.makeOldTool()
        try world.installApp()
        let plugins = world.home.appending(path: "Plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try world.link(plugins.appending(path: "jenkins.30s.sh"), to: world.oldTool.appending(path: "plugins/jenkins.30s.sh"))
        try Data("#!/bin/bash\necho weather".utf8).write(to: plugins.appending(path: "weather.10m.sh"))
        try FileManager.default.createDirectory(at: world.home.appending(path: "bin"), withIntermediateDirectories: true)
        try Data("#!/bin/bash\nopen \"menubar-monitor://watch?target=$1\"".utf8).write(to: world.home.appending(path: "bin/jenkins-watch"))
        world.variables["FAKE_PLUGIN_DIR"] = plugins.path
        world.variables["FAKE_LOGIN_ITEMS"] = "SwiftBar"
        world.variables["FAKE_RUNNING"] = "SwiftBar"

        let run = try await world.run(["--retire-old"])

        #expect(run.status == 0, "\(run.output)")
        #expect(run.lines(startingWith: "would run:") == [
            "would run: rm \(plugins.path)/jenkins.30s.sh",
            "would run: lsregister -u '\(world.oldTool.path)/notifier/Jenkins Watch.app'",
        ])
        #expect(run.output.contains("SwiftBar stays a login item and keeps running: other plugins use it"))
        #expect(run.output.contains("~/bin/jenkins-watch isn't a link to the old command, so it stays"))
        #expect(run.changes.isEmpty, "\(run.changes)")
    }

    @Test("APP-07 install.sh --retire-old deletes the old caches, logs and keychain items only after a yes")
    func deletesAfterAYes() async throws {
        var world = try World()
        try world.installApp()
        try world.write("{}", to: "Library/Application Support/menubar-monitor/legacy-import.json")
        try world.write("MR-1", to: "Library/Caches/jenkins-menubar/watched")
        try world.write("{}", to: "Library/Logs/jenkins-menubar/jenkins-menubar.log")
        world.variables["FAKE_KEYCHAIN"] =
            "jenkins-menubar/JENKINS_MCP_BASIC_AUTH jenkins-menubar/GITLAB_TOKEN menubar-monitor/JENKINS_MCP_BASIC_AUTH"
        world.variables["FAKE_HELPER_DEFAULTS"] = "1"

        let no = try await world.run(["--retire-old"], input: "n\n")
        let nothing = try await world.run(["--retire-old"])
        let yes = try await world.run(["--retire-old"], input: "y\n")

        for run in [no, nothing] {
            #expect(run.status == 0, "\(run.output)")
            #expect(run.output.contains("Delete them? [y/N]"))
            #expect(run.output.contains("• kept them"))
            #expect(run.lines(startingWith: "would run:").isEmpty)
        }
        #expect(yes.status == 0, "\(yes.output)")
        let library = world.home.appending(path: "Library").path
        #expect(yes.lines(startingWith: "would run:") == [
            "would run: rm -rf \(library)/Caches/jenkins-menubar",
            "would run: rm -rf \(library)/Logs/jenkins-menubar",
            "would run: security delete-generic-password -s jenkins-menubar -a JENKINS_MCP_BASIC_AUTH",
            "would run: defaults delete local.jenkins-menubar.notifier",
        ])
        #expect(yes.output.contains("keeps the keychain item jenkins-menubar GITLAB_TOKEN: MegaMonitor has no copy of it yet"))
        #expect(no.changes.isEmpty && nothing.changes.isEmpty && yes.changes.isEmpty)
    }

    @Test("APP-07 install.sh --retire-old needs the installed app")
    func needsTheApp() async throws {
        let world = try World()

        let run = try await world.run(["--retire-old"])

        #expect(run.status == 1)
        #expect(run.output.contains("MegaMonitor isn't installed: run ./install.sh first"))
        #expect(run.changes.isEmpty, "\(run.changes)")
    }

    /// A made-up machine in a temporary folder: a home, a copy of the checkout, the fake tools, and the old tool's
    /// folder once ``makeOldTool()`` made it.
    private struct World {
        private let folder: TemporaryFolder
        /// the temporary folder with its links resolved (`/private/var/…`), as the script's `realpath` prints it
        let base: URL
        /// the scenario: `FAKE_PLUGIN_DIR`, `FAKE_LOGIN_ITEMS`, `FAKE_RUNNING`, `FAKE_KEYCHAIN` ("service/account"
        /// words), `FAKE_HELPER_DEFAULTS`, `FAKE_NO_CLT`, `FAKE_MACOS`
        var variables: [String: String] = [:]

        var home: URL { base.appending(path: "home") }
        var checkout: URL { base.appending(path: "checkout") }
        var oldTool: URL { base.appending(path: "old") }
        private var fakes: URL { base.appending(path: "fakes") }
        private var utilities: URL { base.appending(path: "utilities") }
        private var calls: URL { base.appending(path: "calls.log") }

        private static var repositoryRoot: URL {
            URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
        }

        init() throws {
            folder = try TemporaryFolder()
            // resolvingSymlinksInPath() drops the /private that realpath(1) keeps.
            let resolved = try #require(realpath(folder.url.path(percentEncoded: false), nil))
            defer { free(resolved) }
            base = URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
            let manager = FileManager.default
            for url in [home, checkout, fakes, utilities] {
                try manager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            let script = checkout.appending(path: "install.sh")
            try manager.copyItem(at: Self.repositoryRoot.appending(path: "install.sh"), to: script)
            try writeScript(#"printf 'build.sh %s\n' "$*" >>"$CALLS""#, to: checkout.appending(path: "build.sh"))
            try writeScript(Self.fakeTool, to: fakes.appending(path: "fake-tool"))
            for tool in ["defaults", "security", "osascript", "pgrep", "pkill", "open", "xcode-select", "xcrun", "sw_vers", "lsregister", "launchctl"] {
                try manager.createSymbolicLink(atPath: fakes.appending(path: tool).path, withDestinationPath: "fake-tool")
            }
            for utility in ["/usr/bin/dirname", "/usr/bin/grep", "/bin/realpath", "/bin/ls"] {
                let name = URL(filePath: utility).lastPathComponent
                try manager.createSymbolicLink(atPath: utilities.appending(path: name).path, withDestinationPath: utility)
            }
        }

        /// Creates the old tool's folder the way the old install.sh left it: the plugin, jenkins-watch, the built helper
        /// app and the team values.
        func makeOldTool() throws {
            try write(#"cache_dir="$HOME/Library/Caches/jenkins-menubar""#, at: oldTool.appending(path: "plugins/jenkins.30s.sh"))
            try write(#"log_file="$HOME/Library/Logs/jenkins-menubar/jenkins-menubar.log""#, at: oldTool.appending(path: "bin/jenkins-watch"))
            try write("<plist/>", at: oldTool.appending(path: "notifier/Jenkins Watch.app/Contents/Info.plist"))
            try write("jenkins_url=https://jenkins.example.com/job/project/", at: oldTool.appending(path: "config/team.conf"))
        }

        /// Creates the installed app, which `--retire-old` asks for.
        func installApp() throws {
            try write("<plist/>", to: "Applications/MegaMonitor.app/Contents/Info.plist")
        }

        func write(_ text: String, to pathInHome: String) throws {
            try write(text, at: home.appending(path: pathInHome))
        }

        func link(_ link: URL, to destination: URL) throws {
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        }

        /// Runs `install.sh --dry-run` with the arguments, in an empty environment but for `HOME`, `PATH`, `TMPDIR`
        /// and the scenario.
        func run(_ arguments: [String], input: String = "") async throws -> ScriptRun {
            try? FileManager.default.removeItem(at: calls)
            var environment = variables
            environment["HOME"] = home.path
            environment["PATH"] = "\(fakes.path):\(utilities.path)"
            environment["TMPDIR"] = base.path
            environment["CALLS"] = calls.path
            let output = try await SystemProcessRunner().run(
                URL(filePath: "/usr/bin/env"),
                arguments: ["-i"] + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                    + ["/bin/bash", checkout.appending(path: "install.sh").path] + arguments + ["--dry-run"],
                input: Data(input.utf8))
            let recorded = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
            return ScriptRun(
                status: output.status,
                output: String(decoding: output.standardOutput, as: UTF8.self) + String(decoding: output.standardError, as: UTF8.self),
                calls: recorded.split(separator: "\n").map(String.init))
        }

        private func write(_ text: String, at url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        private func writeScript(_ body: String, to url: URL) throws {
            try write("#!/bin/bash\n" + body + "\n", at: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        /// One script for every faked tool, which tells them apart by the name it was called by. It records the call,
        /// then answers the questions install.sh asks; anything else would change something, and the test fails on it.
        private static let fakeTool = #"""
            name=${0##*/}
            printf '%s' "$name" >>"$CALLS"
            printf ' %s' "$@" >>"$CALLS"
            printf '\n' >>"$CALLS"
            case "$name $*" in
            "defaults read com.ameba.SwiftBar PluginDirectory")
                [[ -n ${FAKE_PLUGIN_DIR:-} ]] || exit 1
                echo "$FAKE_PLUGIN_DIR"
                ;;
            "defaults read local.jenkins-menubar.notifier") [[ -n ${FAKE_HELPER_DEFAULTS:-} ]] ;;
            "security find-generic-password -s "*) [[ " ${FAKE_KEYCHAIN:-} " == *" $3/$5 "* ]] || exit 44 ;;
            "osascript -e tell application \"System Events\" to get the name of every login item") echo "${FAKE_LOGIN_ITEMS:-}" ;;
            "pgrep -x "*) [[ " ${FAKE_RUNNING:-} " == *" $2 "* ]] ;;
            "xcode-select -p")
                [[ -z ${FAKE_NO_CLT:-} ]] || exit 2
                echo /Library/Developer/CommandLineTools
                ;;
            "xcrun --find swift") echo /usr/bin/swift ;;
            "sw_vers -productVersion") echo "${FAKE_MACOS:-26.1}" ;;
            esac
            """#
    }

    /// What a run of install.sh did.
    private struct ScriptRun {
        var status: Int32
        /// stdout, then stderr
        var output: String
        /// every call of a fake tool or of `build.sh`, as "<name> <arguments>"
        var calls: [String]

        /// the calls that would have changed something: every call but the questions install.sh asks
        var changes: [String] {
            let questions = [
                "defaults read ", "security find-generic-password ", "osascript -e tell application \"System Events\" to get ",
                "pgrep -x ", "xcode-select -p", "xcrun --find swift", "sw_vers -productVersion",
            ]
            return calls.filter { call in !questions.contains { call.hasPrefix($0) } }
        }

        func lines(startingWith prefix: String) -> [String] {
            output.split(separator: "\n").map(String.init).filter { $0.hasPrefix(prefix) }
        }
    }
}
