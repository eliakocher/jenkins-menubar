import Foundation
import Testing

@testable import MenubarCore

@Suite("AppRoute")
struct AppRouteTests {
    private static func route(_ link: String) throws -> AppRoute? {
        AppRoute(url: try #require(URL(string: link)))
    }

    @Test("APP-03 routes a settings link to its pane")
    func settings() throws {
        #expect(try Self.route("menubar-monitor://settings/general") == .settings(.general))
        #expect(try Self.route("menubar-monitor://settings/jenkins") == .settings(.jenkins))
        #expect(try Self.route("menubar-monitor://settings/gitlab") == .settings(.gitLab))
        #expect(try Self.route("menubar-monitor://settings/team") == .settings(.team))
        #expect(try Self.route("menubar-monitor://settings/accounts") == .settings(.accounts))
        #expect(try Self.route("menubar-monitor://settings/Team") == .settings(.team))
        for pane in SettingsPane.allCases {
            #expect(AppRoute(url: AppRoute.settings(pane).url) == .settings(pane))
        }
        // An unknown or missing pane opens General, also the removed Watching pane.
        #expect(try Self.route("menubar-monitor://settings/watching") == .settings(.general))
        #expect(try Self.route("menubar-monitor://settings/colors") == .settings(.general))
        #expect(try Self.route("menubar-monitor://settings") == .settings(.general))
    }

    @Test("APP-03 routes a watch link")
    func watch() throws {
        let target = "https://jenkins.example.com/job/project/job/MR-1/"
        let encoded = try #require(target.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        #expect(try Self.route("menubar-monitor://watch?target=\(encoded)") == .watch(target: target))
        #expect(try Self.route("menubar-monitor://watch?target=!12") == .watch(target: "!12"))
        // Without a target, the sheet opens and refuses the empty link.
        #expect(try Self.route("menubar-monitor://watch") == .watch(target: ""))
        #expect(AppRoute(url: AppRoute.watch(target: target).url) == .watch(target: target))
    }

    @Test("APP-03 routes a section link")
    func section() throws {
        #expect(try Self.route("menubar-monitor://open/pipelines") == .open(.pipelines))
        #expect(try Self.route("menubar-monitor://open/merge-requests") == .open(.mergeRequests))
        #expect(try Self.route("menubar-monitor://open/work-items") == .open(.workItems))
        #expect(try Self.route("menubar-monitor://open/activity") == .open(.activity))
        for section in AppRoute.Section.allCases {
            #expect(AppRoute(url: AppRoute.open(section).url) == .open(section))
        }
    }

    @Test("APP-03 unknown route opens the main window")
    func unknown() throws {
        #expect(try Self.route("menubar-monitor://") == .mainWindow)
        #expect(try Self.route("menubar-monitor://colors/red") == .mainWindow)
        #expect(try Self.route("menubar-monitor://open/builds") == .mainWindow)
        #expect(try Self.route("menubar-monitor://open") == .mainWindow)
        #expect(try Self.route("MENUBAR-MONITOR://open/activity") == .open(.activity))
        // Another app's link isn't a route at all.
        #expect(try Self.route("https://example.com/settings/team") == nil)
        #expect(try Self.route("jenkins-menubar://settings/team") == nil)
    }
}
