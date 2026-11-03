import AppKit
import MenubarCore
import SwiftUI

/// What the toolbar's Back and Forward buttons show and do (WIN-08), as plain values and closures so the shell stays
/// free of the router. The menus' places are closures, called only when a menu opens: a SwiftUI menu in the toolbar is
/// turned into an AppKit menu, every item with its symbol, each time the toolbar lays its items out, and with a full
/// history that took most of a section switch (the user, 2026-11-02). Two values are equal when the buttons show the
/// same; the closures read the history when called, so they are never out of date.
struct NavigationControls: Equatable {
    /// one place in a menu: its symbol and title
    struct Entry: Identifiable, Equatable {
        /// the place's position in the menu; the same place can be in the history twice
        var id: Int
        var location: NavigationLocation
        var title: String
        var systemImage: String
    }

    /// how many places a menu lists, the nearest ones: all the history keeps
    static let menuLimit = NavigationHistory.limit

    var canGoBack: Bool
    var canGoForward: Bool
    /// the nearest places Back reaches that still exist, ``menuLimit`` at most, the nearest first
    var backEntries: @MainActor () -> [Entry]
    var forwardEntries: @MainActor () -> [Entry]
    var goBack: @MainActor () -> Void
    var goForward: @MainActor () -> Void
    var jump: @MainActor (NavigationLocation) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canGoBack == rhs.canGoBack && lhs.canGoForward == rhs.canGoForward
    }

    /// Returns a menu's entries: the places that still exist, the nearest first, ``menuLimit`` at most, numbered in
    /// that order.
    ///
    /// - Parameters:
    ///   - places: the places, the nearest first
    ///   - limit: how many the menu lists
    ///   - exists: whether a place can be shown again
    ///   - title: a place's title
    ///   - systemImage: a place's symbol
    /// - Returns: the entries
    static func entries(
        _ places: [NavigationLocation], limit: Int = menuLimit, exists: (NavigationLocation) -> Bool,
        title: (NavigationLocation) -> String, systemImage: (NavigationLocation) -> String
    ) -> [Entry] {
        Array(places.lazy.filter(exists).prefix(limit)).enumerated().map { index, place in
            Entry(id: index, location: place, title: title(place), systemImage: systemImage(place))
        }
    }
}

/// The Back ‹ and Forward › buttons at the leading side of the window's toolbar (WIN-08). A click goes one place; a long
/// press or a right-click lists the places, newest first for Back, to jump to.
struct NavigationButtons: ToolbarContent {
    let controls: NavigationControls

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            NavigationButton(direction: .back, controls: controls)
                .equatable()
            NavigationButton(direction: .forward, controls: controls)
                .equatable()
        }
    }
}

/// The Back or the Forward button. It is drawn again only when it turns enabled or disabled; its menu is made when it
/// opens.
private struct NavigationButton: View, @MainActor Equatable {
    enum Direction {
        case back, forward
    }

    let direction: Direction
    let controls: NavigationControls

    private var isEnabled: Bool {
        direction == .back ? controls.canGoBack : controls.canGoForward
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.direction == rhs.direction && lhs.isEnabled == rhs.isEnabled
    }

    var body: some View {
        let controls = controls
        NavigationHistoryButtonView(
            title: direction == .back ? "Back" : "Forward",
            systemImage: direction == .back ? "chevron.left" : "chevron.right",
            help: direction == .back
                ? "Back (⌘[). Press and hold for the places before." : "Forward (⌘]). Press and hold for the places after.",
            isEnabled: isEnabled,
            primary: direction == .back ? controls.goBack : controls.goForward,
            entries: direction == .back ? controls.backEntries : controls.forwardEntries,
            jump: controls.jump)
    }
}

/// The AppKit button behind ``NavigationButton``: a click acts, a press held past the double-click interval or a
/// right-click opens the menu of places, made only then.
private struct NavigationHistoryButtonView: NSViewRepresentable {
    let title: String
    let systemImage: String
    let help: String
    let isEnabled: Bool
    let primary: @MainActor () -> Void
    let entries: @MainActor () -> [NavigationControls.Entry]
    let jump: @MainActor (NavigationLocation) -> Void

    func makeNSView(context: Context) -> NavigationHistoryButton {
        let button = NavigationHistoryButton()
        button.bezelStyle = .toolbar
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        button.setAccessibilityLabel(title)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NavigationHistoryButton, context: Context) {
        button.isEnabled = isEnabled
        button.toolTip = help
        button.primary = primary
        button.entries = entries
        button.jump = jump
    }
}

/// A toolbar button with a menu that is made when it opens (WIN-08).
final class NavigationHistoryButton: NSButton {
    var primary: @MainActor () -> Void = {}
    var entries: @MainActor () -> [NavigationControls.Entry] = { [] }
    var jump: @MainActor (NavigationLocation) -> Void = { _ in }
    /// the entries of the open menu, for the item picked
    private var shown: [NavigationControls.Entry] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(clicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not from a nib")
    }

    /// A click acts; a press held past the double-click interval opens the menu, as Safari's Back does.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else {
            return
        }
        highlight(true)
        let deadline = Date().addingTimeInterval(NSEvent.doubleClickInterval)
        let up = window.nextEvent(matching: .leftMouseUp, until: deadline, inMode: .eventTracking, dequeue: true)
        highlight(false)
        guard let up else {
            showMenu()
            return
        }
        if bounds.contains(convert(up.locationInWindow, from: nil)) {
            primary()
        }
    }

    /// A right-click opens the menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        isEnabled ? makeMenu() : nil
    }

    override func accessibilityPerformShowMenu() -> Bool {
        showMenu()
        return true
    }

    @objc private func clicked() {
        primary()
    }

    private func showMenu() {
        guard let menu = makeMenu() else {
            return
        }
        let below = NSPoint(x: bounds.minX, y: isFlipped ? bounds.maxY + 4 : bounds.minY - 4)
        menu.popUp(positioning: nil, at: below, in: self)
    }

    private func makeMenu() -> NSMenu? {
        shown = entries()
        guard !shown.isEmpty else {
            return nil
        }
        let menu = NSMenu()
        for entry in shown {
            let item = NSMenuItem(title: entry.title, action: #selector(picked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = entry.id
            item.image = Self.symbol(entry.systemImage)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func picked(_ item: NSMenuItem) {
        guard let entry = shown.first(where: { $0.id == item.tag }) else {
            return
        }
        jump(entry.location)
    }

    /// The symbols as images made once.
    private static func symbol(_ name: String) -> NSImage? {
        if let image = symbols[name] {
            return image
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        symbols[name] = image
        return image
    }

    @MainActor private static var symbols: [String: NSImage] = [:]
}
