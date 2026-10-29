import Foundation
import Testing

@testable import MenubarCore

/// The import from a copy of the old tool's files (`Tests/Fixtures/Legacy/`) in a temporary home folder, into
/// stores in the same folder, a UserDefaults suite of the test's own and keychains in memory. Nothing real is read: not
/// the user's `~/.zshrc`, environment, keychain or SwiftBar settings.
@Suite("LegacyImport")
struct LegacyImportTests {
    /// `config/settings` of the fixture, mapped
    static let fixturePreferences = Preferences(
        checkIntervalSeconds: 120, hideSuccessfulAfter: .hours(8), hideFailedAfter: .never, hidesMergedBuilds: false,
        alertStyle: .banner, stageAlerts: false, iconStyle: .color, gitLabMaxAgeSeconds: 30,
        workItems: WorkItemFilters(
            scope: .authored, type: .task, state: .all, sort: .title, limit: 50,
            withLabels: ["workflow::in dev", "team::platform"], withoutLabels: ["type::bug"], labelsMatch: .any))

    /// `config/team.conf` of the fixture, without the URLs' trailing `/`
    static let fixtureTeam = TeamValues(
        jenkinsJobURL: "https://jenkins.example.com/job/Example%20Team/job/group%252Fproject",
        gitLabURL: "https://gitlab.example.com", gitLabProject: "group/subgroup/project",
        committedLabel: "level::Committed", slotLabelPrefix: "slot::", ignoredMergeRequestPrefix: "[cascade]")

    @Test("IMP-01 imports everything from a full old folder")
    func importsEverything() async throws {
        let tool = try OldTool(oldKeychain: [TokenAccount.jenkins.rawValue: "from-the-old-keychain"])
        let checkoutBefore = try String(contentsOf: tool.checkout.appending(path: "config/settings"), encoding: .utf8)

        let report = try #require(await tool.makeImport().runIfNeeded())

        #expect(report.oldFolder == tool.checkout)
        #expect(report.foundBy == .storedCheckout)
        #expect(report.oldToolFound)
        #expect(report.token(.jenkins) == .imported(.oldKeychain))
        #expect(report.token(.gitlab) == .imported(.zshrc))
        #expect(await tool.keychain.values == [
            TokenAccount.jenkins.rawValue: "from-the-old-keychain", TokenAccount.gitlab.rawValue: OldTool.gitLabToken,
        ])
        #expect(report.importedSettings)
        #expect(tool.preferences.load() == Self.fixturePreferences)
        #expect(report.importedTeam)
        #expect(tool.teamStore.projects() == [Project(id: .main, team: Self.fixtureTeam)])
        #expect(report.watchedJobs == 2)
        #expect(report.hiddenBuilds == 2)
        #expect(tool.userState.load(.main) == UserState(
            watched: [
                WatchedJob(job: "MR-12", label: "!12", added: OldTool.now),
                WatchedJob(job: "feature%252Fsearch", label: "feature/search", added: OldTool.now),
            ],
            hidden: ["MR-7": 41, "MR-12": 3]))
        // The old tool's own files and keychain items are left as they are.
        #expect(await tool.oldKeychain.values == [TokenAccount.jenkins.rawValue: "from-the-old-keychain"])
        #expect(try String(contentsOf: tool.checkout.appending(path: "config/settings"), encoding: .utf8) == checkoutBefore)
        #expect(FileManager.default.fileExists(atPath: tool.caches.appending(path: "watched").path))
    }

    @Test("IMP-01 maps the old settings")
    func mapsTheSettings() throws {
        let fixture = LegacyKeyValues(text: try FixtureFiles.string("Legacy/checkout/config/settings"))
        #expect(LegacyFormats.preferences(from: fixture, onto: Preferences()) == Self.fixturePreferences)

        // As the old tool read the file: the last line of a key counts, a line must start with the key, and an empty
        // value is no value.
        let lines = LegacyKeyValues(
            text: "menubar_icons=monochrome\nmenubar_icons=emoji\n  alert=banner\nstage_alerts=\n# hide_merged=off\r\nhide_merged=off\r\n")
        let mapped = LegacyFormats.preferences(from: lines, onto: Preferences())
        #expect(mapped.iconStyle == .color)
        #expect(mapped.alertStyle == .window)
        #expect(mapped.stageAlerts)
        #expect(!mapped.hidesMergedBuilds)
        #expect(LegacyFormats.preferences(from: LegacyKeyValues(text: "hide_successful_after_hours=immediately"), onto: Preferences())
            .hideSuccessfulAfter == .immediately)

        // An invalid value counts as the default (SET-01), and so does a value the new options don't have.
        let defaults = TemporaryDefaults()
        let store = PreferencesStore(defaults: defaults.defaults)
        let invalid = LegacyKeyValues(text: """
            refresh_seconds=45
            refresh_seconds=ten
            hide_successful_after_hours=48
            hide_failed_after_hours=-1
            hide_merged=yes
            alert=popup
            work_items_scope=everyone
            work_items_type=ISSUES
            work_items_sort=MILESTONE_DUE_ASC
            work_items_limit=25
            work_items_labels_match=both
            """)
        store.save(LegacyFormats.preferences(from: invalid, onto: store.load()))
        #expect(store.load() == Preferences())
    }

    @Test("IMP-01 drops gitlab_refresh_seconds")
    func dropsGitLabRefresh() async throws {
        // 15 is one of the maximum ages, so a mapped value would show.
        let tool = try OldTool()
        try tool.folder.write("gitlab_refresh_seconds=15\nhide_merged=off\n", to: "checkout/config/settings")

        let report = try #require(await tool.makeImport().runIfNeeded())

        #expect(report.importedSettings)
        #expect(!tool.preferences.load().hidesMergedBuilds)
        #expect(tool.preferences.load().gitLabMaxAgeSeconds == Preferences().gitLabMaxAgeSeconds)
        #expect(tool.defaults.defaults.object(forKey: PreferencesStore.Key.gitLabMaxAgeSeconds.rawValue) == nil)
    }

    @Test("IMP-01 maps emoji icons to color")
    func mapsEmojiToColor() {
        func iconStyle(_ value: String, onto current: Preferences = Preferences()) -> Preferences.IconStyle {
            LegacyFormats.preferences(from: LegacyKeyValues(text: "menubar_icons=\(value)"), onto: current).iconStyle
        }
        #expect(iconStyle("emoji") == .color)
        #expect(iconStyle("monochrome") == .monochrome)
        #expect(iconStyle("colour") == .monochrome)
        #expect(iconStyle("monochrome", onto: Preferences(iconStyle: .color)) == .monochrome)
    }

    @Test("IMP-01 imports watched and hidden builds")
    func importsWatchedAndHidden() async throws {
        let tool = try OldTool(zshrc: false)
        let earlier = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try tool.userState.save(UserState(watched: [WatchedJob(job: "MR-12", label: "!12", added: earlier)], hidden: ["MR-12": 2]), for: .main)
        // A job before a tab, a blank line, a job twice; a job hidden twice, and lines that aren't job and number.
        try tool.folder.write("MR-12\tfrom an older version\n\nfeature%252Fsearch\nMR-12\n", to: "Library/Caches/jenkins-menubar/watched")
        try tool.folder.write("MR-7\t40\nMR-12\t3\nMR-7\t41\nbroken line\nMR-9\tx\n\t5\n", to: "Library/Caches/jenkins-menubar/hidden")

        let report = try #require(await tool.makeImport().runIfNeeded())

        // What was there is kept: the watched job with its date, and the hidden build of MR-12.
        #expect(tool.userState.load(.main) == UserState(
            watched: [
                WatchedJob(job: "MR-12", label: "!12", added: earlier),
                WatchedJob(job: "feature%252Fsearch", label: "feature/search", added: OldTool.now),
            ],
            hidden: ["MR-12": 2, "MR-7": 41]))
        #expect(report.watchedJobs == 1)
        #expect(report.hiddenBuilds == 1)
    }

    @Test("IMP-01 finds the old folder through the SwiftBar link")
    func findsThroughSwiftBar() async throws {
        let tool = try OldTool()
        let manager = FileManager.default
        let plugins = tool.folder.url.appending(path: "SwiftBar Plugins", directoryHint: .isDirectory)
        try manager.createDirectory(at: plugins, withIntermediateDirectories: true)
        try manager.createSymbolicLink(
            at: plugins.appending(path: LegacyImport.pluginName), withDestinationURL: tool.checkout.appending(path: "plugins/jenkins.30s.sh"))
        // The app was built from a fresh clone, which has no old config.
        let freshClone = tool.folder.url.appending(path: "fresh-clone", directoryHint: .isDirectory)
        try tool.folder.write("#!/bin/bash", to: "fresh-clone/plugins/jenkins.30s.sh")
        let swiftBar = TemporaryDefaults()
        swiftBar.defaults.set(plugins.path(percentEncoded: false), forKey: "PluginDirectory")

        let locations = LegacyImport.Locations.standard(storedCheckout: freshClone, home: tool.folder.url, swiftBarDefaults: swiftBar.defaults)
        let found = try #require(tool.makeImport(locations).locateOldFolder())

        #expect(found.source == .swiftBarPlugin)
        #expect(samePlace(found.folder, tool.checkout))
        #expect(locations.watchLink == tool.folder.url.appending(path: "bin/jenkins-watch"))
        #expect(locations.caches == tool.caches)

        // SwiftBar's plugin folder can be the old folder's own plugins/: the old install.sh sets it up so when SwiftBar
        // has none yet.
        swiftBar.defaults.set(tool.checkout.appending(path: "plugins").path(percentEncoded: false), forKey: "PluginDirectory")
        let own = LegacyImport.Locations.standard(storedCheckout: nil, home: tool.folder.url, swiftBarDefaults: swiftBar.defaults)
        let ownFound = try #require(tool.makeImport(own).locateOldFolder())
        #expect(ownFound.source == .swiftBarPlugin)
        #expect(samePlace(ownFound.folder, tool.checkout))

        // The stored checkout comes first when it is the old folder.
        var stored = locations
        stored.storedCheckout = tool.checkout
        #expect(tool.makeImport(stored).locateOldFolder()?.source == .storedCheckout)

        let report = try #require(await tool.makeImport(locations).runIfNeeded())
        #expect(report.foundBy == .swiftBarPlugin)
        #expect(report.importedSettings)
        #expect(report.importedTeam)
    }

    @Test("IMP-01 finds the old folder through the jenkins-watch link")
    func findsThroughWatchLink() throws {
        let tool = try OldTool()
        let manager = FileManager.default
        let link = tool.folder.url.appending(path: "bin/jenkins-watch")
        try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: tool.checkout.appending(path: "bin/jenkins-watch"))
        let emptyPlugins = tool.folder.url.appending(path: "SwiftBar Plugins", directoryHint: .isDirectory)
        try manager.createDirectory(at: emptyPlugins, withIntermediateDirectories: true)
        let locations = LegacyImport.Locations(storedCheckout: nil, swiftBarPluginFolder: emptyPlugins, watchLink: link, caches: tool.caches)

        let found = try #require(tool.makeImport(locations).locateOldFolder())

        #expect(found.source == .watchLink)
        #expect(samePlace(found.folder, tool.checkout))
        // A copy instead of a link leads nowhere: the welcome flow asks.
        try manager.removeItem(at: link)
        try tool.folder.write("#!/bin/bash", to: "bin/jenkins-watch")
        #expect(tool.makeImport(locations).locateOldFolder() == nil)
    }

    @Test("IMP-01 imports what exists when items are missing")
    func importsWhatExists() async throws {
        // No config/settings, no caches, no token anywhere.
        let tool = try OldTool(caches: false, zshrc: false)
        try FileManager.default.removeItem(at: tool.checkout.appending(path: "config/settings"))

        let report = try #require(await tool.makeImport().runIfNeeded())

        #expect(report.importedTeam)
        #expect(tool.teamStore.primaryProject().team == Self.fixtureTeam)
        #expect(!report.importedSettings)
        #expect(tool.preferences.load() == Preferences())
        #expect(report.token(.jenkins) == .notFound(.missing))
        #expect(report.token(.gitlab) == .notFound(.missing))
        #expect(await tool.keychain.values.isEmpty)
        #expect(report.watchedJobs == 0)
        #expect(tool.userState.load(.main) == UserState())
        #expect(report.notMoved.contains(.settings))
        #expect(report.summary == "Imported from jenkins-menubar: the team values")

        // Team values entered before the import are kept, and an empty team.conf imports nothing.
        let entered = try OldTool(caches: false, zshrc: false)
        let mine = TeamValues(jenkinsJobURL: "https://jenkins.example.org/job/mine")
        try entered.teamStore.save(Project(id: .main, team: mine))
        let enteredReport = try #require(await entered.makeImport().runIfNeeded())
        #expect(!enteredReport.importedTeam)
        #expect(entered.teamStore.primaryProject().team == mine)

        let empty = try OldTool(caches: false, zshrc: false)
        try empty.folder.write("jenkins_job_url=\ngitlab_url=\n", to: "checkout/config/team.conf")
        let emptyReport = try #require(await empty.makeImport().runIfNeeded())
        #expect(!emptyReport.importedTeam)
        #expect(emptyReport.notMoved.contains(.teamValues))
        #expect(empty.teamStore.projects().isEmpty)
    }

    @Test("IMP-01 imports from the folder chosen in the welcome flow")
    func importsTheChosenFolder() async throws {
        // Only traces are found: the caches and a token, but no link to the folder.
        let tool = try OldTool()
        let importer = tool.makeImport(tool.locationsWithoutFolder)
        let first = try #require(await importer.runIfNeeded())
        #expect(first.oldFolder == nil)
        #expect(first.notMoved.contains(.oldFolder))
        #expect(!first.importedTeam)

        // A folder without the old config imports nothing more.
        let wrong = await importer.run(chosenFolder: tool.folder.url)
        #expect(wrong.oldFolder == nil)
        #expect(wrong.notMoved.contains(.oldFolder))

        let chosen = await importer.run(chosenFolder: tool.checkout)

        #expect(chosen.foundBy == .chosen)
        #expect(chosen.oldFolder == tool.checkout)
        #expect(chosen.importedSettings)
        #expect(chosen.importedTeam)
        #expect(!chosen.notMoved.contains(.oldFolder))
        #expect(chosen.token(.gitlab) == .kept)
        #expect(chosen.watchedJobs == 0)
        #expect(tool.preferences.load() == Self.fixturePreferences)
        #expect(tool.teamStore.primaryProject().team == Self.fixtureTeam)
        #expect(importer.recordedReport() == chosen)
    }

    @Test("IMP-02 second run changes nothing")
    func secondRunChangesNothing() async throws {
        let tool = try OldTool(oldKeychain: [TokenAccount.jenkins.rawValue: "from-the-old-keychain"])
        let importer = tool.makeImport()
        let first = try #require(await importer.runIfNeeded())
        let preferences = tool.preferences.load()
        let projects = tool.teamStore.projects()
        let tokens = await tool.keychain.values
        let marker = try Data(contentsOf: importer.markerURL)
        // Meanwhile the user stops watching a job, and the old files change.
        var state = tool.userState.load(.main)
        state.watched.removeAll { $0.job == "MR-12" }
        try tool.userState.save(state, for: .main)
        try tool.folder.write("hide_merged=on\nrefresh_seconds=600\n", to: "checkout/config/settings")
        try tool.folder.write("gitlab_url=https://gitlab.example.org\n", to: "checkout/config/team.conf")
        try tool.folder.write("MR-12\nMR-99\n", to: "Library/Caches/jenkins-menubar/watched")
        try await tool.oldKeychain.store("a-newer-token", account: TokenAccount.gitlab.rawValue)

        let again = await tool.makeImport(environment: [TokenAccount.gitlab.rawValue: "from-the-environment"]).runIfNeeded()

        #expect(again == nil)
        #expect(importer.hasRun)
        #expect(tool.preferences.load() == preferences)
        #expect(tool.teamStore.projects() == projects)
        #expect(tool.userState.load(.main) == state)
        #expect(await tool.keychain.values == tokens)
        #expect(try Data(contentsOf: importer.markerURL) == marker)
        #expect(importer.recordedReport() == first)
        #expect(await tool.log.entries().count == 1)

        // A marker that can't be read still counts: the import never runs twice.
        try Data("not json".utf8).write(to: importer.markerURL)
        #expect(await importer.runIfNeeded() == nil)
        #expect(importer.recordedReport() == nil)
        #expect(tool.userState.load(.main) == state)
    }

    @Test("IMP-02 logs a summary without tokens")
    func logsASummary() async throws {
        let tool = try OldTool(oldKeychain: [TokenAccount.jenkins.rawValue: OldTool.jenkinsToken])
        let importer = tool.makeImport()

        let report = try #require(await importer.runIfNeeded())

        let entries = await tool.log.entries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.level == .info)
        #expect(entry.source == .app)
        #expect(entry.time == OldTool.now)
        #expect(entry.message == "Imported from jenkins-menubar: the Jenkins token from keychain (jenkins-menubar), "
            + "the GitLab token from ~/.zshrc, the settings, the team values, 2 watched jobs, 2 hidden builds. The butler carried the boxes.")
        #expect(entry.detail == report.detail)
        #expect(entry.detail == "Folder \(tool.checkout.path(percentEncoded: false)), found as the app's checkout. "
            + "Not moved: notification settings, keychain access, window positions, label memory and caches.")
        // No token in the log files or in the marker, nor in the report's description.
        var texts = try tool.log.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { try String(contentsOf: $0, encoding: .utf8) }
        texts.append(try String(contentsOf: importer.markerURL, encoding: .utf8))
        texts.append(String(describing: report))
        for text in texts {
            for secret in [OldTool.jenkinsToken, OldTool.gitLabToken, "fake-api-token"] {
                #expect(!text.contains(secret), "\(secret)")
            }
        }
    }

    @Test("IMP-03 lists what did not move")
    func listsWhatDidNotMove() async throws {
        // The old folder without config/settings, a token the new keychain refuses, and one ~/.zshrc computes.
        let tool = try OldTool()
        try FileManager.default.removeItem(at: tool.checkout.appending(path: "config/settings"))
        try tool.folder.write("export GITLAB_TOKEN=$(security find-generic-password -s gitlab -w)\n", to: ".zshrc")

        let report = try #require(await tool.makeImport(environment: [TokenAccount.jenkins.rawValue: "has a space"]).runIfNeeded())

        let refused = "That does not look like a token: it has spaces or quotes"
        #expect(report.notMoved == [
            .notificationSettings, .windowPositions, .labelMemoryAndCaches, .settings,
            .token(.jenkins, .notStored(.environment, reason: refused)), .token(.gitlab, .notFound(.zshrcComputed)),
        ])
        #expect(report.notMoved.map(\.message) == [
            "Notification permission and style: macOS keeps them per app, so allow notifications again",
            "Window positions",
            "The remembered labels and the caches: they fill again with the first checks",
            "Settings: the old folder has no config/settings, so the defaults apply",
            "The Jenkins token from environment was not stored: \(refused)",
            "The GitLab token: ~/.zshrc computes it, which the app cannot run: paste it here",
        ])
        // A token that was there but could not be stored is a warning.
        #expect(await tool.log.entries().map(\.level) == [.warning])

        // Only traces of the old tool: its caches and a token in its keychain service. The folder is asked for.
        let traces = try OldTool(checkout: false, zshrc: false, oldKeychain: [TokenAccount.jenkins.rawValue: "from-the-old-keychain"])
        let tracesReport = try #require(await traces.makeImport(traces.locationsWithoutFolder).runIfNeeded())
        #expect(tracesReport.notMoved == [
            .notificationSettings, .keychainAccess, .windowPositions, .labelMemoryAndCaches, .oldFolder,
            .token(.gitlab, .notFound(.missing)),
        ])
        #expect(tracesReport.notMoved[1].message == "Keychain items made outside the security tool: macOS asks once before they can be read")
        #expect(tracesReport.notMoved[4].message == "The jenkins-menubar folder was not found: choose it to import its settings and team values")
        #expect(tracesReport.notMoved[5].message == "The GitLab token: none was found")

        // A fresh account had nothing to move.
        let fresh = try OldTool(checkout: false, caches: false, zshrc: false)
        let freshReport = try #require(await fresh.makeImport(fresh.locationsWithoutFolder).runIfNeeded())
        #expect(!freshReport.oldToolFound)
        #expect(freshReport.notMoved.isEmpty)
        #expect(freshReport.summary == "Nothing to import from jenkins-menubar")
        #expect(fresh.makeImport().hasRun)
    }
}

/// Looking for the old tool's tokens (ACC-02), with the old keychain in memory, a made-up environment and a `~/.zshrc`
/// in a temporary folder. One test stores through `security`, in a keychain made for it.
@Suite("LegacyTokenFinder")
struct LegacyTokenTests {
    private static let jenkins = TokenAccount.jenkins.rawValue
    private static let gitlab = TokenAccount.gitlab.rawValue

    @Test("ACC-02 reads a quoted token with a comment from zshrc")
    func readsAQuotedToken() async throws {
        for line in [
            #"export JENKINS_MCP_BASIC_AUTH="abc+/=._~-"  # the work Jenkins"#,
            "export JENKINS_MCP_BASIC_AUTH='abc+/=._~-' # the work Jenkins",
            "export JENKINS_MCP_BASIC_AUTH=abc+/=._~- # the work Jenkins",
            "\t  export JENKINS_MCP_BASIC_AUTH=abc+/=._~-",
        ] {
            #expect(ZshrcExport.find(Self.jenkins, in: "# my zshrc\n\(line)\nalias ll='ls -l'\n") == .plain("abc+/=._~-"), "\(line)")
        }
        // Another variable, a comment, a line without the space, and an empty value aren't the export.
        for line in [
            "export JENKINS_MCP_BASIC_AUTH_OLD=abc", "# export JENKINS_MCP_BASIC_AUTH=abc", "exportJENKINS_MCP_BASIC_AUTH=abc",
            "export JENKINS_MCP_BASIC_AUTH=", #"export JENKINS_MCP_BASIC_AUTH="""#,
        ] {
            #expect(ZshrcExport.find(Self.jenkins, in: line) == ZshrcExport.none, "\(line)")
        }

        let folder = try TemporaryFolder()
        let zshrc = folder.file(".zshrc")
        try FileManager.default.copyItem(at: FixtureFiles.url("Legacy/zshrc"), to: zshrc)
        let finder = LegacyTokenFinder(oldKeychain: InMemoryKeychain(), environment: [:], zshrc: zshrc)
        #expect(await finder.find(.jenkins) == LegacyToken(source: .zshrc, value: OldTool.jenkinsToken))
        #expect(await finder.find(.gitlab) == LegacyToken(source: .zshrc, value: OldTool.gitLabToken))
    }

    @Test("ACC-02 ignores a computed token in zshrc")
    func ignoresAComputedToken() async throws {
        for line in [
            "export GITLAB_TOKEN=$(security find-generic-password -s gitlab -w)",
            #"export GITLAB_TOKEN="$(cat ~/.gitlab-token)""#,
            "export GITLAB_TOKEN=`cat ~/.gitlab-token`",
            "export GITLAB_TOKEN=$OTHER_TOKEN",
            #"export GITLAB_TOKEN="${OTHER_TOKEN}"  # shared"#,
        ] {
            #expect(ZshrcExport.find(Self.gitlab, in: line) == .computed, "\(line)")
        }
        // Single quotes expand nothing, so the value is taken as written; ACC-03 refuses it when it is stored.
        #expect(ZshrcExport.find(Self.gitlab, in: "export GITLAB_TOKEN='$literal'") == .plain("$literal"))
        // The last export counts, as in zsh.
        #expect(ZshrcExport.find(Self.gitlab, in: "export GITLAB_TOKEN=plain\nexport GITLAB_TOKEN=$(pass gitlab)") == .computed)
        #expect(ZshrcExport.find(Self.gitlab, in: "export GITLAB_TOKEN=$(pass gitlab)\nexport GITLAB_TOKEN=plain") == .plain("plain"))

        let folder = try TemporaryFolder()
        let zshrc = try folder.write("export GITLAB_TOKEN=$(security find-generic-password -s gitlab -w)\n", to: ".zshrc")
        let computed = await LegacyTokenFinder(oldKeychain: InMemoryKeychain(), environment: [:], zshrc: zshrc).find(.gitlab)
        #expect(computed == LegacyToken(source: .zshrcComputed))
        #expect(computed.value == nil)
        // The old keychain still gives the token.
        let oldKeychain = InMemoryKeychain(values: [Self.gitlab: "from-the-old-keychain"])
        #expect(await LegacyTokenFinder(oldKeychain: oldKeychain, environment: [:], zshrc: zshrc).find(.gitlab)
            == LegacyToken(source: .oldKeychain, value: "from-the-old-keychain"))
    }

    @Test("ACC-02 prefers the old keychain over the environment and zshrc")
    func prefersTheOldKeychain() async throws {
        let folder = try TemporaryFolder()
        let zshrc = try folder.write("export JENKINS_MCP_BASIC_AUTH=from-zshrc\n", to: ".zshrc")
        let oldKeychain = InMemoryKeychain(values: [Self.jenkins: "from-the-old-keychain"])
        let environment = [Self.jenkins: "from-the-environment"]

        #expect(await LegacyTokenFinder(oldKeychain: oldKeychain, environment: environment, zshrc: zshrc).find(.jenkins)
            == LegacyToken(source: .oldKeychain, value: "from-the-old-keychain"))
        // A keychain that can't be read counts as not holding it.
        #expect(await LegacyTokenFinder(oldKeychain: UnreadableKeychain(), environment: environment, zshrc: zshrc).find(.jenkins)
            == LegacyToken(source: .environment, value: "from-the-environment"))
        await oldKeychain.delete(account: Self.jenkins)
        #expect(await LegacyTokenFinder(oldKeychain: oldKeychain, environment: environment, zshrc: zshrc).find(.jenkins)
            == LegacyToken(source: .environment, value: "from-the-environment"))
        #expect(await LegacyTokenFinder(oldKeychain: oldKeychain, environment: [Self.jenkins: ""], zshrc: zshrc).find(.jenkins)
            == LegacyToken(source: .zshrc, value: "from-zshrc"))
        #expect(await LegacyTokenFinder(oldKeychain: oldKeychain, environment: [:], zshrc: nil).find(.jenkins)
            == LegacyToken(source: .missing))
    }

    @Test("ACC-02 tells where each token comes from")
    func tellsTheSource() async throws {
        #expect(LegacyToken.Source.allCases.map(\.displayName) == [
            "keychain (jenkins-menubar)", "environment", "~/.zshrc", "computed in ~/.zshrc", "missing",
        ])
        let tool = try OldTool(checkout: false, caches: false, zshrc: false)
        try tool.folder.write("export GITLAB_TOKEN=`pass gitlab`\n", to: ".zshrc")

        let report = try #require(await tool.makeImport(environment: [Self.jenkins: "from-the-environment"]).runIfNeeded())

        #expect(report.token(.jenkins) == .imported(.environment))
        #expect(report.token(.gitlab) == .notFound(.zshrcComputed))
        // A found token shows only where it came from, wherever it is printed.
        let token = LegacyToken(source: .environment, value: "a-secret-value")
        var dumped = ""
        dump(token, to: &dumped)
        for text in [String(describing: token), String(reflecting: token), dumped] {
            #expect(text.contains("environment"))
            #expect(!text.contains("a-secret-value"), "\(text)")
        }
    }

    @Test("ACC-02 stores a found token under the new service")
    func storesUnderTheNewService() async throws {
        try await withTemporaryKeychain { path in
            let old = SecurityCLIKeychain(service: LegacyTokenFinder.oldKeychainService, keychainPath: path)
            let new = SecurityCLIKeychain(service: AppIdentity.keychainService, keychainPath: path)
            try await old.store("from-the-old-keychain", account: Self.gitlab)
            let tool = try OldTool(checkout: false, caches: false, zshrc: false)
            let importer = tool.makeImport(
                tool.locationsWithoutFolder, environment: [Self.jenkins: "  from-the-environment\n"], oldKeychain: old, keychain: new)

            let report = try #require(await importer.runIfNeeded())

            #expect(report.token(.gitlab) == .imported(.oldKeychain))
            #expect(report.token(.jenkins) == .imported(.environment))
            #expect(try await new.find(account: Self.gitlab) == "from-the-old-keychain")
            #expect(try await new.find(account: Self.jenkins) == "from-the-environment")
            // The old item is kept, for the old tool during the trial.
            #expect(try await old.find(account: Self.gitlab) == "from-the-old-keychain")

            // A token menubar-monitor already has is kept.
            try await new.store("entered-in-settings", account: Self.gitlab)
            let again = await importer.run(chosenFolder: tool.folder.url)
            #expect(again.token(.gitlab) == .kept)
            #expect(try await new.find(account: Self.gitlab) == "entered-in-settings")
        }
    }

    /// Runs the body with a keychain file made for it in a temporary folder, and deletes it afterwards. Every call
    /// passes its path, so the login keychain is never touched.
    private func withTemporaryKeychain(_ body: (String) async throws -> Void) async throws {
        let folder = try TemporaryFolder()
        let path = folder.file("import.keychain-db").path
        let security = URL(filePath: "/usr/bin/security")
        let created = try await SystemProcessRunner().run(security, arguments: ["create-keychain", "-p", "test", path], input: nil)
        try #require(created.status == 0, "security create-keychain: \(String(decoding: created.standardError, as: UTF8.self))")
        let result: Result<Void, any Error>
        do {
            try await body(path)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        _ = try? await SystemProcessRunner().run(security, arguments: ["delete-keychain", path], input: nil)
        try result.get()
    }
}

/// A home folder with jenkins-menubar's files, copied from the fixtures, and menubar-monitor's stores, all in one
/// temporary folder.
private struct OldTool {
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// the tokens in the fixture's `zshrc`
    static let jenkinsToken = "amVua2lucy11c2VyOmZha2UtYXBpLXRva2Vu"
    static let gitLabToken = "fake-gitlab-token-0123"

    let folder: TemporaryFolder
    let defaults = TemporaryDefaults()
    /// jenkins-menubar's keychain service
    let oldKeychain: InMemoryKeychain
    /// menubar-monitor's keychain service
    let keychain = InMemoryKeychain()
    let log: ActivityLog

    /// Creates the home folder.
    ///
    /// - Parameters:
    ///   - checkout: whether the old folder is there, at `checkout/`
    ///   - caches: whether `Library/Caches/jenkins-menubar` is there
    ///   - zshrc: whether `.zshrc` is there, with both tokens
    ///   - oldKeychain: the values in the old keychain service, by account
    init(checkout: Bool = true, caches: Bool = true, zshrc: Bool = true, oldKeychain: [String: String] = [:]) throws {
        folder = try TemporaryFolder()
        self.oldKeychain = InMemoryKeychain(values: oldKeychain)
        log = ActivityLog(folder: folder.url.appending(path: "Logs", directoryHint: .isDirectory), now: { Self.now })
        let manager = FileManager.default
        if checkout {
            try manager.copyItem(at: FixtureFiles.url("Legacy/checkout"), to: self.checkout)
        }
        if caches {
            try manager.createDirectory(at: self.caches.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: FixtureFiles.url("Legacy/caches"), to: self.caches)
        }
        if zshrc {
            try manager.copyItem(at: FixtureFiles.url("Legacy/zshrc"), to: self.zshrc)
        }
    }

    var checkout: URL { folder.url.appending(path: "checkout", directoryHint: .isDirectory) }
    var caches: URL { folder.url.appending(path: "Library/Caches/jenkins-menubar", directoryHint: .isDirectory) }
    var zshrc: URL { folder.file(".zshrc") }
    var applicationSupport: URL { folder.url.appending(path: "Application Support", directoryHint: .isDirectory) }
    var preferences: PreferencesStore { PreferencesStore(defaults: defaults.defaults) }
    var teamStore: TeamStore { TeamStore(folder: applicationSupport, report: { _ in }) }
    var userState: UserStateStore { UserStateStore(folder: applicationSupport, report: { _ in }) }

    /// the stored checkout is the old folder, and no link is looked at
    var locations: LegacyImport.Locations {
        LegacyImport.Locations(storedCheckout: checkout, swiftBarPluginFolder: nil, watchLink: nil, caches: caches)
    }

    /// nothing leads to the old folder
    var locationsWithoutFolder: LegacyImport.Locations {
        LegacyImport.Locations(storedCheckout: nil, swiftBarPluginFolder: nil, watchLink: nil, caches: caches)
    }

    func makeImport(
        _ locations: LegacyImport.Locations? = nil,
        environment: [String: String] = [:],
        oldKeychain: (any Keychain)? = nil,
        keychain: (any Keychain)? = nil
    ) -> LegacyImport {
        LegacyImport(
            locations: locations ?? self.locations,
            oldTokens: LegacyTokenFinder(oldKeychain: oldKeychain ?? self.oldKeychain, environment: environment, zshrc: zshrc),
            keychain: keychain ?? self.keychain,
            preferences: preferences,
            teamStore: teamStore,
            userState: userState,
            applicationSupport: applicationSupport,
            log: log,
            now: { Self.now })
    }
}

/// A keychain whose `security` fails, like a locked keychain.
private struct UnreadableKeychain: Keychain {
    func find(account: String) async throws -> String? {
        throw KeychainError.failed(status: 51, message: "User interaction is not allowed.")
    }

    func store(_ value: String, account: String) async throws {}

    func delete(account: String) async throws {}
}

/// Whether two URLs name the same place, after following links: the temporary folder is reached through `/var`, a
/// link to `/private/var`.
private func samePlace(_ url: URL, _ other: URL) -> Bool {
    func path(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
    return path(url) == path(other)
}
