import MenubarCore
import SwiftUI

/// Steam that rises from the coffee break's cup: soft wisps that curl up and fade, over the butler's picture. Two wisps for
/// 6 s at Normal, three for 12 s at Party, then it settles; with Reduce Motion nothing moves and the art's own steam stays.
struct CoffeeSteam: View {
    let level: FunLevel
    /// draws one still frame at this many seconds instead of playing, for the gallery's shots
    var frozenAt: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var start = Date()
    @ViewState private var isDone = false

    /// where the cup's rim is in the picture, as a fraction of it
    private static let cup = UnitPoint(x: 0.66, y: 0.36)

    var body: some View {
        if !reduceMotion || frozenAt != nil, !isDone {
            TimelineView(.animation(paused: isDone || frozenAt != nil)) { timeline in
                let time = frozenAt ?? timeline.date.timeIntervalSince(start)
                Canvas { context, size in
                    let wisps = level.isParty ? 3 : 2
                    for wisp in 0..<wisps {
                        draw(&context, size: size, wisp: wisp, time: time)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                guard frozenAt == nil else { return }
                start = Date()
                try? await Task.sleep(for: .seconds(level.isParty ? 12 : 6))
                isDone = true
            }
        }
    }

    /// One wisp rises over three seconds, again and again, a little offset from the others.
    private func draw(_ context: inout GraphicsContext, size: CGSize, wisp: Int, time: Double) {
        let cycle = 3.0
        let local = (time + Double(wisp) * cycle / 3).truncatingRemainder(dividingBy: cycle) / cycle
        let baseX = Self.cup.x * size.width + CGFloat(wisp - 1) * size.width * 0.045
        let baseY = Self.cup.y * size.height
        let rise = size.height * 0.24
        var path = Path()
        let steps = 14
        for step in 0...steps {
            let fraction = Double(step) / Double(steps)
            let x = baseX + CGFloat(sin(fraction * 5 + time * 2 + Double(wisp)) * Double(size.width) * 0.018 * (0.4 + fraction))
            let y = baseY - CGFloat(fraction) * rise * CGFloat(0.4 + local * 0.6)
            if step == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        // A wisp fades in, floats, and fades out.
        let opacity = sin(local * .pi) * 0.75
        var layer = context
        layer.opacity = opacity
        layer.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: size.width * 0.028, lineCap: .round, lineJoin: .round))
    }
}
