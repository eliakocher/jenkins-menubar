import AppKit
import MenubarCore
import SwiftUI

/// What the mouse's side buttons, ⌘← and ⌘→ ask of the main window (WIN-08), decided from plain values so that it is
/// testable without a window or a mouse.
///
/// Buttons 3 and 4 are the back and forward buttons of a mouse like the Logitech MX Master 3S: macOS sends `otherMouseDown`
/// with that `buttonNumber`, and also a `systemDefined` event of subtype 7 whose button mask has bit 3 or bit 4. The first
/// is the one used; the second is only a fallback for a mouse that sends no `otherMouseDown`, and each click acts once,
/// whichever arrives first. ⌘← and ⌘→ move the caret in a text field, so they navigate only while no text is being edited.
struct NavigationInputDecoder {
    /// what an event asks for
    enum Request: Equatable, Hashable {
        case back
        case forward

        /// Returns what a mouse button asks for: 3 is back and 4 forward on a mouse with side buttons.
        static func mouseButton(_ number: Int) -> Request? {
            switch number {
            case 3: .back
            case 4: .forward
            default: nil
            }
        }
    }

    /// an event of ours, with only the values the decision needs
    enum Input: Equatable, Sendable {
        /// an `otherMouseDown`
        case mouseButton(Int, time: TimeInterval)
        /// a `systemDefined` event of subtype 7: the buttons that changed (`data1`) and the state of all (`data2`), as masks
        /// with a bit per button number
        case auxButtons(changed: Int, state: Int, time: TimeInterval)
        /// a `keyDown`
        case key(code: UInt16, modifiers: NSEvent.ModifierFlags, isEditingText: Bool)
    }

    /// how long after a click the same button's other event is the same click: a click's two events come within a few
    /// milliseconds, and nobody clicks a side button twice in this time
    static let sameClick: TimeInterval = 0.1

    private var lastActed: [Request: TimeInterval] = [:]

    /// Returns what an event asks for, or `nil` when it is none of ours or the same click acted already.
    mutating func request(for input: Input) -> Request? {
        switch input {
        case .mouseButton(let number, let time):
            return Request.mouseButton(number).flatMap { act($0, at: time) }
        case .auxButtons(let changed, let state, let time):
            // Press and release both come; only a press acts.
            let pressed = changed & state
            for number in [3, 4] where pressed & (1 << number) != 0 {
                if let request = Request.mouseButton(number).flatMap({ act($0, at: time) }) {
                    return request
                }
            }
            return nil
        case .key(let code, let modifiers, let isEditingText):
            guard !isEditingText, modifiers.intersection(.deviceIndependentFlagsMask) == .command else {
                return nil
            }
            switch code {
            case 123: return .back
            case 124: return .forward
            default: return nil
            }
        }
    }

    private mutating func act(_ request: Request, at time: TimeInterval) -> Request? {
        if let last = lastActed[request], time >= last, time - last < Self.sameClick {
            return nil
        }
        lastActed[request] = time
        return request
    }
}

/// Listens, for the whole app, for the mouse's back and forward buttons and for ⌘← and ⌘→, and takes them to the main
/// window (WIN-08).
///
/// The router owns the one monitor, and it lives as long as the app: a monitor tied to a SwiftUI view depends on SwiftUI
/// keeping that view. The main window tells it which window is its own (``NavigationWindowAnchor``). The mouse's buttons
/// act on a click in that window, key or not, as in a browser; the keys only while it is the key window. The panel,
/// Settings and the sheets keep their events.
///
/// The first version read `keyCode` of every event: that raises on a mouse event, so the handler died before it looked
/// at the button, and the side buttons did nothing (the user, 2026-10-30). Each kind of event is read for its own values only.
@MainActor
final class NavigationInput {
    /// the main window, set by ``NavigationWindowAnchor``; `nil` while it is closed
    weak var window: NSWindow?
    private var decoder = NavigationInputDecoder()
    private var monitor: Any?
    private var goBack: (@MainActor () -> Void)?
    private var goForward: (@MainActor () -> Void)?

    /// Starts listening, once; the actions are the first ones given.
    func start(goBack: @escaping @MainActor () -> Void, goForward: @escaping @MainActor () -> Void) {
        guard monitor == nil else {
            return
        }
        self.goBack = goBack
        self.goForward = goForward
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .systemDefined, .keyDown]) { [weak self] event in
            let windowNumber = event.windowNumber
            guard let input = Self.input(from: event) else {
                return event
            }
            let handled = MainActor.assumeIsolated { self?.handle(input, windowNumber: windowNumber) ?? false }
            return handled ? nil : event
        }
    }

    /// Reads the values of an event that matter, and only the properties its type has: `keyCode` raises for a mouse event
    /// and `buttonNumber` for a key.
    nonisolated static func input(from event: NSEvent, isEditingText: Bool = false) -> NavigationInputDecoder.Input? {
        switch event.type {
        case .otherMouseDown:
            return .mouseButton(event.buttonNumber, time: event.timestamp)
        case .systemDefined where event.subtype.rawValue == 7:
            return .auxButtons(changed: event.data1, state: event.data2, time: event.timestamp)
        case .keyDown:
            return .key(code: event.keyCode, modifiers: event.modifierFlags, isEditingText: isEditingText)
        default:
            return nil
        }
    }

    /// Returns whether it handled the event, which then goes no further.
    func handle(_ input: NavigationInputDecoder.Input, windowNumber: Int) -> Bool {
        guard let window, window.isVisible, windowNumber == window.windowNumber, window.attachedSheet == nil else {
            return false
        }
        var input = input
        if case .key(let code, let modifiers, _) = input {
            guard window.isKeyWindow else {
                return false
            }
            input = .key(
                code: code, modifiers: modifiers, isEditingText: (window.firstResponder as? NSTextView)?.isEditable == true)
        }
        switch decoder.request(for: input) {
        case .back?:
            goBack?()
            return true
        case .forward?:
            goForward?()
            return true
        case nil:
            return false
        }
    }
}

/// Tells the ``NavigationInput`` which window is the main window, whenever the view gets into a window or out of one.
struct NavigationWindowAnchor: NSViewRepresentable {
    let input: NavigationInput

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.input = input
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.input = input
    }

    final class AnchorView: NSView {
        var input: NavigationInput?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Only a window is kept: the reference is weak, and a window that closed is not visible.
            if let window {
                input?.window = window
            }
        }
    }
}
