import Foundation
import Testing

@testable import MenubarCore

@Suite("Hot corners import")
@MainActor
struct HotCornerImportTests {
    /// the user's own values of the old app, as its defaults keep them
    private static let realShaped: LegacyHotCornersDefaults = [
        "corner.bottomRight": "shortcut",
        "corner.bottomRight.delay": 0.5,
        "corner.bottomRight.shortcut": "Caffeinate Claude",
        "corner.topLeft": "appWindows",
        "corner.topRight": "missionControl",
        "delay": 0.0,
    ]

    @Test("HOT-08 the old app's settings come over with its fallbacks: a missing corner its default, a missing delay the global one")
    func realShaped() {
        let settings = HotCornerImport.settings(from: Self.realShaped)
        #expect(settings == HotCornerSettings(
            enabled: true,
            topLeft: HotCornerSetup(delay: 0, plain: .system(.applicationWindows)),
            topRight: HotCornerSetup(delay: 0, plain: .system(.missionControl)),
            bottomLeft: HotCornerSetup(delay: 0, plain: .system(.desktop)),
            bottomRight: HotCornerSetup(delay: 0.5, plain: .runShortcut(name: "Caffeinate Claude"))))
    }

    struct FallbackCase: CustomTestStringConvertible, Sendable {
        let label: String
        let legacy: LegacyHotCornersDefaults
        let corner: HotCorner
        let expected: HotCornerSetup
        var testDescription: String { label }
    }

    @Test(
        "HOT-08 the import's fallbacks: no delay is 0.15 s, a delay rounds to the nearest option, an unknown action is the default, a shortcut without a name is none",
        arguments: [
            FallbackCase(
                label: "nothing stored", legacy: ["enabled": false], corner: .bottomRight,
                expected: HotCornerSetup(delay: 0.15, plain: .system(.displaySleep))),
            FallbackCase(
                label: "a delay between options", legacy: ["corner.topLeft.delay": 0.7], corner: .topLeft,
                expected: HotCornerSetup(delay: 0.5, plain: .system(.missionControl))),
            FallbackCase(
                label: "a global delay beyond the options", legacy: ["delay": 5], corner: .topRight,
                expected: HotCornerSetup(delay: 2, plain: .system(.applicationWindows))),
            FallbackCase(
                label: "an unknown action", legacy: ["corner.bottomLeft": "teleport"], corner: .bottomLeft,
                expected: HotCornerSetup(delay: 0.15, plain: .system(.desktop))),
            FallbackCase(
                label: "a shortcut without a name", legacy: ["corner.topLeft": "shortcut"], corner: .topLeft,
                expected: HotCornerSetup(delay: 0.15, plain: .none)),
            FallbackCase(
                label: "none stays none", legacy: ["corner.topRight": "none", "corner.topRight.delay": 1.0], corner: .topRight,
                expected: HotCornerSetup(delay: 1, plain: .none)),
        ])
    func fallbacks(_ test: FallbackCase) {
        #expect(HotCornerImport.settings(from: test.legacy)[test.corner] == test.expected)
    }

    @Test("HOT-08 a missing switch means on, a stored one is kept")
    func enabledFallback() {
        #expect(HotCornerImport.settings(from: ["delay": 0.3]).enabled)
        #expect(!HotCornerImport.settings(from: ["enabled": false]).enabled)
    }

    enum RunCase: String, CaseIterable, Sendable {
        case importsOnce, keepsTheUsersSettings, waitsForTheOldAppsDefaults
    }

    @Test("HOT-08 the import runs once at start, only with the old app's defaults, and never over settings made here", arguments: RunCase.allCases)
    func runsOnce(_ test: RunCase) async throws {
        let folder = try TemporaryFolder()
        let defaults = TemporaryDefaults()
        let system = FakeHotCornerSystem(legacy: test == .waitsForTheOldAppsDefaults ? nil : Self.realShaped)
        let model = AppModel(dependencies: .fake(root: folder.url, defaults: defaults.defaults, hotCornerSystem: system))
        let own = HotCornerSettings(enabled: true, topLeft: HotCornerSetup(plain: .search))
        if test == .keepsTheUsersSettings {
            model.settings.preferences.hotCorners = own
        }
        model.start()
        model.stop()
        let marked = defaults.defaults.bool(forKey: HotCornerImport.markerKey)
        let saved = PreferencesStore(defaults: defaults.defaults).load().hotCorners
        switch test {
        case .importsOnce:
            #expect(marked)
            #expect(saved == HotCornerImport.settings(from: Self.realShaped))
            #expect(model.hotCorners.settings == saved)
            // Changed here and started again, it isn't imported a second time.
            model.settings.preferences.hotCorners = own
            model.importLegacyHotCorners()
            #expect(model.settings.preferences.hotCorners == own)
        case .keepsTheUsersSettings:
            #expect(marked)
            #expect(saved == own)
        case .waitsForTheOldAppsDefaults:
            #expect(!marked)
            #expect(saved == HotCornerSettings())
        }
        await model.settled()
    }
}
