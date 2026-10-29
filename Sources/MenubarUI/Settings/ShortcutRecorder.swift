import AppKit
import MenubarCore
import SwiftUI

/// Settings' recorder for the global hotkey (APP-08): click it, press the keys, and it shows them in macOS's symbols.
///
/// While it records it takes the keyboard: Esc cancels, ⌫ clears, and a combination without ⌘, ⌃ or ⌥ asks for one
/// and keeps listening. It stops when its window loses the keyboard, so a click elsewhere ends it too. It listens with
/// a local event monitor, which sees only this app's own key events, so it needs no permission.
public struct ShortcutRecorder: View {
    @Binding private var shortcut: HotkeyShortcut?
    @ViewState private var isRecording: Bool
    /// the modifiers held now, shown live while recording
    @ViewState private var held: HotkeyShortcut.Modifiers = []
    /// why the last combination wasn't taken
    @ViewState private var hint: String?
    @ViewState private var capture = ShortcutCapture()

    /// - Parameters:
    ///   - shortcut: the recorded shortcut; nil for none
    ///   - isRecording: whether it looks as if it records, for the gallery; it listens to nothing until it is clicked
    public init(shortcut: Binding<HotkeyShortcut?>, isRecording: Bool = false) {
        _shortcut = shortcut
        _isRecording = ViewState(initialValue: isRecording)
    }

    public var body: some View {
        HStack(spacing: 8) {
            Button {
                isRecording ? stop() : start()
            } label: {
                field
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the window with")
            .accessibilityValue(shortcut?.display ?? "No shortcut")
            .accessibilityHint(isRecording ? "Press the new shortcut, or Escape to cancel" : "Starts recording a shortcut")
            if shortcut != nil, !isRecording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear Shortcut")
                .accessibilityLabel("Clear Shortcut")
            }
        }
        .onDisappear { stop() }
    }

    /// the pill: the shortcut as key caps, a call to record, or what has been typed so far
    @ViewBuilder
    private var field: some View {
        HStack(spacing: 4) {
            if isRecording {
                if let hint {
                    Text(hint)
                        .foregroundStyle(.red)
                } else if held.isEmpty {
                    Text("Type a shortcut")
                        .foregroundStyle(.secondary)
                } else {
                    caps(held.symbols.map(String.init))
                    Text("…").foregroundStyle(.secondary)
                }
            } else if let shortcut {
                caps(shortcut.modifiers.symbols.map(String.init) + [shortcut.label])
            } else {
                Text("Record Shortcut")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .frame(minWidth: 124, minHeight: 28)
        .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isRecording ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var fill: Color {
        isRecording ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.05)
    }

    private func caps(_ keys: [String]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, key.count > 1 ? 6 : 0)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(.background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 0, y: 0.5)
            }
        }
    }

    private func start() {
        isRecording = true
        held = []
        hint = nil
        capture.start(
            modifiersChanged: { modifiers in
                held = modifiers
                if !modifiers.isEmpty {
                    hint = nil
                }
            },
            key: { press in handle(press) },
            ended: { stop() })
    }

    private func stop() {
        capture.stop()
        isRecording = false
        held = []
        hint = nil
    }

    /// Takes a key press while recording.
    ///
    /// - Returns: whether the press was used up; the recorder swallows every one, so ⌘W and the like don't reach the
    ///   window while it listens
    private func handle(_ press: KeyPress) -> Bool {
        let modifiers = press.modifiers
        switch (press.keyCode, modifiers.isEmpty) {
        case (53, true):
            stop()
        case (51, true), (117, true):
            shortcut = nil
            stop()
        default:
            guard let recorded = HotkeyShortcut(
                keyCode: UInt32(press.keyCode), modifiers: modifiers, label: press.characters)
            else {
                // The hint shows until a modifier is pressed again.
                hint = "Add ⌘, ⌃ or ⌥"
                return true
            }
            shortcut = recorded
            stop()
        }
        return true
    }

    static func modifiers(of flags: NSEvent.ModifierFlags) -> HotkeyShortcut.Modifiers {
        var modifiers: HotkeyShortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}

/// A key press, as far as the recorder needs it.
struct KeyPress: Sendable {
    var keyCode: UInt16
    var modifiers: HotkeyShortcut.Modifiers
    var characters: String
}

/// The event monitor behind ``ShortcutRecorder``: it listens for key presses and modifier changes of this app, and
/// ends when the window that was key resigns.
@MainActor
final class ShortcutCapture {
    private var monitor: Any?
    private var resignObserver: (any NSObjectProtocol)?

    func start(
        modifiersChanged: @escaping @MainActor (HotkeyShortcut.Modifiers) -> Void,
        key: @escaping @MainActor (KeyPress) -> Bool,
        ended: @escaping @MainActor () -> Void
    ) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let modifiers = ShortcutRecorder.modifiers(of: event.modifierFlags)
            let press = KeyPress(
                keyCode: event.type == .keyDown ? event.keyCode : 0, modifiers: modifiers,
                characters: event.type == .keyDown ? event.charactersIgnoringModifiers ?? "" : "")
            let isKey = event.type == .keyDown
            // Local monitors run on the main thread, in the middle of event dispatch.
            let swallowed = MainActor.assumeIsolated {
                if isKey {
                    return key(press)
                }
                modifiersChanged(modifiers)
                return false
            }
            return swallowed ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: NSApp.keyWindow, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ended() }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }
}
