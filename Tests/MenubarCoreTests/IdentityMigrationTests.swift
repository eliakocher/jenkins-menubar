import Foundation
import Testing

@testable import MenubarCore

/// The identity migration (APP-10), against temporary UserDefaults suites, temporary folders and in-memory keychains:
/// never the real domains, folders or the login keychain.
@MainActor
@Suite("IdentityMigration")
struct IdentityMigrationTests {
    /// Two suites, the former and the new domain, and the folders of both in one temporary folder.
    @MainActor
    private struct World {
        let former = TemporaryDefaults()
        let current = TemporaryDefaults()
        let folder: TemporaryFolder
        let migration: IdentityMigration

        init() throws {
            folder = try TemporaryFolder()
            migration = IdentityMigration(
                formerDomain: former.suiteName, currentDomain: current.suiteName,
                formerLocations: FileLocations(root: folder.file("former")),
                currentLocations: FileLocations(root: folder.file("current")),
                defaults: current.defaults)
        }
    }

    @Test("APP-10 copies the former preferences and folders once, keeps what the new identity has, leaves the originals")
    func copiesOnce() throws {
        let world = try World()
        let former = world.former.defaults
        former.set(false, forKey: "showInMenuBar")
        former.set(true, forKey: "linkRouting.enabled")
        former.set(["section": "pipelines", "width": 240], forKey: "mainWindow")
        former.set("former", forKey: "kept")
        world.current.defaults.set("current", forKey: "kept")
        let folder = world.folder
        try folder.write(#"{"projects":[]}"#, to: "former/Application Support/projects.json")
        try folder.write("{}", to: "former/Application Support/state/watched.json")
        try folder.write("old cache", to: "former/Caches/main/jenkins.json")
        try folder.write("{}", to: "former/Logs/menubar-monitor.log")
        try folder.write("{}", to: "former/Logs/menubar-monitor.log.1")
        try folder.write("{}", to: "former/Logs/requests/1.json")
        // What the new identity has already: scripts/migrate-old-bundle.sh's marker and a cache of its own.
        try folder.write("", to: "current/Application Support/refresh-login-item")
        try folder.write("new cache", to: "current/Caches/main/jenkins.json")
        let formerFiles = folder.contents().filter { $0.hasPrefix("former/") }

        let report = try #require(world.migration.moveFilesAndDefaults())

        #expect(report.problems.isEmpty, "\(report.problems)")
        #expect(report.foundFormer)
        #expect(report.copiedKeys == 3 && report.keptKeys == 1)
        #expect(report.reclaimDefaultBrowser, "the router was on under the former bundle id")
        let current = world.current.defaults
        #expect(current.object(forKey: "showInMenuBar") as? Bool == false)
        #expect(current.dictionary(forKey: "mainWindow")?["section"] as? String == "pipelines")
        #expect(current.string(forKey: "kept") == "current")
        #expect(former.string(forKey: "kept") == "former", "the former domain stays")
        #expect(report.copiedItems == [
            "Application Support/projects.json", "Application Support/state", "Logs/MegaMonitor.log",
            "Logs/MegaMonitor.log.1", "Logs/requests",
        ])
        #expect(report.keptItems == ["Caches/main"])
        #expect(try folder.read("current/Application Support/projects.json") == #"{"projects":[]}"#)
        #expect(try folder.read("current/Application Support/state/watched.json") == "{}")
        #expect(try folder.read("current/Caches/main/jenkins.json") == "new cache")
        #expect(folder.contents().contains("current/Logs/requests/1.json"))
        #expect(folder.contents().filter { $0.hasPrefix("former/") } == formerFiles, "the former folders stay")
        #expect(world.migration.moveFilesAndDefaults() == nil, "it runs once")
    }

    @Test("APP-10 a fresh install finds nothing and marks itself done")
    func freshInstall() throws {
        let world = try World()

        let report = try #require(world.migration.moveFilesAndDefaults())

        #expect(!report.foundFormer && report.problems.isEmpty && !report.reclaimDefaultBrowser)
        #expect(world.migration.moveFilesAndDefaults() == nil)
    }

    @Test("APP-10 a copy that fails is removed and tried again at the next launch")
    func failedCopyIsRetried() throws {
        let world = try World()
        let unreadable = try world.folder.write("{}", to: "former/Caches/main/secret.json")
        try world.folder.write("{}", to: "former/Caches/main/jenkins.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }

        let failed = try #require(world.migration.moveFilesAndDefaults())

        #expect(failed.problems.count == 1)
        #expect(failed.problems.first?.hasPrefix("couldn't copy Caches/main") == true)
        #expect(!FileManager.default.fileExists(atPath: world.folder.file("current/Caches/main").path), "no half copy")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path)
        let retried = try #require(world.migration.moveFilesAndDefaults(), "not done while something failed")
        #expect(retried.problems.isEmpty && retried.copiedItems == ["Caches/main"])
    }

    @Test("APP-10 copies the tokens once, keeps one the new service has, and never logs one")
    func copiesTokens() async throws {
        let world = try World()
        let former = InMemoryKeychain(values: ["JENKINS_MCP_BASIC_AUTH": "amRvZTpzZWNyZXQ=", "GITLAB_TOKEN": "glpat-former"])
        let current = InMemoryKeychain(values: ["GITLAB_TOKEN": "glpat-current"])
        await current.failStoring(with: .notStored)

        let failed = try #require(await world.migration.moveTokens(from: former, to: current))
        await current.failStoring(with: nil)
        let report = try #require(await world.migration.moveTokens(from: former, to: current), "tried again after a failure")

        #expect(failed.problems == ["couldn't copy the Jenkins token: The keychain did not take the token"])
        #expect(report.copied == ["Jenkins"] && report.kept == ["GitLab"] && report.problems.isEmpty)
        #expect(await current.values == ["JENKINS_MCP_BASIC_AUTH": "amRvZTpzZWNyZXQ=", "GITLAB_TOKEN": "glpat-current"])
        #expect(await former.values.count == 2, "the former items stay")
        let lines = (failed.logLines + report.logLines).joined(separator: "\n")
        #expect(!lines.contains("amRvZTpzZWNyZXQ=") && !lines.contains("glpat"))
        #expect(await world.migration.moveTokens(from: former, to: current) == nil, "it runs once")
    }

    @Test("APP-10 the link router comes back on after the rename, with the remembered browser")
    func reclaimsTheDefaultBrowser() async throws {
        let defaults = TemporaryDefaults()
        let firefox = BrowserApp(url: URL(filePath: "/Applications/Firefox.app"), bundleID: "org.mozilla.firefox", name: "Firefox")
        // As copied from the former domain: on, with Firefox remembered; macOS still names the former bundle id.
        defaults.defaults.set(true, forKey: LinkRouting.enabledKey)
        defaults.defaults.set(try JSONEncoder().encode(firefox), forKey: LinkRouting.browserKey)
        let system = RenamedBrowsers(installed: [firefox])
        let routing = LinkRouting(system: system, defaults: defaults.defaults, projects: { [] })
        #expect(!routing.isOn, "refresh() reads the former id as another browser")

        system.refuses = true
        await routing.reclaimAfterRename()
        #expect(!routing.isOn && routing.note != nil)
        system.refuses = false
        await routing.reclaimAfterRename()

        #expect(routing.isOn && defaults.defaults.bool(forKey: LinkRouting.enabledKey))
        #expect(system.current == RenamedBrowsers.me)
        #expect(routing.forwardTarget == firefox)
    }

    @Test("APP-10 links of the former scheme still open")
    func formerScheme() throws {
        for link in ["menubar-monitor://settings/team", "megamonitor://settings/team", "MegaMonitor://settings/team"] {
            #expect(AppRoute(url: try #require(URL(string: link))) == .settings(.team), "\(link)")
        }
        #expect(AppRoute.settings(.team).url.scheme == "megamonitor")
        #expect(AppRoute(url: try #require(URL(string: "https://settings/team"))) == nil)
    }
}

/// A Mac after the rename: the default browser is the former bundle id, which no installed app has.
@MainActor
private final class RenamedBrowsers: DefaultBrowserSystem {
    static let me = BrowserApp(url: URL(filePath: "/Applications/MegaMonitor.app"), bundleID: AppIdentity.bundleID, name: "MegaMonitor")
    static let former = BrowserApp(url: URL(filePath: "/Applications/MegaMonitor.app"), bundleID: AppIdentity.Former.bundleID, name: "MegaMonitor")

    var thisApp: BrowserApp? { Self.me }
    var current: BrowserApp? = former
    var installed: [BrowserApp]
    var refuses = false

    init(installed: [BrowserApp]) {
        self.installed = installed
    }

    func defaultBrowser() -> BrowserApp? { current }
    func app(bundleID: String) -> BrowserApp? { installed.first { $0.bundleID == bundleID } }
    func exists(_ app: BrowserApp) -> Bool { installed.contains(app) }

    func setDefaultBrowser(_ app: BrowserApp) async throws {
        if refuses {
            throw CocoaError(.userCancelled)
        }
        current = app
    }

    func open(_ url: URL, with app: BrowserApp) async {}
}
