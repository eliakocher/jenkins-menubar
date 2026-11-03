import CoreGraphics
import Foundation
import Testing

@testable import MenubarCore

@Suite("Hot corner geometry")
struct HotCornerGeometryTests {
    struct GeometryCase: CustomTestStringConvertible, Sendable {
        let label: String
        let screens: [CGRect]
        let point: CGPoint
        let expected: HotCorner?

        var testDescription: String { label }
    }

    private static let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// a taller display right of the main one
    private static let tallRight = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    /// a display of the same size right of the main one
    private static let right = CGRect(x: 1440, y: 0, width: 1440, height: 900)
    /// a display of the same size above the main one
    private static let above = CGRect(x: 0, y: 900, width: 1440, height: 900)

    static let cases: [GeometryCase] = [
        // One display: the four corners, within 3 pt; the last row too.
        GeometryCase(label: "one display, top left", screens: [main], point: CGPoint(x: 0, y: 899), expected: .topLeft),
        GeometryCase(label: "one display, top right", screens: [main], point: CGPoint(x: 1439, y: 899), expected: .topRight),
        GeometryCase(label: "one display, bottom left", screens: [main], point: CGPoint(x: 0, y: 0), expected: .bottomLeft),
        GeometryCase(label: "one display, bottom right", screens: [main], point: CGPoint(x: 1439, y: 0), expected: .bottomRight),
        GeometryCase(label: "one display, 3 pt off still counts", screens: [main], point: CGPoint(x: 3, y: 896), expected: .topLeft),
        GeometryCase(label: "one display, 4 pt off is out", screens: [main], point: CGPoint(x: 4, y: 899), expected: nil),
        GeometryCase(label: "one display, the last row counts", screens: [main], point: CGPoint(x: 0, y: 900), expected: .topLeft),
        GeometryCase(label: "one display, an edge is no corner", screens: [main], point: CGPoint(x: 720, y: 899), expected: nil),
        GeometryCase(label: "one display, the middle", screens: [main], point: CGPoint(x: 720, y: 450), expected: nil),
        // Two displays side by side, the right one taller.
        GeometryCase(
            label: "two displays, the main one's top right leads on", screens: [main, tallRight],
            point: CGPoint(x: 1439, y: 899), expected: nil),
        GeometryCase(
            label: "two displays, the main one's bottom right leads on", screens: [main, tallRight],
            point: CGPoint(x: 1439, y: 0), expected: nil),
        GeometryCase(
            label: "two displays, the taller one's top left stops the pointer", screens: [main, tallRight],
            point: CGPoint(x: 1440, y: 1079), expected: .topLeft),
        GeometryCase(
            label: "two displays, the outer top right", screens: [main, tallRight], point: CGPoint(x: 3359, y: 1079),
            expected: .topRight),
        GeometryCase(
            label: "two displays, the outer top left", screens: [main, tallRight], point: CGPoint(x: 0, y: 899),
            expected: .topLeft),
        // Three displays: one right of the main one, one above it.
        GeometryCase(
            label: "three displays, the main one's top left leads up", screens: [main, right, above],
            point: CGPoint(x: 0, y: 899), expected: nil),
        GeometryCase(
            label: "three displays, the upper one's top left", screens: [main, right, above], point: CGPoint(x: 0, y: 1799),
            expected: .topLeft),
        GeometryCase(
            label: "three displays, the upper one's bottom right leads down", screens: [main, right, above],
            point: CGPoint(x: 1439, y: 900), expected: nil),
        GeometryCase(
            label: "three displays, the right one's top left leads sideways", screens: [main, right, above],
            point: CGPoint(x: 1440, y: 899), expected: nil),
        GeometryCase(
            label: "three displays, the right one's top right", screens: [main, right, above],
            point: CGPoint(x: 2879, y: 899), expected: .topRight),
        GeometryCase(
            label: "three displays, the right one's bottom right", screens: [main, right, above],
            point: CGPoint(x: 2879, y: 0), expected: .bottomRight),
    ]

    @Test("HOT-01 only real corners count: 1 to 3 displays, 3 pt of tolerance, a corner that leads on to another display is none", arguments: cases)
    func corners(_ test: GeometryCase) {
        #expect(HotCornerGeometry.corner(at: test.point, screens: test.screens) == test.expected)
    }
}
