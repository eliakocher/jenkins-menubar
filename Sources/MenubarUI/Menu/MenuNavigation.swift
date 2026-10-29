import CoreGraphics
import Foundation
import MenubarCore

/// Where the pane's highlight is and which flyout is open, and how the keys move them, as in a native menu: ↑ and ↓
/// move the highlight (wrapping), → or Return on an area opens its flyout and moves the highlight into it, ← or Esc
/// goes back to the pane, Return activates the highlighted row, Esc on the pane closes it. The pointer sets the same
/// state, so keys and pointer take over from each other. Pure, so the tests check the moves.
struct MenuNavigation: Hashable, Sendable {
    /// A row of the pane the highlight can rest on.
    enum PaneRow: Hashable, Sendable {
        /// the problem row, when a setting fixes it
        case problem
        case area(MainWindowSection)
        case checkNow
        case openWindow
        case settings
        case quit
    }

    /// Where the keys go.
    enum Focus: Hashable, Sendable {
        case pane
        case flyout
    }

    /// A key the pane handles.
    enum Key: Hashable, Sendable {
        case up
        case down
        case left
        case right
        case enter
        case escape
    }

    /// What a key asks the pane to do, beyond moving the highlight.
    enum Command: Hashable, Sendable {
        /// the key changed nothing, or only the highlight
        case none
        /// performs a pane row's action, like Return on Check Now
        case activate(PaneRow)
        /// performs the flyout's row at an index, like Return on a build
        case activateFlyout(Int)
        /// closes the pane, Esc while the keys are on the pane
        case closePane
        /// the key isn't the pane's: the system handles it
        case ignored
    }

    /// the pane's rows in order; the highlight moves over these
    var paneRows: [PaneRow] = []
    /// the highlighted pane row; `nil` for none
    var highlight: PaneRow?
    /// the area whose flyout is open; `nil` for none
    var openArea: MainWindowSection?
    var focus = Focus.pane
    /// how many rows the open flyout has for the keys
    var flyoutCount = 0
    /// the highlighted flyout row, by index; `nil` for none
    var flyoutHighlight: Int?

    /// Returns the pane's rows in order: the problem row when a setting fixes it, the areas, then the footer.
    static func paneRows(problemIsLinked: Bool, areas: [MainWindowSection]) -> [PaneRow] {
        (problemIsLinked ? [.problem] : []) + areas.map(PaneRow.area)
            + [.checkNow, .openWindow, .settings, .quit]
    }

    /// whether a pane row shows as highlighted: the highlighted one; while the keys are in the flyout, or nothing
    /// else is highlighted, the area whose flyout is open, as a native menu keeps a submenu's item highlighted
    func isHighlighted(_ row: PaneRow) -> Bool {
        let openRow = openArea.map(PaneRow.area)
        if focus == .flyout {
            return row == openRow
        }
        return (highlight ?? openRow) == row
    }

    /// Handles a key.
    ///
    /// - Parameter key: the key
    /// - Returns: what the pane does beyond the highlight
    mutating func handle(_ key: Key) -> Command {
        switch focus {
        case .pane: handleOnPane(key)
        case .flyout: handleInFlyout(key)
        }
    }

    private mutating func handleOnPane(_ key: Key) -> Command {
        switch key {
        case .down, .up:
            guard !paneRows.isEmpty else {
                return .none
            }
            let step = key == .down ? 1 : -1
            if let highlight, let index = paneRows.firstIndex(of: highlight) {
                self.highlight = paneRows[(index + step + paneRows.count) % paneRows.count]
            } else {
                self.highlight = key == .down ? paneRows.first : paneRows.last
            }
            // A native menu closes a submenu when the highlight moves off its item.
            if case .area(let section) = self.highlight, section == openArea {
                return .none
            }
            openArea = nil
            flyoutHighlight = nil
            return .none
        case .right, .enter:
            guard let highlight else {
                return .none
            }
            if case .area(let section) = highlight {
                openArea = section
                focus = .flyout
                flyoutHighlight = flyoutCount > 0 ? 0 : nil
                return .none
            }
            return key == .enter ? .activate(highlight) : .none
        case .left:
            return .none
        case .escape:
            return .closePane
        }
    }

    private mutating func handleInFlyout(_ key: Key) -> Command {
        switch key {
        case .down, .up:
            guard flyoutCount > 0 else {
                return .none
            }
            let step = key == .down ? 1 : -1
            if let flyoutHighlight {
                self.flyoutHighlight = (flyoutHighlight + step + flyoutCount) % flyoutCount
            } else {
                flyoutHighlight = key == .down ? 0 : flyoutCount - 1
            }
            return .none
        case .left, .escape:
            backToPane()
            return .none
        case .enter:
            return flyoutHighlight.map(Command.activateFlyout) ?? .none
        case .right:
            return .none
        }
    }

    /// Closes the flyout and puts the keys back on the pane, the highlight on its area.
    mutating func backToPane() {
        if let openArea {
            highlight = .area(openArea)
        }
        openArea = nil
        focus = .pane
        flyoutHighlight = nil
    }

    /// Opens an area's flyout from the pointer: the keys stay on the pane until they move into it.
    mutating func open(_ area: MainWindowSection) {
        if openArea != area {
            flyoutHighlight = nil
            focus = .pane
        }
        openArea = area
        highlight = .area(area)
    }

    /// Closes the flyout, as when the pointer settles on another row or leaves both windows.
    mutating func closeFlyout() {
        openArea = nil
        focus = .pane
        flyoutHighlight = nil
    }

    /// Notes the row under the pointer in the flyout, which takes the keys as in a native submenu.
    mutating func hoverFlyout(_ index: Int?) {
        flyoutHighlight = index
        if index != nil {
            focus = .flyout
        }
    }
}

/// When the flyout opens, switches and closes while the pointer moves, as a native submenu does: it opens after a
/// short rest on an area, switches when another area is hovered, waits while the pointer travels toward it (the aim),
/// and closes when the pointer settles on another row or leaves both windows for a moment. Pure: the pane schedules
/// what it returns.
enum MenuHover {
    /// Where the pointer is.
    enum Target: Hashable, Sendable {
        case area(MainWindowSection)
        /// a pane row that isn't an area: the problem row or the footer
        case otherRow
        case flyout
        /// neither the pane nor the flyout
        case outside
    }

    /// What the pane does about the pointer.
    enum Decision: Hashable, Sendable {
        /// cancels what waits, and changes nothing
        case keep
        /// opens an area's flyout, or switches to it, after a delay
        case open(MainWindowSection, after: Duration)
        /// closes the flyout after a delay
        case close(after: Duration)
    }

    /// the rest on an area before its flyout opens
    static let openDelay = Duration.milliseconds(150)
    /// how long the flyout waits for a pointer on its way to it before it gives way
    static let aimDelay = Duration.milliseconds(350)
    /// how long the pointer may be outside both windows before the flyout closes
    static let leaveDelay = Duration.milliseconds(500)

    /// Returns what the pane does when the pointer moves.
    ///
    /// - Parameters:
    ///   - target: where the pointer is now
    ///   - openArea: the area whose flyout is open
    ///   - isAiming: whether the pointer travels toward the open flyout (``MenuAim/isAiming(from:to:toward:)``)
    static func decide(_ target: Target, openArea: MainWindowSection?, isAiming: Bool) -> Decision {
        switch target {
        case .area(let area):
            if area == openArea {
                return .keep
            }
            if openArea == nil {
                return .open(area, after: openDelay)
            }
            return .open(area, after: isAiming ? aimDelay : openDelay)
        case .otherRow:
            guard openArea != nil else {
                return .keep
            }
            return .close(after: isAiming ? aimDelay : openDelay)
        case .flyout:
            return .keep
        case .outside:
            return openArea == nil ? .keep : .close(after: leaveDelay)
        }
    }
}

/// The aim of native submenus: while the pointer moves from the pane toward the open flyout, it crosses other rows,
/// which must not take the flyout away. It aims when its new position lies in the triangle between its last position
/// and the flyout's near edge.
enum MenuAim {
    /// how far behind its last position the triangle starts, so a pointer moving straight along the edge counts
    static let slack: CGFloat = 4

    /// Returns whether the pointer travels toward the flyout.
    ///
    /// - Parameters:
    ///   - previous: the pointer's last position, in screen coordinates
    ///   - current: its position now
    ///   - flyout: the flyout's frame, in the same coordinates
    /// - Returns: `true` when `current` lies in the triangle from `previous` to the flyout's near edge
    static func isAiming(from previous: CGPoint, to current: CGPoint, toward flyout: CGRect) -> Bool {
        guard previous != current, !flyout.isEmpty else {
            return false
        }
        // The near edge: the flyout's left edge when it lies to the right of the pointer, else its right edge.
        let towardRight = flyout.midX >= previous.x
        let edgeX = towardRight ? flyout.minX : flyout.maxX
        guard towardRight ? current.x > previous.x : current.x < previous.x else {
            return false
        }
        let apex = CGPoint(x: previous.x + (towardRight ? -slack : slack), y: previous.y)
        let top = CGPoint(x: edgeX, y: flyout.maxY)
        let bottom = CGPoint(x: edgeX, y: flyout.minY)
        return contains(current, triangle: (apex, top, bottom))
    }

    private static func contains(_ point: CGPoint, triangle: (CGPoint, CGPoint, CGPoint)) -> Bool {
        func side(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y)
        }
        let d1 = side(point, triangle.0, triangle.1)
        let d2 = side(point, triangle.1, triangle.2)
        let d3 = side(point, triangle.2, triangle.0)
        let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
        let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNegative && hasPositive)
    }
}

/// Where the flyout goes, beside the pane: on the right when it fits there, else on the left, as menu bar extras near
/// the screen's right edge need; its first row at the hovered row's height; inside the screen's visible frame, as
/// tall as its content or the screen allows (it scrolls beyond).
enum MenuFlyoutPlacement {
    /// Which side of the pane the flyout is on.
    enum Side: Hashable, Sendable {
        case left
        case right
    }

    /// the room between the pane and the flyout
    static let gap: CGFloat = 4
    /// the room the flyout keeps from the visible frame's edges
    static let margin: CGFloat = 6

    /// Returns the flyout's frame, in screen coordinates (origin bottom left, as AppKit's).
    ///
    /// - Parameters:
    ///   - row: the hovered area row's frame
    ///   - pane: the pane's frame
    ///   - size: the flyout's size with all its content
    ///   - visible: the screen's visible frame, without the menu bar and the Dock
    ///   - topInset: the room above the flyout's first row, so its first row lines up with the hovered row
    /// - Returns: the frame and the side
    static func frame(row: CGRect, pane: CGRect, size: CGSize, visible: CGRect, topInset: CGFloat = 0)
        -> (frame: CGRect, side: Side)
    {
        let bounds = visible.insetBy(dx: margin, dy: margin)
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        let right = pane.maxX + gap
        let left = pane.minX - gap - width
        let side: Side
        let x: CGFloat
        if right + width <= bounds.maxX {
            (side, x) = (.right, right)
        } else if left >= bounds.minX {
            (side, x) = (.left, left)
        } else {
            // Neither fits: the side with more room, pushed inside the screen.
            let roomRight = bounds.maxX - pane.maxX
            let roomLeft = pane.minX - bounds.minX
            side = roomRight >= roomLeft ? .right : .left
            x = side == .right ? bounds.maxX - width : bounds.minX
        }
        var y = row.maxY + topInset - height
        y = max(bounds.minY, min(y, bounds.maxY - height))
        return (CGRect(x: x, y: y, width: width, height: height), side)
    }
}
