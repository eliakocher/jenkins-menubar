import AppKit
import SwiftUI

/// The window of one alert: a non-activating glass panel without window buttons that floats over other apps, every
/// Space and full-screen apps, and becomes key only when it's clicked (`docs/design/alert.md`, panel configuration,
/// and the user's decision Q7).
public final class AlertPanel: NSPanel {
    /// the glass's corners, which are the window's corners too: the clear window draws none of its own
    private static let cornerRadius: CGFloat = 16

    public init(title: String) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
            // `.titled` stays without a title bar to show: a window can become key only with it, so a click makes the
            // alert usable. Not closable, since there is no close button.
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        self.title = title
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        // The glass is the whole background: the window itself draws nothing, but keeps its shadow.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
    }

    /// what Esc does; the window's own close is for ⌘W
    public var onCancel: (() -> Void)?

    /// Shows the alert's view on the panel's glass and sizes the panel to fit it.
    ///
    /// - Parameter view: the hosted `BuildAlertView`
    public func setContent(_ view: NSView) {
        let size = view.fittingSize
        let glass = AlertGlassView(frame: NSRect(origin: .zero, size: size))
        glass.style = .regular
        glass.cornerRadius = Self.cornerRadius
        view.frame = glass.bounds
        view.autoresizingMask = [.width, .height]
        glass.contentView = view
        contentView = glass
        setContentSize(size)
    }

    /// the content size the window takes at the next main turn; `nil` while none is waiting
    private var pendingSize: CGSize?

    /// Gives the panel a new content size, keeping its top left corner where it is: the pages of an alert window differ
    /// in height, and a window that grew from its bottom would jump.
    ///
    /// The size comes from SwiftUI's geometry callback, which runs inside its update pass; a window that is resized in
    /// there lets AppKit lay the hosted view out inside SwiftUI's own layout, and the page ended up offset from the
    /// window (the user, 2026-11-04: after ›, the butler's hat cut off and a band of empty glass below). So the window
    /// changes a main turn later, once, with the newest size.
    ///
    /// - Parameter size: the content's size
    public func fit(to size: CGSize) {
        guard size.width > 0, size.height > 0 else {
            return
        }
        let isWaiting = pendingSize != nil
        pendingSize = size
        guard !isWaiting else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.applyPendingSize() }
        }
    }

    private func applyPendingSize() {
        guard let size = pendingSize else {
            return
        }
        pendingSize = nil
        var target = frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        // AppKit rounds a window's frame to whole points: the glass must fill that, not the fraction.
        target.height = ceil(target.height)
        let new = Self.frame(keepingTopLeftOf: frame, forSize: target)
        if abs(new.height - frame.height) > 0.5 || abs(new.width - frame.width) > 0.5 {
            setFrame(new, display: false, animate: false)
        }
        // Whatever order the resizes came in, the glass and the hosted view fill the window.
        if let glass = contentView {
            glass.frame = NSRect(origin: .zero, size: frame.size)
            glass.needsLayout = true
        }
    }

    /// The frame of a window that takes a new size with its top left corner kept: it grows and shrinks downward.
    ///
    /// - Parameters:
    ///   - frame: the window's frame now
    ///   - size: the frame's new size
    /// - Returns: the new frame
    static func frame(keepingTopLeftOf frame: NSRect, forSize size: NSSize) -> NSRect {
        NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Esc and ⌘. dismiss the shown alert once the panel is key.
    public override func cancelOperation(_ sender: Any?) {
        if let onCancel {
            onCancel()
        } else {
            close()
        }
    }

    /// ⌘W, through the menu's Close or ``performKeyEquivalent(with:)``, dismisses every alert of the window: without a close button,
    /// `NSWindow` would only beep.
    public override func performClose(_ sender: Any?) {
        close()
    }

    /// ⌘W dismisses the alert once it is key, also while another app is active and the app's menu doesn't get the key.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The glass of the alert window: it keeps its content view exactly on its bounds, so that the window, the glass and the
/// hosted page never disagree about size or origin, whichever of AppKit and SwiftUI resized first.
private final class AlertGlassView: NSGlassEffectView {
    override func layout() {
        super.layout()
        if let contentView, contentView.frame != bounds {
            contentView.frame = bounds
        }
    }
}
