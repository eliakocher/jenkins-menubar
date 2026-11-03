import MenubarCore
import SwiftUI

/// A short burst of confetti over a view (`docs/easter-eggs.md`, the fun layer): drawn on a `Canvas` from the time since it
/// started, so it holds no timers of its own and stops drawing when it ends. It never takes a click.
///
/// A small burst (Normal) is 40 pieces for 1.6 s, a full one (Party) 110 pieces for 2.8 s. With Reduce Motion on, nothing
/// moves: a still scatter shows for two seconds.
struct ConfettiBurst: View {
    let level: FunLevel
    /// where the burst starts, as a fraction of the view's size
    var origin = UnitPoint(x: 0.5, y: 0.32)
    var seed = 7
    /// draws one still frame at this many seconds instead of playing, for the gallery's shots
    var frozenAt: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var start = Date()
    @ViewState private var isDone = false

    static let palette: [Color] = [
        Color(red: 0.95, green: 0.33, blue: 0.33), Color(red: 0.98, green: 0.72, blue: 0.20),
        Color(red: 0.30, green: 0.78, blue: 0.45), Color(red: 0.25, green: 0.60, blue: 0.95),
        Color(red: 0.72, green: 0.42, blue: 0.92), Color(red: 0.98, green: 0.50, blue: 0.75),
    ]

    var count: Int { level.isParty ? 110 : 40 }
    var duration: Double { reduceMotion ? 2 : level.isParty ? 2.8 : 1.6 }

    var body: some View {
        Group {
            if let frozenAt {
                Canvas { context, size in draw(&context, size: size, time: frozenAt, fade: 1) }
            } else if !isDone {
                if reduceMotion {
                    Canvas { context, size in draw(&context, size: size, time: 0.55, fade: 1) }
                } else {
                    TimelineView(.animation(paused: isDone)) { timeline in
                        let time = timeline.date.timeIntervalSince(start)
                        Canvas { context, size in
                            draw(&context, size: size, time: time, fade: min(1, max(0, (duration - time) / 0.5)))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            guard frozenAt == nil else { return }
            start = Date()
            try? await Task.sleep(for: .seconds(duration))
            isDone = true
        }
    }

    /// Draws every piece at a time: thrown up and out from the origin, pulled down, spinning, fading at the end.
    func draw(_ context: inout GraphicsContext, size: CGSize, time: Double, fade: Double) {
        var generator = SeededGenerator(seed: UInt64(seed) &* 2_654_435_761 &+ 1)
        let scale = size.height / 320
        for index in 0..<count {
            let angle = Double.random(in: -.pi * 0.95 ... -.pi * 0.05, using: &generator)
            let speed = Double.random(in: 140...(level.isParty ? 520 : 380), using: &generator) * scale
            let spin = Double.random(in: -9...9, using: &generator)
            let side = Double.random(in: 4...(level.isParty ? 9 : 7), using: &generator)
            let wide = Bool.random(using: &generator)
            let x = origin.x * size.width + cos(angle) * speed * time
            let y = origin.y * size.height + sin(angle) * speed * time + 0.5 * 620 * scale * time * time
            var piece = context
            piece.opacity = fade
            piece.translateBy(x: x, y: y)
            piece.rotate(by: .radians(spin * time + Double(index)))
            let rect = CGRect(x: -side / 2, y: -side / 3, width: side, height: wide ? side * 0.55 : side)
            let color = Self.palette[index % Self.palette.count]
            piece.fill(wide ? Path(rect) : Path(ellipseIn: rect), with: .color(color))
        }
    }
}

/// A little fireworks burst for New Year and the app's anniversary: three bursts of sparks in the upper half, one after the
/// other, over about 2.6 s. With Reduce Motion on, one still burst shows for two seconds.
struct FireworksBurst: View {
    var seed = 3
    /// draws one still frame at this many seconds instead of playing, for the gallery's shots
    var frozenAt: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var start = Date()
    @ViewState private var isDone = false

    private static let centers = [UnitPoint(x: 0.25, y: 0.28), UnitPoint(x: 0.72, y: 0.20), UnitPoint(x: 0.5, y: 0.38)]
    private static let colors: [Color] = [
        Color(red: 1.0, green: 0.82, blue: 0.30), Color(red: 0.98, green: 0.45, blue: 0.55), Color(red: 0.45, green: 0.80, blue: 1.0),
    ]
    private static let duration = 2.6

    var body: some View {
        Group {
            if let frozenAt {
                Canvas { context, size in draw(&context, size: size, time: frozenAt) }
            } else if !isDone {
                if reduceMotion {
                    Canvas { context, size in draw(&context, size: size, time: 1.05) }
                } else {
                    TimelineView(.animation(paused: isDone)) { timeline in
                        Canvas { context, size in draw(&context, size: size, time: timeline.date.timeIntervalSince(start)) }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            guard frozenAt == nil else { return }
            start = Date()
            try? await Task.sleep(for: .seconds(reduceMotion ? 2 : Self.duration))
            isDone = true
        }
    }

    func draw(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        var generator = SeededGenerator(seed: UInt64(seed) &* 40503 &+ 11)
        for (index, center) in Self.centers.enumerated() {
            let local = reduceMotion ? time : time - Double(index) * 0.55
            guard local >= 0, local < 1.5 else {
                continue
            }
            let color = Self.colors[index % Self.colors.count]
            let fade = max(0, 1 - local / 1.5)
            for spark in 0..<30 {
                let angle = Double(spark) / 30 * 2 * .pi + Double.random(in: -0.1...0.1, using: &generator)
                let speed = Double.random(in: 70...130, using: &generator) * size.height / 320
                let x = center.x * size.width + cos(angle) * speed * local
                let y = center.y * size.height + sin(angle) * speed * local + 60 * local * local
                let radius = 3.2 * (1 - local / 2.2)
                var dot = context
                dot.opacity = fade
                dot.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
            }
        }
    }
}

/// What plays over an alert: confetti or fireworks, by the alert's ``FunCelebration`` and fun level.
struct FunCelebrationOverlay: View {
    let celebration: FunCelebration
    let level: FunLevel
    var seed = 7
    var frozenAt: Double?

    var body: some View {
        switch celebration {
        case .confetti: ConfettiBurst(level: level, seed: seed, frozenAt: frozenAt)
        case .fireworks: FireworksBurst(seed: seed, frozenAt: frozenAt)
        }
    }
}

/// A small deterministic random source, so a burst has the same pieces at every frame.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }
}
