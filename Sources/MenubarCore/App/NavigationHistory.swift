import Foundation

/// A place in the main window that Back and Forward return to (WIN-08): a section with the item selected in it, or an
/// item under "Opened". Items are named by their stable ids, as strings, so the history knows nothing of the stores.
public struct NavigationLocation: Hashable, Sendable {
    /// the sidebar section, or the section behind an "Opened" item
    public var section: AppRoute.Section
    /// the selected row's stable id in the section (a job, a merge request's web address, a work item's reference or a
    /// checkout's path); `nil` for a section without a selection and for Activity and Slots
    public var item: String?
    /// the id of the item shown under "Opened"; it replaces the section's list while set
    public var opened: String?

    /// - Parameters:
    ///   - section: the sidebar section
    ///   - item: the selected row's id; `nil` for none
    ///   - opened: the id of the item shown under "Opened"; `nil` while a section is shown
    public init(section: AppRoute.Section, item: String? = nil, opened: String? = nil) {
        self.section = section
        self.item = item
        self.opened = opened
    }
}

/// The main window's back and forward stacks, as a browser keeps them (WIN-08): every navigation by the user is
/// ``visit(_:)``ed, Back and Forward move between the places, and navigating after going back drops what was ahead.
///
/// The type is a plain value. It knows nothing of the window: the router feeds it the locations and shows what it
/// returns, and the router decides whether a place still exists (``back(isValid:)``).
public struct NavigationHistory: Equatable, Sendable {
    /// how many places Back remembers; the oldest drop out first
    public static let limit = 50

    /// the place the window shows, as far as the history knows
    public private(set) var current: NavigationLocation
    /// the places before the current one, oldest first
    public private(set) var backStack: [NavigationLocation] = []
    /// the places after the current one, the furthest first, so that the nearest is the last
    public private(set) var forwardStack: [NavigationLocation] = []

    /// - Parameter start: where the window starts
    public init(start: NavigationLocation) {
        current = start
    }

    /// whether Back has a place to go to
    public var canGoBack: Bool { !backStack.isEmpty }

    /// whether Forward has a place to go to
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// the places Back reaches, the nearest first, as the Back button's menu lists them
    public var backEntries: [NavigationLocation] { backStack.reversed() }

    /// the places Forward reaches, the nearest first
    public var forwardEntries: [NavigationLocation] { forwardStack.reversed() }

    /// Notes that the user went somewhere. The place being shown already is no navigation, and the places ahead are
    /// dropped, as a browser does after Back and a new link.
    ///
    /// - Parameter location: where the window is now
    /// - Returns: whether it was a new place
    @discardableResult
    public mutating func visit(_ location: NavigationLocation) -> Bool {
        guard location != current else {
            return false
        }
        backStack.append(current)
        if backStack.count > Self.limit {
            backStack.removeFirst(backStack.count - Self.limit)
        }
        current = location
        forwardStack.removeAll()
        return true
    }

    /// Goes back to the nearest place that still exists. Places that don't are dropped.
    ///
    /// - Parameter isValid: whether a place still exists
    /// - Returns: where to go; `nil`, with nothing moved, when no place is left
    public mutating func back(isValid: (NavigationLocation) -> Bool = { _ in true }) -> NavigationLocation? {
        while let candidate = backStack.last {
            backStack.removeLast()
            if isValid(candidate) {
                forwardStack.append(current)
                current = candidate
                return candidate
            }
        }
        return nil
    }

    /// Goes forward to the nearest place that still exists. Places that don't are dropped.
    ///
    /// - Parameter isValid: whether a place still exists
    /// - Returns: where to go; `nil`, with nothing moved, when no place is left
    public mutating func forward(isValid: (NavigationLocation) -> Bool = { _ in true }) -> NavigationLocation? {
        while let candidate = forwardStack.last {
            forwardStack.removeLast()
            if isValid(candidate) {
                backStack.append(current)
                current = candidate
                return candidate
            }
        }
        return nil
    }

    /// Jumps to a place from the Back or Forward menu: the places between come along on the other side, so Back and
    /// Forward keep their order.
    ///
    /// - Parameter location: a place in ``backEntries`` or ``forwardEntries``
    /// - Returns: whether the place was in the history
    @discardableResult
    public mutating func jump(to location: NavigationLocation) -> Bool {
        if let index = backStack.lastIndex(of: location) {
            // The places after it, and the current one, move over, the nearest last.
            let passed = Array(backStack[(index + 1)...])
            backStack.removeSubrange(index...)
            forwardStack.append(current)
            forwardStack.append(contentsOf: passed.reversed())
            current = location
            return true
        }
        if let index = forwardStack.lastIndex(of: location) {
            let passed = Array(forwardStack[(index + 1)...])
            forwardStack.removeSubrange(index...)
            backStack.append(current)
            backStack.append(contentsOf: passed.reversed())
            current = location
            return true
        }
        return false
    }
}
