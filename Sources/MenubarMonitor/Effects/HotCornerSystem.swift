import AppKit
import Foundation
import IOKit.pwr_mgt
import MenubarCore

/// The macOS side of Hot Corners: performs the actions of ``SystemCornerAction``, runs shortcuts, opens apps and handles
/// the old Hot Corners app. None of it needs the Accessibility permission, nothing goes through a shell, and nothing is
/// ever deleted.
///
/// - Mission Control, Application Windows and Desktop: the Dock's `CoreDockSendNotification` (**private API**, resolved
///   with `dlopen` and `dlsym`, so a macOS without it only loses the action). Without it, Mission Control and
///   Application Windows fall back to `open -a "Mission Control"` (with `--args 2` for the windows); Desktop has no
///   fallback.
/// - Apps: `/System/Applications/Apps.app` through `NSWorkspace`; on a Mac without it, the Dock's
///   `com.apple.launchpad.toggle` (**private API**).
/// - Start Screen Saver: `NSWorkspace` opens `ScreenSaverEngine.app`.
/// - Disable Screen Saver, a hold: an `IOPMAssertion` that prevents the idle display sleep (and with it the screen saver)
///   until ``endHold()``.
/// - Put Display to Sleep: `/usr/bin/pmset displaysleepnow`.
/// - Lock Screen: `SACLockScreenImmediate` of the login framework (**private API**, resolved at runtime); `pmset
///   displaysleepnow` when it is missing, which locks too when the Mac asks for the password at once.
/// - Shortcuts: `/usr/bin/shortcuts run <name>` and `shortcuts list`.
/// - The corner glow (HOT-12): ``HotCornerGlowPanel``.
@MainActor
public final class NativeHotCornerSystem: HotCornerSystem {
    private typealias CoreDockSendNotificationFn = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void
    private typealias LockScreenFn = @convention(c) () -> Int32

    private static let legacyBundleID = "dev.kocher.HotCorners"
    private static let appsPath = "/System/Applications/Apps.app"
    private static let screenSaverPath = "/System/Library/CoreServices/ScreenSaverEngine.app"
    private static let missionControlApp = "Mission Control"

    /// the Dock's private entry point, nil when this macOS lacks it
    private static let coreDockSend: CoreDockSendNotificationFn? = {
        guard
            let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
            let symbol = dlsym(handle, "CoreDockSendNotification")
        else { return nil }
        return unsafeBitCast(symbol, to: CoreDockSendNotificationFn.self)
    }()

    /// the login framework's private lock call, nil when this macOS lacks it
    private static let lockScreenCall: LockScreenFn? = {
        guard
            let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
            let symbol = dlsym(handle, "SACLockScreenImmediate")
        else { return nil }
        return unsafeBitCast(symbol, to: LockScreenFn.self)
    }()

    /// the assertion of a running hold, 0 when none runs
    private var holdAssertion: IOPMAssertionID = 0

    public init() {}

    isolated deinit {
        endHold()
    }

    public func perform(_ action: SystemCornerAction) {
        switch action {
        case .missionControl:
            if !sendDock("com.apple.expose.awake") {
                Self.launch("/usr/bin/open", ["-a", Self.missionControlApp])
            }
        case .applicationWindows:
            if !sendDock("com.apple.expose.front.awake") {
                Self.launch("/usr/bin/open", ["-a", Self.missionControlApp, "--args", "2"])
            }
        case .desktop:
            _ = sendDock("com.apple.showdesktop.awake")
        case .apps:
            if FileManager.default.fileExists(atPath: Self.appsPath) {
                openApp(at: Self.appsPath)
            } else {
                _ = sendDock("com.apple.launchpad.toggle")
            }
        case .startScreenSaver:
            openApp(at: Self.screenSaverPath)
        case .disableScreenSaver:
            beginHold()
        case .displaySleep:
            Self.launch("/usr/bin/pmset", ["displaysleepnow"])
        case .lockScreen:
            if let lock = Self.lockScreenCall {
                _ = lock()
            } else {
                Self.launch("/usr/bin/pmset", ["displaysleepnow"])
            }
        }
    }

    public func endHold() {
        guard holdAssertion != 0 else {
            return
        }
        IOPMAssertionRelease(holdAssertion)
        holdAssertion = 0
    }

    public func runShortcut(named name: String) {
        // The name goes verbatim, trailing spaces too: `shortcuts run` needs them.
        Self.launch("/usr/bin/shortcuts", ["run", name])
    }

    public func openApp(at path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                AppLog.warning("A Mega Corner couldn't open \(path): \(error.localizedDescription)")
            }
        }
    }

    public func showGlow(at corner: HotCorner, screen: CGRect, glow: HotCornerGlow) {
        HotCornerGlowPanel.show(at: corner, screen: screen, glow: glow)
    }

    public func shortcutNames() async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.listShortcuts())
            }
        }
    }

    public var isLegacyAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.legacyBundleID).isEmpty
    }

    public func quitLegacyApp() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.legacyBundleID) {
            app.terminate()
        }
    }

    public func legacyDefaults() -> LegacyHotCornersDefaults? {
        guard let domain = UserDefaults.standard.persistentDomain(forName: Self.legacyBundleID), !domain.isEmpty else {
            return nil
        }
        var values: LegacyHotCornersDefaults = [:]
        for (key, value) in domain {
            if let string = value as? String {
                values[key] = string
            } else if let number = value as? NSNumber {
                values[key] = CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue : number.doubleValue
            }
        }
        return values.isEmpty ? nil : values
    }

    // MARK: - Mechanisms

    /// Sends a notification to the Dock; false when the private call is missing.
    private func sendDock(_ name: String) -> Bool {
        guard let send = Self.coreDockSend else {
            return false
        }
        send(name as CFString, nil)
        return true
    }

    /// Starts the hold: the display stays awake, so the screen saver never starts. A running hold ends first, so none leaks.
    private func beginHold() {
        endHold()
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MegaMonitor Mega Corner" as CFString, &assertion)
        if result == kIOReturnSuccess {
            holdAssertion = assertion
        } else {
            AppLog.warning("A Mega Corner couldn't hold the screen saver off (IOReturn \(result)).")
        }
    }

    /// Starts a program and doesn't wait: absolute path, arguments as they are, no shell.
    private static func launch(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            AppLog.warning("A Mega Corner couldn't start \(path): \(error.localizedDescription)")
        }
    }

    /// Runs `shortcuts list` and reads its lines: blank ones dropped, the names verbatim, sorted without case.
    private nonisolated static func listShortcuts() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        // Read before waiting, or a full pipe would block the tool.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
