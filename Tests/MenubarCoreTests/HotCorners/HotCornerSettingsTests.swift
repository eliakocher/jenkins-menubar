import Foundation
import Testing

@testable import MenubarCore

@Suite("Hot corners settings")
struct HotCornerSettingsTests {
    /// settings with every kind of action somewhere
    private static let full = HotCornerSettings(
        enabled: true,
        topLeft: HotCornerSetup(
            delay: 0, plain: .system(.missionControl), command: .system(.lockScreen), option: .openSection(.slots),
            control: .runShortcut(name: "Focus  "), shift: .openApp(path: "/Applications/Notes.app")),
        topRight: HotCornerSetup(delay: 0.3, plain: .showMainWindow, shift: .muteAlerts),
        bottomLeft: HotCornerSetup(delay: 1, plain: .search, command: .refreshNow),
        bottomRight: HotCornerSetup(delay: 2, plain: .system(.disableScreenSaver)))

    @Test("HOT-10 the settings are kept in the preferences as one JSON text, absent while they are the defaults, and read back")
    func roundTrip() {
        let suite = TemporaryDefaults()
        let store = PreferencesStore(defaults: suite.defaults)
        var preferences = store.load()
        #expect(preferences.hotCorners == HotCornerSettings())
        preferences.hotCorners = Self.full
        store.save(preferences)
        #expect(suite.defaults.string(forKey: PreferencesStore.hotCornersKey) != nil)
        #expect(store.load().hotCorners == Self.full)

        preferences.hotCorners = HotCornerSettings()
        store.save(preferences)
        #expect(suite.defaults.object(forKey: PreferencesStore.hotCornersKey) == nil)
        #expect(store.load().hotCorners == HotCornerSettings())
        // The personal backup takes them along.
        #expect(PersonalSettingsBackup.allowlist.contains { $0.key == PreferencesStore.hotCornersKey })
    }

    struct DecodingCase: CustomTestStringConvertible, Sendable {
        let label: String
        let text: String
        let expected: HotCornerSettings
        var testDescription: String { label }
    }

    @Test(
        "HOT-10 the stored text decodes leniently: a delay snaps to the nearest option, an unknown action is none, garbage is the default",
        arguments: [
            DecodingCase(label: "garbage", text: "not json", expected: HotCornerSettings()),
            DecodingCase(label: "an array", text: "[1,2]", expected: HotCornerSettings()),
            DecodingCase(
                label: "a delay between options",
                text: #"{"enabled":true,"topLeft":{"delay":0.2,"plain":"system.desktop"}}"#,
                expected: HotCornerSettings(enabled: true, topLeft: HotCornerSetup(delay: 0.15, plain: .system(.desktop)))),
            DecodingCase(
                label: "a delay beyond the options",
                text: #"{"enabled":true,"bottomRight":{"delay":9,"plain":"search"}}"#,
                expected: HotCornerSettings(enabled: true, bottomRight: HotCornerSetup(delay: 2, plain: .search))),
            DecodingCase(
                label: "an action of a later version",
                text: #"{"enabled":true,"topRight":{"delay":0.5,"plain":"system.teleport","command":"section.pipelines"}}"#,
                expected: HotCornerSettings(
                    enabled: true, topRight: HotCornerSetup(delay: 0.5, plain: .none, command: .openSection(.pipelines)))),
            DecodingCase(
                label: "a corner of the wrong type", text: #"{"enabled":true,"topLeft":7}"#,
                expected: HotCornerSettings(enabled: true)),
        ])
    func lenientDecoding(_ test: DecodingCase) {
        let suite = TemporaryDefaults()
        suite.defaults.set(test.text, forKey: PreferencesStore.hotCornersKey)
        #expect(PreferencesStore(defaults: suite.defaults).load().hotCorners == test.expected)
    }

    @Test("HOT-10 every action survives its stored text, and a delay is always one of the options", arguments: [0.0, 0.1, 0.16, 0.4, 0.75, 1.4, 50, -1])
    func storedTextAndDelay(_ delay: Double) {
        let actions: [HotCornerAction] =
            [.none] + SystemCornerAction.allCases.map(HotCornerAction.system) + HotCornerAction.appActions
            + [.runShortcut(name: " Trailing "), .openApp(path: "/Applications/A b.app")]
        for action in actions {
            #expect(HotCornerAction(storedText: action.storedText) == action)
        }
        #expect(HotCornerSettings.delayOptions.contains(HotCornerSettings.nearestDelay(to: delay)))
    }

    struct GlowCase: CustomTestStringConvertible, Sendable {
        let label: String
        let text: String
        let expected: HotCornerGlow
        var testDescription: String { label }
    }

    @Test(
        "HOT-12 the glow is kept with the settings; stored text without it, or with parts it doesn't know, reads as the defaults, and the duration and opacity stay in range",
        arguments: [
            GlowCase(label: "an older text without a glow", text: #"{"enabled":true}"#, expected: HotCornerGlow()),
            GlowCase(
                label: "a custom color", text: ##"{"glow":{"color":"#3366ff","style":"pulse","size":"small"}}"##,
                expected: HotCornerGlow(color: .custom(hex: "3366FF"), style: .pulse, size: .small)),
            GlowCase(
                label: "a preset and the switch off", text: #"{"glow":{"enabled":false,"color":"pink","style":"ripple"}}"#,
                expected: HotCornerGlow(enabled: false, color: .pink, style: .ripple)),
            GlowCase(
                label: "parts of a later version", text: ##"{"glow":{"color":"#12","style":"sparkle","size":"huge"}}"##,
                expected: HotCornerGlow()),
            GlowCase(
                label: "a duration and an opacity", text: #"{"glow":{"duration":1.5,"opacity":0.6}}"#,
                expected: HotCornerGlow(duration: 1.5, opacity: 0.6)),
            GlowCase(
                label: "a duration between the steps snaps, and one beyond the range clamps",
                text: #"{"glow":{"duration":0.74,"opacity":0.55}}"#, expected: HotCornerGlow(duration: 0.7, opacity: 0.55)),
            GlowCase(
                label: "a duration and an opacity beyond the ranges", text: #"{"glow":{"duration":9,"opacity":3}}"#,
                expected: HotCornerGlow(duration: 2.0, opacity: 1)),
            GlowCase(
                label: "too short and too faint", text: #"{"glow":{"duration":0,"opacity":-1}}"#,
                expected: HotCornerGlow(duration: 0.4, opacity: 0.2)),
            GlowCase(
                label: "a duration and an opacity of the wrong type", text: #"{"glow":{"duration":"long","opacity":"half"}}"#,
                expected: HotCornerGlow()),
            GlowCase(label: "a glow of the wrong type", text: #"{"enabled":true,"glow":3}"#, expected: HotCornerGlow()),
        ])
    func glowDecoding(_ test: GlowCase) {
        let suite = TemporaryDefaults()
        suite.defaults.set(test.text, forKey: PreferencesStore.hotCornersKey)
        #expect(PreferencesStore(defaults: suite.defaults).load().hotCorners.glow == test.expected)

        // A glow of its own is stored and read back; the default glow leaves the settings at the defaults.
        var settings = HotCornerSettings(enabled: true)
        settings.glow = test.expected
        #expect(HotCornerSettings(jsonText: settings.jsonText ?? "") == settings)
        #expect(HotCornerSettings(glow: HotCornerGlow()).jsonText == nil)
        #expect(HotCornerGlowColor.custom(hex: "0A1B2C").rgb != nil)
        #expect(HotCornerGlow().duration == 0.9 && HotCornerGlow().opacity == 1)
        // The values stay in range when they are set, not only when they are read.
        var glow = HotCornerGlow()
        glow.duration = 7
        glow.opacity = 0
        #expect(glow.duration == 2.0 && glow.opacity == 0.2)
    }
}
