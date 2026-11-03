import CoreGraphics
import Foundation

/// Where the screen corners are (HOT-01). Only a real corner counts: one where the pointer stops. A corner the pointer
/// can pass on to another display, across the side or across the top or bottom edge, is not one.
public enum HotCornerGeometry {
    /// how far from the corner, in points, the pointer still counts as in it; the old Hot Corners app's value
    public static let tolerance: CGFloat = 3
    /// how far beyond a corner, in points, another display is looked for
    static let reach: CGFloat = 2

    /// Returns the corner the pointer is in.
    ///
    /// - Parameters:
    ///   - point: the pointer, in global coordinates with the origin at the bottom left (`NSEvent.mouseLocation`)
    ///   - screens: the displays' frames, in the same space
    ///   - tolerance: how far from the corner still counts
    /// - Returns: the corner, or nil when the pointer is in none, or only in one that leads on to another display
    public static func corner(at point: CGPoint, screens: [CGRect], tolerance: CGFloat = tolerance) -> HotCorner? {
        // The display that holds the point first; then the ones it touches by a point, as the pointer can sit on the
        // last row (`maxY`) of the bottom-left space.
        let holding = screens.filter { $0.contains(point) }
        let touching = screens.filter { !$0.contains(point) && $0.insetBy(dx: -1, dy: -1).contains(point) }
        for frame in holding + touching {
            let left = point.x <= frame.minX + tolerance
            let right = point.x >= frame.maxX - 1 - tolerance
            let bottom = point.y <= frame.minY + tolerance
            let top = point.y >= frame.maxY - 1 - tolerance
            let corner: HotCorner? =
                switch (left, right, top, bottom) {
                case (true, _, true, _): .topLeft
                case (_, true, true, _): .topRight
                case (true, _, _, true): .bottomLeft
                case (_, true, _, true): .bottomRight
                default: nil
                }
            if let corner, isReal(corner, of: frame, screens: screens) {
                return corner
            }
        }
        return nil
    }

    /// Returns whether a display's corner is a real one: no other display lies just beyond it, sideways or up or down.
    ///
    /// - Parameters:
    ///   - corner: the corner
    ///   - frame: the display's frame
    ///   - screens: every display's frame
    /// - Returns: `true` when the pointer stops there
    public static func isReal(_ corner: HotCorner, of frame: CGRect, screens: [CGRect]) -> Bool {
        let isLeft = corner == .topLeft || corner == .bottomLeft
        let isTop = corner == .topLeft || corner == .topRight
        // The corner's own point, inside the display.
        let x = isLeft ? frame.minX : frame.maxX - 1
        let y = isTop ? frame.maxY - 1 : frame.minY
        let sideways = CGPoint(x: isLeft ? x - reach : x + reach, y: y)
        let upOrDown = CGPoint(x: x, y: isTop ? y + reach : y - reach)
        return !screens.contains { other in
            other != frame && (other.contains(sideways) || other.contains(upOrDown))
        }
    }
}
