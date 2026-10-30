import Foundation
import Testing

@testable import MenubarCore

/// A Mac whose default browser is a variable, which can refuse a change.
@MainActor
private final class FakeBrowsers: DefaultBrowserSystem {
    static let safari = BrowserApp(url: URL(filePath: "/Applications/Safari.app"), bundleID: "com.apple.Safari", name: "Safari")
    static let firefox = BrowserApp(url: URL(filePath: "/Applications/Firefox.app"), bundleID: "org.mozilla.firefox", name: "Firefox")
    static let me = BrowserApp(url: URL(filePath: "/Applications/MegaMonitor.app"), bundleID: "local.menubar-monitor", name: "MegaMonitor")

    var thisApp: BrowserApp? { Self.me }
    var current: BrowserApp?
    var installed: [BrowserApp] = [safari, firefox]
    var refuses = false
    private(set) var opened: [(URL, BrowserApp)] = []

    init(current: BrowserApp?) {
        self.current = current
    }

    func defaultBrowser() -> BrowserApp? { current }
    func app(bundleID: String) -> BrowserApp? { installed.first { $0.bundleID == bundleID } }
    func exists(_ app: BrowserApp) -> Bool { installed.contains(app) }

    func setDefaultBrowser(_ app: BrowserApp) async throws {
        if refuses && app == Self.me {
            throw CocoaError(.userCancelled)
        }
        current = app
    }

    func open(_ url: URL, with app: BrowserApp) async {
        opened.append((url, app))
    }
}

@MainActor
@Suite("LinkRouting")
struct LinkRoutingTests {
    private static let project = Project(id: .main, team: TeamValues(
        jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: "https://gitlab.example.com",
        gitLabProject: "group/project"))
    private static let mergeRequest = URL(string: "https://gitlab.example.com/group/project/-/merge_requests/1")!

    private func routing(_ system: FakeBrowsers, defaults: TemporaryDefaults) -> LinkRouting {
        LinkRouting(system: system, defaults: defaults.defaults, projects: { [Self.project] })
    }

    @Test("APP-09 turning on remembers the browser and turning off restores it")
    func onAndOff() async throws {
        let defaults = TemporaryDefaults()
        let system = FakeBrowsers(current: FakeBrowsers.firefox)
        let routing = routing(system, defaults: defaults)
        #expect(!routing.isOn)
        #expect(routing.route(Self.mergeRequest, optionHeld: false) == .browser)

        await routing.setEnabled(true)
        #expect(routing.isOn)
        #expect(system.current == FakeBrowsers.me)
        #expect(routing.remembered == FakeBrowsers.firefox)
        #expect(routing.browserName == "Firefox")
        #expect(routing.route(Self.mergeRequest, optionHeld: false) == .mergeRequest(gitLabProject: "group/project", iid: 1))
        // ⌥ always means the browser.
        #expect(routing.route(Self.mergeRequest, optionHeld: true) == .browser)

        // The choice survives a restart.
        let restarted = self.routing(system, defaults: defaults)
        #expect(restarted.isOn && restarted.remembered == FakeBrowsers.firefox)

        await routing.setEnabled(false)
        #expect(!routing.isOn)
        #expect(system.current == FakeBrowsers.firefox)
        #expect(routing.remembered == nil)
        #expect(routing.route(Self.mergeRequest, optionHeld: false) == .browser)
    }

    @Test("APP-09 a refusal turns the switch back off with a note")
    func refusal() async {
        let defaults = TemporaryDefaults()
        let system = FakeBrowsers(current: FakeBrowsers.firefox)
        system.refuses = true
        let routing = routing(system, defaults: defaults)
        await routing.setEnabled(true)
        #expect(!routing.isOn)
        #expect(system.current == FakeBrowsers.firefox)
        #expect(routing.note?.contains("Firefox") == true)
    }

    @Test("APP-09 falls back to Safari when the remembered browser is the app, gone or missing")
    func fallback() async {
        // Already the default, with nothing remembered.
        let defaults = TemporaryDefaults()
        let system = FakeBrowsers(current: FakeBrowsers.me)
        let routing = routing(system, defaults: defaults)
        await routing.setEnabled(true)
        #expect(routing.forwardTarget == FakeBrowsers.safari)
        await routing.setEnabled(false)
        #expect(system.current == FakeBrowsers.safari)

        // The remembered browser was uninstalled meanwhile.
        let other = TemporaryDefaults()
        let removed = FakeBrowsers(current: FakeBrowsers.firefox)
        let second = self.routing(removed, defaults: other)
        await second.setEnabled(true)
        removed.installed = [FakeBrowsers.safari]
        await second.setEnabled(false)
        #expect(removed.current == FakeBrowsers.safari)
    }

    @Test("APP-09 passes a link on to the remembered browser, never to the app, even with the switch off")
    func forwarding() async {
        let defaults = TemporaryDefaults()
        let system = FakeBrowsers(current: FakeBrowsers.firefox)
        let routing = routing(system, defaults: defaults)
        await routing.setEnabled(true)
        let link = URL(string: "https://example.com/page")!
        #expect(routing.route(link, optionHeld: false) == .browser)
        #expect(await routing.forward(link))
        #expect(system.opened.map(\.1) == [FakeBrowsers.firefox])

        // The user chose another browser in System Settings: the switch shows off, links still go on.
        system.current = FakeBrowsers.safari
        routing.refresh()
        #expect(!routing.isOn)
        #expect(routing.route(Self.mergeRequest, optionHeld: false) == .browser)
        #expect(await routing.forward(link))
        #expect(system.opened.last?.1 != FakeBrowsers.me)
    }
}
