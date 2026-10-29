import Foundation
import Observation

/// Registers one system-wide shortcut, as Carbon's `RegisterEventHotKey` does in the app (APP-08).
///
/// The app implements it with that call, which needs no Accessibility permission; the tests and the gallery use
/// ``FakeHotkeyRegistrar``, so no test ever registers a hotkey on the real system.
@MainActor
public protocol HotkeyRegistrar: Sendable {
    /// Registers the shortcut in place of the one before; the registrar calls `onPress` on the main actor each time
    /// it is pressed.
    ///
    /// - Throws: a ``HotkeyError`` when macOS refuses it
    func register(_ shortcut: HotkeyShortcut, onPress: @escaping @MainActor () -> Void) throws
    /// Removes the registered shortcut, if there is one.
    func unregister()
}

/// Why macOS refused a shortcut.
public enum HotkeyError: Error, Hashable, Sendable {
    /// another app, or macOS itself, already holds it
    case taken
    /// any other refusal, with the status code
    case refused(Int)
}

/// Where the global hotkey stands, for Settings → General.
public enum HotkeyStatus: Hashable, Sendable {
    /// no shortcut is set
    case off
    /// the shortcut is registered
    case active(HotkeyShortcut)
    /// macOS refused it
    case failed(HotkeyShortcut, HotkeyError)

    /// what Settings shows when the shortcut isn't working, in plain words; nil otherwise
    public var problem: String? {
        guard case .failed(let shortcut, let error) = self else {
            return nil
        }
        switch error {
        case .taken:
            return "\(shortcut.display) is already used by another app or by macOS. Pick another shortcut."
        case .refused(let code):
            return "macOS didn't accept \(shortcut.display) (error \(code)). Pick another shortcut."
        }
    }
}

/// The global hotkey that opens the main window (APP-08): it registers the shortcut of the preferences when the app
/// launches and whenever it changes, and removes it when the app quits.
@Observable @MainActor
public final class GlobalHotkey {
    @ObservationIgnored private let registrar: any HotkeyRegistrar
    @ObservationIgnored private var applied: HotkeyShortcut?
    /// Called when the shortcut is pressed; the app opens the window.
    @ObservationIgnored public var onPress: (@MainActor () -> Void)?
    /// Called once when macOS refuses a shortcut, with the text for the log.
    @ObservationIgnored public var onFailure: (@MainActor (String) -> Void)?

    /// whether the shortcut works, as Settings shows it
    public private(set) var status: HotkeyStatus = .off

    public init(registrar: any HotkeyRegistrar) {
        self.registrar = registrar
    }

    /// Makes the registered shortcut the given one: none removes it. Calling it with the shortcut that works already
    /// does nothing; one macOS refused is tried again, since the other app may have let go of it.
    ///
    /// - Parameter shortcut: the shortcut from the preferences; nil for none
    public func apply(_ shortcut: HotkeyShortcut?) {
        let isNew = shortcut != applied
        if !isNew, case .failed = status {
            // Tried again below, without another log entry.
        } else if !isNew {
            return
        }
        applied = shortcut
        registrar.unregister()
        guard let shortcut else {
            status = .off
            return
        }
        do {
            try registrar.register(shortcut) { [weak self] in self?.onPress?() }
            status = .active(shortcut)
        } catch let error as HotkeyError {
            fail(shortcut, error, isNew: isNew)
        } catch {
            fail(shortcut, .refused(0), isNew: isNew)
        }
    }

    /// Removes the shortcut, as the app quits.
    public func stop() {
        registrar.unregister()
        applied = nil
        status = .off
    }

    private func fail(_ shortcut: HotkeyShortcut, _ error: HotkeyError, isNew: Bool) {
        let next = HotkeyStatus.failed(shortcut, error)
        if status != next {
            status = next
        }
        if isNew, let problem = next.problem {
            onFailure?("Global hotkey: \(problem)")
        }
    }
}

#if DEBUG
/// A registrar that only records what it was asked, for the tests and the gallery. Debug builds only.
@MainActor
public final class FakeHotkeyRegistrar: HotkeyRegistrar {
    /// the shortcuts registered, in order
    public private(set) var registered: [HotkeyShortcut] = []
    /// how often a shortcut was removed
    public private(set) var unregisterCalls = 0
    /// the shortcut registered now
    public private(set) var current: HotkeyShortcut?
    /// when set, `register` throws it, like a shortcut that another app holds
    public var error: HotkeyError?
    private var onPress: (@MainActor () -> Void)?

    public init() {}

    public func register(_ shortcut: HotkeyShortcut, onPress: @escaping @MainActor () -> Void) throws {
        if let error {
            throw error
        }
        registered.append(shortcut)
        current = shortcut
        self.onPress = onPress
    }

    public func unregister() {
        unregisterCalls += 1
        current = nil
        onPress = nil
    }

    /// Acts as if the registered shortcut was pressed.
    public func press() {
        onPress?()
    }
}
#endif
