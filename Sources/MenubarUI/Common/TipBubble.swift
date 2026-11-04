import AppKit
import SwiftUI

/// The one tooltip window of a window: a borderless panel with a glass background that is filled, sized, moved and shown
/// again for every tooltip, and hidden at once with the pointer's leaving (no fade). The text is measured and drawn by one
/// and the same call at the same wrapping width, so the bubble always fits all of it, on as many lines as it takes; a
/// small view goes in a hosting view that is made once.
@MainActor
final class TipBubble {
    /// the widest the bubble gets, text included
    static let maxWidth: CGFloat = 280
    private static let padding = NSSize(width: 9, height: 5)
    private static let corner: CGFloat = 8
    static let font = NSFont.systemFont(ofSize: 12)

    private lazy var panel: NSPanel = makePanel()
    private let effect = NSVisualEffectView()
    private let label = TipTextView()
    private var host: NSHostingView<AnyView>?
    private weak var parent: NSWindow?

    /// Fills the bubble, puts it by the pointer and shows it.
    ///
    /// - Parameters:
    ///   - source: what it says
    ///   - pointer: the pointer, in screen coordinates
    ///   - window: the window it belongs to, which it follows as a child
    @discardableResult
    func present(_ source: TipSource, pointer: CGPoint, in window: NSWindow) -> NSRect {
        let content: NSSize
        switch source {
        case .text(let text):
            content = fill(text: text)
        case .view(let make):
            content = fill(view: make())
        }
        let size = NSSize(width: content.width + 2 * Self.padding.width, height: content.height + 2 * Self.padding.height)
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(origin: .zero, size: size)
        let origin = TipPlacement.origin(pointer: pointer, size: size, in: screen)
        panel.appearance = window.effectiveAppearance
        panel.level = window.level
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        effect.frame = NSRect(origin: .zero, size: size)
        let inner = NSRect(origin: NSPoint(x: Self.padding.width, y: Self.padding.height), size: content)
        label.frame = inner
        host?.frame = inner
        if parent !== window {
            parent?.removeChildWindow(panel)
            parent = window
        }
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.alphaValue = 1
        panel.orderFront(nil)
        return panel.frame
    }

    /// the bubble's content, for the tests and renders
    var contentView: NSView { effect }

    func hide() {
        guard panel.isVisible else { return }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    // MARK: Content

    /// Returns the size of a text wrapped at the widest the bubble allows, on as many lines as it takes.
    static func measure(_ text: String) -> NSSize {
        let attributed = TipTextView.attributed(text)
        let box = attributed.boundingRect(
            with: NSSize(width: wrapWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(box.width) + 1, height: ceil(box.height))
    }

    /// the width a text wraps at: the bubble's widest less its padding
    static var wrapWidth: CGFloat { maxWidth - 2 * padding.width }

    private func fill(text: String) -> NSSize {
        host?.isHidden = true
        label.isHidden = false
        label.text = TipTextView.attributed(text)
        return Self.measure(text)
    }

    private func fill(view: AnyView) -> NSSize {
        label.isHidden = true
        let root = AnyView(
            view.font(.system(size: 12)).foregroundStyle(.primary).frame(maxWidth: Self.wrapWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true))
        if let host {
            host.rootView = root
            host.isHidden = false
        } else {
            let created = NSHostingView(rootView: root)
            effect.addSubview(created)
            host = created
        }
        let size = host?.fittingSize ?? .zero
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    // MARK: The panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 24), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle]
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.mask
        effect.addSubview(label)
        panel.contentView = effect
        return panel
    }

    /// A rounded rectangle that stretches, the shape the glass is cut to.
    private static let mask: NSImage = {
        let edge = corner * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: corner, left: corner, bottom: corner, right: corner)
        image.resizingMode = .stretch
        return image
    }()
}

/// The bubble's text. It draws with the very call and wrapping width that ``TipBubble/measure(_:)`` measures with, so
/// the lines break where the size was worked out for.
@MainActor
private final class TipTextView: NSView {
    var text = NSAttributedString() {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func attributed(_ string: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: string, attributes: [.font: TipBubble.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
    }

    override func draw(_ dirtyRect: NSRect) {
        // wider than the view, which clips it: the wrapping is the one that was measured
        text.draw(
            with: NSRect(x: 0, y: 0, width: TipBubble.wrapWidth, height: bounds.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
