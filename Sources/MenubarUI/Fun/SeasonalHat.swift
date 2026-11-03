import MenubarCore
import SwiftUI

/// A hat drawn over the butler, in code. The alert's butler wears the real art of the season (`icons/*-halloween.png`,
/// `*-party.png` for New Year, `*-santa.png`, `*-carnival.png`; see ``AppImages/alert(_:hat:)``), and this drawing stays
/// only as the fallback when a file is missing, and for the peeking butler, who has no art with hats.
///
/// The drawing sits in the 96 × 96 box of the alert's butler: his head's top is at about (44, 12), tilted a little.
struct SeasonalHatOverlay: View {
    let hat: ButlerHat
    /// where the head's top sits, as a fraction of the butler's box
    var head = UnitPoint(x: 0.46, y: 0.12)

    var body: some View {
        Canvas { context, size in
            let unit = size.width / 96
            context.translateBy(x: head.x * size.width, y: head.y * size.height + 2 * unit)
            context.rotate(by: .degrees(-11))
            context.scaleBy(x: unit * 1.25, y: unit * 1.25)
            switch hat {
            case .witch: Self.witch(&context)
            case .newYear: Self.newYear(&context)
            case .party: Self.party(&context)
            case .santa: Self.santa(&context)
            case .carnival, .easter: break
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// the origin is the middle of the hat's base, on the head
    private static func witch(_ context: inout GraphicsContext) {
        let black = Color(red: 0.11, green: 0.08, blue: 0.16)
        let purple = Color(red: 0.55, green: 0.28, blue: 0.80)
        var cone = Path()
        cone.move(to: CGPoint(x: -13, y: 0))
        cone.addCurve(to: CGPoint(x: 15, y: -27), control1: CGPoint(x: -9, y: -14), control2: CGPoint(x: 2, y: -26))
        cone.addCurve(to: CGPoint(x: 11, y: -22), control1: CGPoint(x: 17, y: -28), control2: CGPoint(x: 13, y: -27))
        cone.addCurve(to: CGPoint(x: 13, y: 0), control1: CGPoint(x: 8, y: -14), control2: CGPoint(x: 11, y: -6))
        cone.closeSubpath()
        context.fill(cone, with: .color(black))
        context.stroke(cone, with: .color(.black.opacity(0.5)), lineWidth: 0.8)
        context.fill(Path(CGRect(x: -12, y: -7, width: 24, height: 5.5)), with: .color(purple))
        context.fill(Path(CGRect(x: -2.4, y: -7.6, width: 4.8, height: 6.7)), with: .color(Color(red: 0.98, green: 0.78, blue: 0.25)))
        context.fill(Path(CGRect(x: -1.2, y: -6.2, width: 2.4, height: 3.9)), with: .color(purple))
        let brim = Path(ellipseIn: CGRect(x: -21, y: -3.5, width: 42, height: 9))
        context.fill(brim, with: .color(black))
        context.stroke(brim, with: .color(.black.opacity(0.5)), lineWidth: 0.8)
    }

    private static func party(_ context: inout GraphicsContext) {
        var cone = Path()
        cone.move(to: CGPoint(x: -12, y: 1))
        cone.addLine(to: CGPoint(x: 0, y: -25))
        cone.addLine(to: CGPoint(x: 12, y: 1))
        cone.closeSubpath()
        context.fill(cone, with: .color(Color(red: 0.30, green: 0.60, blue: 0.95)))
        context.stroke(cone, with: .color(.black.opacity(0.45)), lineWidth: 0.8)
        for (x, y) in [(-4.0, -8.0), (4.0, -14.0), (0.0, -3.0)] {
            context.fill(Path(ellipseIn: CGRect(x: x - 1.8, y: y - 1.8, width: 3.6, height: 3.6)), with: .color(Color(red: 0.98, green: 0.72, blue: 0.20)))
        }
        context.fill(Path(ellipseIn: CGRect(x: -4, y: -29, width: 8, height: 8)), with: .color(Color(red: 0.95, green: 0.33, blue: 0.33)))
    }

    private static func santa(_ context: inout GraphicsContext) {
        let red = Color(red: 0.84, green: 0.16, blue: 0.18)
        var cone = Path()
        cone.move(to: CGPoint(x: -14, y: 1))
        cone.addCurve(to: CGPoint(x: 16, y: -14), control1: CGPoint(x: -12, y: -20), control2: CGPoint(x: 8, y: -24))
        cone.addLine(to: CGPoint(x: 14, y: 1))
        cone.closeSubpath()
        context.fill(cone, with: .color(red))
        context.stroke(cone, with: .color(.black.opacity(0.45)), lineWidth: 0.8)
        context.fill(Path(roundedRect: CGRect(x: -16, y: -3, width: 32, height: 7), cornerRadius: 3.5), with: .color(.white))
        context.fill(Path(ellipseIn: CGRect(x: 12, y: -19, width: 8, height: 8)), with: .color(.white))
    }

    private static func newYear(_ context: inout GraphicsContext) {
        let gold = Color(red: 0.98, green: 0.80, blue: 0.30)
        let deep = Color(red: 0.20, green: 0.30, blue: 0.62)
        var cone = Path()
        cone.move(to: CGPoint(x: -13, y: 1))
        cone.addLine(to: CGPoint(x: 0, y: -26))
        cone.addLine(to: CGPoint(x: 13, y: 1))
        cone.closeSubpath()
        context.fill(cone, with: .linearGradient(
            Gradient(colors: [Color(red: 1.0, green: 0.92, blue: 0.55), gold]), startPoint: CGPoint(x: -13, y: -26),
            endPoint: CGPoint(x: 13, y: 1)))
        context.stroke(cone, with: .color(.black.opacity(0.45)), lineWidth: 0.8)
        for (offset, width) in [(-7.0, 17.0), (-14.0, 9.0)] {
            context.fill(Path(CGRect(x: -width / 2, y: offset, width: width, height: 2.6)), with: .color(deep))
        }
        context.fill(Path(CGRect(x: -13, y: -1.5, width: 26, height: 3.6)), with: .color(deep))
        context.fill(Path(ellipseIn: CGRect(x: -3.8, y: -30, width: 7.6, height: 7.6)), with: .color(.white))
        context.stroke(Path(ellipseIn: CGRect(x: -3.8, y: -30, width: 7.6, height: 7.6)), with: .color(.black.opacity(0.35)), lineWidth: 0.6)
        // sparkles
        for (x, y, size) in [(-19.0, -20.0, 4.0), (19.0, -12.0, 3.0), (-22.0, -6.0, 2.4)] {
            var star = Path()
            star.move(to: CGPoint(x: x, y: y - size))
            star.addLine(to: CGPoint(x: x + size * 0.28, y: y - size * 0.28))
            star.addLine(to: CGPoint(x: x + size, y: y))
            star.addLine(to: CGPoint(x: x + size * 0.28, y: y + size * 0.28))
            star.addLine(to: CGPoint(x: x, y: y + size))
            star.addLine(to: CGPoint(x: x - size * 0.28, y: y + size * 0.28))
            star.addLine(to: CGPoint(x: x - size, y: y))
            star.addLine(to: CGPoint(x: x - size * 0.28, y: y - size * 0.28))
            star.closeSubpath()
            context.fill(star, with: .color(gold))
        }
    }
}
