import CoreGraphics
import Foundation
import Testing

@testable import MenubarCore

@Suite("Hot corners controller")
@MainActor
struct HotCornersControllerTests {
    /// A controller on the fake system, the fake pointer with one 1440 × 900 display, and the test clock.
    @MainActor
    private final class Rig {
        static let middle = CGPoint(x: 720, y: 450)

        let folder: TemporaryFolder
        let system: FakeHotCornerSystem
        let pointer = FakePointerSource()
        let clock = TestClock()
        let log: ActivityLog
        let controller: HotCornersController
        private(set) var appActions: [HotCornerAction] = []

        init(_ settings: HotCornerSettings, system: FakeHotCornerSystem = FakeHotCornerSystem(), start: Bool = true) throws {
            folder = try TemporaryFolder()
            self.system = system
            log = ActivityLog(folder: folder.url)
            controller = HotCornersController(system: system, pointer: pointer, clock: clock, log: log, settings: settings)
            controller.onAppAction = { [unowned self] action in appActions.append(action) }
            if start {
                controller.start()
            }
        }

        var calls: [FakeHotCornerSystem.Call] { system.calls }

        func enter(_ corner: HotCorner, buttonsDown: Bool = false) {
            let point: CGPoint =
                switch corner {
                case .topLeft: CGPoint(x: 0, y: 899)
                case .topRight: CGPoint(x: 1439, y: 899)
                case .bottomLeft: CGPoint(x: 0, y: 0)
                case .bottomRight: CGPoint(x: 1439, y: 0)
                }
            pointer.move(to: point, buttonsDown: buttonsDown)
        }

        func leave() {
            pointer.move(to: Self.middle)
        }

        /// Lets the delay under way pass.
        func pass(_ seconds: Double) async {
            await clock.waitForSleepers()
            clock.advance(by: .seconds(seconds))
            await controller.settled()
        }

        func messages() async -> [String] {
            await controller.settled()
            return await log.entries().map(\.message)
        }
    }

    /// Settings that are on, with one corner set up.
    private static func settings(
        _ corner: HotCorner = .topLeft, delay: Double = 0, plain: HotCornerAction = .system(.missionControl),
        command: HotCornerAction = .none, option: HotCornerAction = .none, control: HotCornerAction = .none,
        shift: HotCornerAction = .none
    ) -> HotCornerSettings {
        var settings = HotCornerSettings(enabled: true)
        settings[corner] = HotCornerSetup(
            delay: delay, plain: plain, command: command, option: option, control: control, shift: shift)
        return settings
    }

    // MARK: HOT-02

    @Test("HOT-02 the action fires once the delay has passed, once per visit; leaving and coming back fires again", arguments: [0.15, 0.3, 0.5, 1, 2])
    func delayAndOncePerVisit(_ delay: Double) async throws {
        let rig = try Rig(Self.settings(delay: delay))
        rig.enter(.topLeft)
        await rig.clock.waitForSleepers()
        rig.clock.advance(by: .seconds(delay / 2))
        #expect(rig.calls.isEmpty)
        rig.clock.advance(by: .seconds(delay / 2))
        await rig.controller.settled()
        #expect(rig.calls == [.perform(.missionControl)])

        // Resting and moving inside the corner fires nothing more.
        rig.pointer.move(to: CGPoint(x: 2, y: 897))
        rig.clock.advance(by: .seconds(5))
        await rig.controller.settled()
        #expect(rig.calls == [.perform(.missionControl)])

        rig.leave()
        rig.enter(.topLeft)
        await rig.pass(delay)
        // A one-time action has no hold to end.
        #expect(rig.calls == [.perform(.missionControl), .perform(.missionControl)])
    }

    @Test("HOT-02 Instant fires on the event itself, and leaving before the delay ends fires nothing")
    func instantAndEarlyLeave() async throws {
        let rig = try Rig(Self.settings(.bottomRight, delay: 0, plain: .system(.displaySleep)))
        rig.enter(.bottomRight)
        #expect(rig.calls == [.perform(.displaySleep)])

        rig.controller.apply(Self.settings(.bottomRight, delay: 1, plain: .system(.displaySleep)))
        rig.leave()
        rig.system.clearCalls()
        rig.enter(.bottomRight)
        await rig.clock.waitForSleepers()
        rig.leave()
        rig.clock.advance(by: .seconds(2))
        await rig.controller.settled()
        #expect(rig.calls.isEmpty)
    }

    // MARK: HOT-03

    @Test("HOT-03 nothing fires while a mouse button is down, and a press starts the visit over")
    func buttonsDown() async throws {
        let rig = try Rig(Self.settings(delay: 0.3))
        // A drag into the corner fires nothing.
        rig.enter(.topLeft, buttonsDown: true)
        #expect(rig.clock.sleeperCount == 0)
        // Released in the corner, a new visit starts.
        rig.enter(.topLeft)
        await rig.pass(0.3)
        #expect(rig.calls == [.perform(.missionControl)])
        // A press in the corner ends the visit; after the release the corner fires again.
        rig.enter(.topLeft, buttonsDown: true)
        rig.enter(.topLeft)
        await rig.pass(0.3)
        #expect(rig.calls == [.perform(.missionControl), .perform(.missionControl)])
        // A press during the delay stops it.
        rig.leave()
        rig.enter(.topLeft)
        await rig.clock.waitForSleepers()
        rig.enter(.topLeft, buttonsDown: true)
        rig.clock.advance(by: .seconds(1))
        await rig.controller.settled()
        #expect(rig.calls.count == 2)
    }

    // MARK: HOT-04

    struct ModifierCase: CustomTestStringConvertible, Sendable {
        let held: Set<HotCornerModifier>
        let expected: HotCornerAction?
        var testDescription: String {
            held.isEmpty ? "no key" : held.map(\.title).sorted().joined(separator: " + ")
        }
    }

    @Test(
        "HOT-04 the key held when the delay ends picks the action: one key its own, two keys nothing, an empty slot nothing",
        arguments: [
            ModifierCase(held: [], expected: .system(.missionControl)),
            ModifierCase(held: [.command], expected: .system(.lockScreen)),
            ModifierCase(held: [.option], expected: nil),
            ModifierCase(held: [.control], expected: .runShortcut(name: "Focus ")),
            ModifierCase(held: [.shift], expected: .showMainWindow),
            ModifierCase(held: [.command, .shift], expected: nil),
            ModifierCase(held: [.command, .option, .control], expected: nil),
        ])
    func modifierChoice(_ test: ModifierCase) async throws {
        let rig = try Rig(Self.settings(
            delay: 0.3, plain: .system(.missionControl), command: .system(.lockScreen), control: .runShortcut(name: "Focus "),
            shift: .showMainWindow))
        rig.enter(.topLeft)
        // The keys are read when the delay ends, not when the pointer arrives.
        rig.pointer.modifiers = test.held
        await rig.pass(0.3)
        switch test.expected {
        case nil:
            #expect(rig.calls.isEmpty && rig.appActions.isEmpty)
        case .system(let action)?:
            #expect(rig.calls == [.perform(action)])
        case .runShortcut(let name)?:
            #expect(rig.calls == [.runShortcut(name)])
        case let action?:
            #expect(rig.appActions == [action])
        }
    }

    // MARK: HOT-05

    enum HoldEnd: String, CaseIterable, Sendable {
        case leaving, pressing, switchingOff, stopping
    }

    @Test("HOT-05 Disable Screen Saver holds from the delay's end until the pointer leaves, a button is pressed or it is switched off", arguments: HoldEnd.allCases)
    func hold(_ end: HoldEnd) async throws {
        let rig = try Rig(Self.settings(.bottomLeft, delay: 0.5, plain: .system(.disableScreenSaver)))
        rig.enter(.bottomLeft)
        await rig.pass(0.5)
        #expect(rig.calls == [.perform(.disableScreenSaver)])
        switch end {
        case .leaving: rig.leave()
        case .pressing: rig.enter(.bottomLeft, buttonsDown: true)
        case .switchingOff:
            var off = rig.controller.settings
            off.enabled = false
            rig.controller.apply(off)
        case .stopping: rig.controller.stop()
        }
        #expect(rig.calls == [.perform(.disableScreenSaver), .endHold])
    }

    // MARK: HOT-06

    struct WatchCase: CustomTestStringConvertible, Sendable {
        let label: String
        let settings: HotCornerSettings
        let started: Bool
        let watched: Bool
        var testDescription: String { label }
    }

    @Test(
        "HOT-06 the pointer is watched only while running, switched on and with an action somewhere",
        arguments: [
            WatchCase(label: "the default", settings: HotCornerSettings(), started: true, watched: false),
            WatchCase(label: "on, no action", settings: HotCornerSettings(enabled: true), started: true, watched: false),
            WatchCase(
                label: "off, with an action",
                settings: HotCornerSettings(enabled: false, topRight: HotCornerSetup(plain: .search)), started: true,
                watched: false),
            WatchCase(
                label: "on, an action with a key only",
                settings: HotCornerSettings(enabled: true, topRight: HotCornerSetup(shift: .search)), started: true,
                watched: true),
            WatchCase(
                label: "on, but not started", settings: HotCornerSettings(enabled: true, topRight: HotCornerSetup(plain: .search)),
                started: false, watched: false),
        ])
    func watching(_ test: WatchCase) throws {
        let rig = try Rig(test.settings, start: test.started)
        #expect(rig.pointer.isStarted == test.watched)
        #expect(rig.controller.isWatching == test.watched)
    }

    @Test("HOT-06 the controller follows the settings live: switched on it watches, switched off it stops")
    func followsSettingsLive() async throws {
        let folder = try TemporaryFolder()
        let defaults = TemporaryDefaults()
        let pointer = FakePointerSource()
        let model = AppModel(dependencies: .fake(root: folder.url, defaults: defaults.defaults, pointerSource: pointer))
        model.hotCorners.start()
        #expect(!pointer.isStarted)

        model.settings.preferences.hotCorners = Self.settings()
        #expect(pointer.isStarted)
        #expect(model.hotCorners.settings == Self.settings())

        model.settings.preferences.hotCorners.enabled = false
        #expect(!pointer.isStarted)
        model.hotCorners.stop()
    }

    // MARK: HOT-07

    @Test(
        "HOT-07 each action goes where it belongs: macOS's to the system, shortcuts and apps by name, MegaMonitor's to the app",
        arguments: [
            HotCornerAction.system(.lockScreen), .system(.apps), .runShortcut(name: "Caffeinate Claude"),
            .openApp(path: "/Applications/Notes.app"), .openSection(.mergeRequests), .showMainWindow, .search,
        ])
    func dispatch(_ action: HotCornerAction) async throws {
        let rig = try Rig(Self.settings(.topRight, plain: action))
        rig.enter(.topRight)
        switch action {
        case .system(let systemAction):
            #expect(rig.calls == [.perform(systemAction)] && rig.appActions.isEmpty)
        case .runShortcut(let name):
            #expect(rig.calls == [.runShortcut(name)] && rig.appActions.isEmpty)
        case .openApp(let path):
            #expect(rig.calls == [.openApp(path)] && rig.appActions.isEmpty)
        default:
            #expect(rig.calls.isEmpty && rig.appActions == [action])
        }
    }

    @Test("HOT-07 every fire writes one Activity line with the corner, the key and the action")
    func logLine() async throws {
        let rig = try Rig(Self.settings(plain: .system(.missionControl), command: .system(.lockScreen)))
        rig.pointer.modifiers = [.command]
        rig.enter(.topLeft)
        rig.leave()
        rig.pointer.modifiers = []
        rig.enter(.topLeft)
        let lines = await rig.messages().filter { $0.hasPrefix("Mega Corner") }
        #expect(lines == ["Mega Corner Top Left (⌘): Lock Screen", "Mega Corner Top Left: Mission Control"])
    }

    // MARK: HOT-11

    @Test("HOT-11 whether the old app runs is fresh on start, on a refresh and after Quit; the shortcut names load")
    func legacyApp() async throws {
        let system = FakeHotCornerSystem(shortcuts: ["Caffeinate Claude", "Focus "], isLegacyAppRunning: true)
        let rig = try Rig(HotCornerSettings(), system: system, start: false)
        #expect(!rig.controller.isLegacyAppRunning)
        rig.controller.start()
        #expect(rig.controller.isLegacyAppRunning)

        system.isLegacyAppRunning = false
        rig.controller.refreshLegacyAppRunning()
        #expect(!rig.controller.isLegacyAppRunning)
        system.isLegacyAppRunning = true
        rig.controller.refreshLegacyAppRunning()
        #expect(rig.controller.isLegacyAppRunning)

        rig.controller.quitLegacyApp()
        #expect(system.calls == [.quitLegacyApp])
        #expect(!rig.controller.isLegacyAppRunning)

        await rig.controller.loadShortcutNames()
        #expect(rig.controller.shortcutNames == ["Caffeinate Claude", "Focus "])
    }

    // MARK: HOT-12

    private static let ripple = HotCornerGlow(color: .custom(hex: "3366FF"), style: .ripple, size: .large)

    @Test("HOT-12 a fired action plays the settings' glow at its corner of the display the pointer is on")
    func glowOnFire() async throws {
        var settings = Self.settings(.bottomRight, delay: 0.3, plain: .search)
        settings.glow = Self.ripple
        let rig = try Rig(settings)
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        rig.pointer.screens.append(second)
        rig.pointer.move(to: CGPoint(x: 3359, y: 0))
        // Not before the delay has passed; the action is the app's own, and the glow still plays.
        #expect(rig.system.glows.isEmpty)
        await rig.pass(0.3)
        #expect(rig.system.glows == [FakeHotCornerSystem.Glow(corner: .bottomRight, screen: second, glow: Self.ripple)])
        // A hold glows once, at its start.
        rig.controller.apply(Self.settings(.topLeft, delay: 0, plain: .system(.disableScreenSaver)))
        rig.system.clearCalls()
        rig.pointer.screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        rig.enter(.topLeft)
        rig.pointer.move(to: CGPoint(x: 2, y: 897))
        #expect(rig.system.glows.count == 1)
    }

    @Test("HOT-12 no glow when it is off, or when nothing fired: an empty slot, two keys held")
    func noGlow() async throws {
        var off = Self.settings(.topLeft, delay: 0)
        off.glow.enabled = false
        let switchedOff = try Rig(off)
        switchedOff.enter(.topLeft)
        #expect(switchedOff.calls == [.perform(.missionControl)])
        #expect(switchedOff.system.glows.isEmpty)

        let emptySlot = try Rig(Self.settings(.topLeft, delay: 0))
        emptySlot.pointer.modifiers = [.command]
        emptySlot.enter(.topLeft)
        #expect(emptySlot.calls.isEmpty)
        #expect(emptySlot.system.glows.isEmpty)

        let twoKeys = try Rig(Self.settings(.topLeft, delay: 0, command: .system(.lockScreen), option: .system(.desktop)))
        twoKeys.pointer.modifiers = [.command, .option]
        twoKeys.enter(.topLeft)
        #expect(twoKeys.calls.isEmpty)
        #expect(twoKeys.system.glows.isEmpty)

        // Try on Screen shows it on the main display whether or not the glow is on.
        switchedOff.controller.showGlowPreview(at: .topRight, glow: off.glow)
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(
            switchedOff.system.glows
                == [FakeHotCornerSystem.Glow(corner: .topRight, screen: main, glow: HotCornerGlow(enabled: true))])
    }
}
