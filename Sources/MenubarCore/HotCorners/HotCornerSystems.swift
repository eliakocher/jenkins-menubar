import CoreGraphics
import Foundation

/// A ``HotCornerSystem`` that does nothing: the default of `Dependencies.standard(…)` until the app passes its own, and
/// what a model without the app's effects uses. It works in release builds.
@MainActor
public final class NoHotCornerSystem: HotCornerSystem {
    public nonisolated init() {}

    public func perform(_ action: SystemCornerAction) {}
    public func endHold() {}
    public func runShortcut(named name: String) {}
    public func openApp(at path: String) {}
    public func showGlow(at corner: HotCorner, screen: CGRect, glow: HotCornerGlow) {}
    public func shortcutNames() async -> [String] { [] }
    public var isLegacyAppRunning: Bool { false }
    public func quitLegacyApp() {}
    public func legacyDefaults() -> LegacyHotCornersDefaults? { nil }
}

/// A ``PointerSource`` that never sends anything: the default of `Dependencies.standard(…)` until the app passes its
/// own. It works in release builds.
@MainActor
public final class NoPointerSource: PointerSource {
    public nonisolated init() {}

    public func start(_ onEvent: @escaping @MainActor (PointerEvent) -> Void) {}
    public func stop() {}
    public var screens: [CGRect] { [] }
    public var modifiers: Set<HotCornerModifier> { [] }
}

#if DEBUG
/// A ``HotCornerSystem`` for the tests and the gallery: it only records what it was asked. Debug builds only.
@MainActor
public final class FakeHotCornerSystem: HotCornerSystem {
    /// One call the controller made.
    public enum Call: Hashable, Sendable {
        case perform(SystemCornerAction)
        case endHold
        case runShortcut(String)
        case openApp(String)
        case quitLegacyApp
    }

    /// One glow the controller asked for.
    public struct Glow: Hashable, Sendable {
        public var corner: HotCorner
        public var screen: CGRect
        public var glow: HotCornerGlow

        public init(corner: HotCorner, screen: CGRect, glow: HotCornerGlow) {
            self.corner = corner
            self.screen = screen
            self.glow = glow
        }
    }

    /// the calls, in order
    public private(set) var calls: [Call] = []
    /// the glows asked for, in order; apart from ``calls``, which stay the actions
    public private(set) var glows: [Glow] = []
    /// what ``shortcutNames()`` answers
    public var shortcuts: [String]
    /// whether the old app runs; ``quitLegacyApp()`` sets it to `false`
    public var isLegacyAppRunning: Bool
    /// what ``legacyDefaults()`` answers
    public var legacy: LegacyHotCornersDefaults?

    public nonisolated init(
        shortcuts: [String] = [], isLegacyAppRunning: Bool = false, legacy: LegacyHotCornersDefaults? = nil
    ) {
        self.shortcuts = shortcuts
        self.isLegacyAppRunning = isLegacyAppRunning
        self.legacy = legacy
    }

    public func perform(_ action: SystemCornerAction) { calls.append(.perform(action)) }
    public func endHold() { calls.append(.endHold) }
    public func runShortcut(named name: String) { calls.append(.runShortcut(name)) }
    public func openApp(at path: String) { calls.append(.openApp(path)) }
    public func showGlow(at corner: HotCorner, screen: CGRect, glow: HotCornerGlow) {
        glows.append(Glow(corner: corner, screen: screen, glow: glow))
    }
    public func shortcutNames() async -> [String] { shortcuts }

    public func quitLegacyApp() {
        calls.append(.quitLegacyApp)
        isLegacyAppRunning = false
    }

    public func legacyDefaults() -> LegacyHotCornersDefaults? { legacy }

    /// Forgets the calls so far.
    public func clearCalls() {
        calls = []
        glows = []
    }
}

/// A ``PointerSource`` for the tests and the gallery: the test sends made-up moves and sets the displays and the keys
/// held. Debug builds only.
@MainActor
public final class FakePointerSource: PointerSource {
    /// the displays' frames; one 1440 × 900 display by default
    public var screens: [CGRect]
    /// the modifier keys held
    public var modifiers: Set<HotCornerModifier> = []
    /// whether the controller watches the pointer now
    public private(set) var isStarted = false
    /// how often ``start(_:)`` was called
    public private(set) var startCount = 0
    private var handler: (@MainActor (PointerEvent) -> Void)?

    public nonisolated init(screens: [CGRect] = [CGRect(x: 0, y: 0, width: 1440, height: 900)]) {
        self.screens = screens
    }

    public func start(_ onEvent: @escaping @MainActor (PointerEvent) -> Void) {
        handler = onEvent
        isStarted = true
        startCount += 1
    }

    public func stop() {
        handler = nil
        isStarted = false
    }

    /// Sends a move, or a drag with a button down; nothing while stopped.
    ///
    /// - Parameters:
    ///   - point: the pointer, in global bottom-left coordinates
    ///   - buttonsDown: whether a mouse button is down
    public func move(to point: CGPoint, buttonsDown: Bool = false) {
        handler?(PointerEvent(location: point, buttonsDown: buttonsDown))
    }
}
#endif
