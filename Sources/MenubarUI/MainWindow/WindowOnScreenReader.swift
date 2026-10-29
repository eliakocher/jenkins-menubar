import AppKit
import SwiftUI

/// Tells whether some of the window it sits in can be seen: not minimized, not fully covered, on a screen that is on
/// (`NSWindow.occlusionState`). The main window's sidebar badges keep GitLab loading only while it can (OD-02, the shell's
/// unverified 7).
struct WindowOnScreenReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastValue: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                return
            }
            let names = [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.report()
                    }
                }
            }
            // Not during SwiftUI's update, which this call can be part of.
            Task { @MainActor [weak self] in
                self?.report()
            }
        }

        private func report() {
            guard let window else {
                return
            }
            let isOnScreen = window.occlusionState.contains(.visible) && !window.isMiniaturized
            guard isOnScreen != lastValue else {
                return
            }
            lastValue = isOnScreen
            onChange?(isOnScreen)
        }
    }
}
