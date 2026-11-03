import AppKit
import MenubarCore

/// Watches the pointer for Hot Corners with `NSEvent` monitors: a global one for the other apps and a local one for
/// this app's own windows, for moves and the three drags. Monitors for mouse events need no Accessibility permission;
/// there is no event tap and no key monitor (those would need it). The modifier keys are read when asked
/// (`NSEvent.modifierFlags`), not watched.
@MainActor
public final class NSEventPointerSource: PointerSource {
    private static let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    private var globalMonitor: Any?
    private var localMonitor: Any?

    public init() {}

    isolated deinit {
        stop()
    }

    public func start(_ onEvent: @escaping @MainActor (PointerEvent) -> Void) {
        stop()
        let send: @MainActor () -> Void = {
            onEvent(PointerEvent(location: NSEvent.mouseLocation, buttonsDown: NSEvent.pressedMouseButtons != 0))
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { _ in
            MainActor.assumeIsolated { send() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { event in
            MainActor.assumeIsolated { send() }
            return event
        }
    }

    public func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    public var screens: [CGRect] {
        NSScreen.screens.map(\.frame)
    }

    public var modifiers: Set<HotCornerModifier> {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var held: Set<HotCornerModifier> = []
        if flags.contains(.command) { held.insert(.command) }
        if flags.contains(.option) { held.insert(.option) }
        if flags.contains(.control) { held.insert(.control) }
        if flags.contains(.shift) { held.insert(.shift) }
        return held
    }
}
