import Foundation
import Testing

@testable import MenubarCore

@Suite("AppRoute")
struct AppRouteTests {
    @Test(
        "APP-03 routes a link to its pane, section or watch target, and an unknown one to the main window",
        arguments: [
            ("menubar-monitor://settings/general", .settings(.general)),
            ("menubar-monitor://settings/gitlab", .settings(.gitLab)),
            ("menubar-monitor://settings/Team", .settings(.team)),
            // An unknown or missing pane opens General, also the removed Watching pane.
            ("menubar-monitor://settings/watching", .settings(.general)),
            ("menubar-monitor://settings", .settings(.general)),
            ("menubar-monitor://open/merge-requests", .open(.mergeRequests)),
            ("megamonitor://open/digest", .open(.digest)),
            ("menubar-monitor://watch?target=https%3A%2F%2Fjenkins.example.com%2Fjob%2FMR-1%2F",
             .watch(target: "https://jenkins.example.com/job/MR-1/")),
            ("menubar-monitor://watch?target=!12", .watch(target: "!12")),
            // Without a target, the sheet opens and refuses the empty link.
            ("menubar-monitor://watch", .watch(target: "")),
            ("menubar-monitor://", .mainWindow),
            ("menubar-monitor://colors/red", .mainWindow),
            ("menubar-monitor://open/builds", .mainWindow),
            ("menubar-monitor://open", .mainWindow),
            ("MENUBAR-MONITOR://open/activity", .open(.activity)),
            // Another app's link isn't a route at all.
            ("https://example.com/settings/team", nil),
            ("jenkins-menubar://settings/team", nil),
        ] as [(String, AppRoute?)])
    func routes(link: String, expected: AppRoute?) throws {
        #expect(AppRoute(url: try #require(URL(string: link))) == expected)
    }

    @Test("INBOX-07 an item link carries the card to bring into view, and reads back as the same route")
    func itemLinks() throws {
        let page = try #require(URL(string: "https://gitlab.example.com/group/project/-/merge_requests/12"))
        let route = AppRoute.openItem(link: page, card: .claude)
        #expect(AppRoute(url: route.url) == route)
        #expect(route.url.scheme == AppIdentity.urlScheme)
        #expect(route.url.absoluteString.contains("card=claude"))
        // Without a card the link has none, and an unknown or differently cased card is read as far as it can be.
        let plain = AppRoute.openItem(link: page, card: nil)
        #expect(AppRoute(url: plain.url) == plain)
        #expect(!plain.url.absoluteString.contains("card"))
        let encoded = page.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        for (link, expected) in [
            ("megamonitor://item?url=\(encoded)&card=discussion", AppRoute.openItem(link: page, card: .discussion)),
            ("menubar-monitor://item?url=\(encoded)&card=CLAUDE", .openItem(link: page, card: .claude)),
            ("megamonitor://item?card=failed-tests&url=\(encoded)", .openItem(link: page, card: .failedTests)),
            ("megamonitor://item?url=\(encoded)&card=nonsense", .openItem(link: page, card: nil)),
            // Refused, each opens the main window: no link, two links, not a web link.
            ("megamonitor://item?card=claude", .mainWindow),
            ("megamonitor://item?url=\(encoded)&url=\(encoded)&card=claude", .mainWindow),
            ("megamonitor://item?url=file%3A%2F%2F%2Fetc%2Fpasswd&card=claude", .mainWindow),
        ] as [(String, AppRoute)] {
            #expect(AppRoute(url: try #require(URL(string: link))) == expected, "\(link)")
        }
    }

    @Test("APP-03 a route's own link reads back as the same route")
    func roundTrip() {
        for pane in SettingsPane.allCases {
            #expect(AppRoute(url: AppRoute.settings(pane).url) == .settings(pane))
        }
        for section in AppRoute.Section.allCases {
            #expect(AppRoute(url: AppRoute.open(section).url) == .open(section))
        }
        let target = "https://jenkins.example.com/job/project/job/MR-1/"
        #expect(AppRoute(url: AppRoute.watch(target: target).url) == .watch(target: target))
    }

    @Test(
        "TEAM-02 an import link opens only an https team file",
        arguments: [
            ("megamonitor://import?url=https%3A%2F%2Fgitlab.example.com%2Fg%2Fsetup%2F-%2Fblob%2Fmain%2Fteam.json",
             "https://gitlab.example.com/g/setup/-/blob/main/team.json"),
            // The former scheme and any case work the same.
            ("menubar-monitor://import?url=https%3A%2F%2Fexample.com%2Fteam.json", "https://example.com/team.json"),
            ("MegaMonitor://IMPORT?url=HTTPS%3A%2F%2Fexample.com%2Fteam.json", "HTTPS://example.com/team.json"),
            // Other parameters are ignored.
            ("megamonitor://import?x=1&url=https%3A%2F%2Fexample.com%2Fteam.json&apply=true",
             "https://example.com/team.json"),
            // Refused, each opens the main window: not https, no link, an empty one, two links.
            ("megamonitor://import?url=http%3A%2F%2Fexample.com%2Fteam.json", nil),
            ("megamonitor://import?url=file%3A%2F%2F%2Fetc%2Fpasswd", nil),
            ("megamonitor://import?url=javascript%3Aalert(1)", nil),
            ("megamonitor://import?url=%2F%2Fexample.com%2Fteam.json", nil),
            ("megamonitor://import?url=example.com%2Fteam.json", nil),
            ("megamonitor://import", nil),
            ("megamonitor://import?url=", nil),
            ("megamonitor://import?target=https%3A%2F%2Fexample.com%2Fteam.json", nil),
            ("megamonitor://import?url=https%3A%2F%2Fa.example.com%2Fteam.json&url=https%3A%2F%2Fb.example.com%2Fteam.json",
             nil),
        ] as [(String, String?)])
    func importLinks(link: String, file: String?) throws {
        let expected = file.map { AppRoute.importTeamFile(link: URL(string: $0)!) } ?? .mainWindow
        #expect(AppRoute(url: try #require(URL(string: link))) == expected)
        let route = AppRoute.importTeamFile(link: URL(string: "https://example.com/team.json")!)
        #expect(AppRoute(url: route.url) == route)
        #expect(route.url.scheme == AppIdentity.urlScheme)
    }

    @Test("TEAM-02 an import link only requests the preview, it fetches and applies nothing", arguments: [
        "megamonitor", "menubar-monitor",
    ])
    @MainActor
    func importLinkOnlyRequests(scheme: String) async throws {
        let folder = try TemporaryFolder()
        let suite = TemporaryDefaults()
        let stub = StubTransport()
        let log = ActivityLog(folder: folder.file("Logs"))
        let teamStore = TeamStore(folder: folder.url, report: { _ in })
        let team = TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/job/team", gitLabURL: "https://gitlab.example.com",
            gitLabProject: "team/product")
        try teamStore.save(Project(id: .main, team: team))
        let store = SettingsStore(
            preferences: PreferencesStore(defaults: suite.defaults), team: teamStore,
            tokens: TokenStore(keychain: InMemoryKeychain(values: [:]), log: log),
            launchAtLogin: LaunchAtLogin(item: FakeLoginItem(), log: log), log: log,
            transport: { _ in stub }, clock: TestClock(), checkNow: {}, setCheckInterval: { _ in })

        let link = "https://gitlab.example.com/g/setup/-/blob/main/team.json"
        let url = try #require(URL(string: "\(scheme)://import?url=\(link)"))
        let route = try #require(AppRoute(url: url))
        #expect(route.requestTeamFileImport(on: store))

        #expect(store.pendingTeamFileLink == URL(string: link))
        #expect(store.selectedPane == .team)
        #expect(stub.requests.isEmpty)
        #expect(store.team == team)
        #expect(teamStore.primaryProject().team == team)
        // Any other route leaves the store alone.
        store.teamFileImportRequested()
        #expect(!AppRoute.mainWindow.requestTeamFileImport(on: store))
        #expect(store.pendingTeamFileLink == nil)
    }
}
