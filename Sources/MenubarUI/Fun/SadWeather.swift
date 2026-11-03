import MenubarCore
import SwiftUI

/// The sad twin of the confetti (`docs/easter-eggs.md`, the fun layer): over a failed build's butler a grey cloud drifts in and
/// rain falls behind him for about two seconds. An unstable build gets a few drops, and at Party the third failure in a row
/// or a Friday failure gets a storm: a dark cloud, heavy rain and one or two flashes of lightning.
///
/// Drawn on a `Canvas` from the time since it started, so it holds no timers of its own and stops drawing when it ends.
/// It never takes a click and makes no sound. With Reduce Motion on, a still cloud shows for two seconds: no rain
/// motion, no flash.
enum SadWeatherTimeline {
    /// how long each weather plays, in seconds
    static func duration(_ weather: SadWeather) -> Double {
        switch weather {
        case .drizzle: 2.2
        case .rain: 2.6
        case .storm: 3.4
        }
    }

    /// the moments of the lightning flashes: one, or two for an even seed
    static func flashes(seed: Int) -> [Double] {
        seed % 2 == 0 ? [0.9, 1.55] : [1.0]
    }

    /// how long a flash lasts
    static let flashLength = 0.14

    /// how strong the white flash over the panel is at a time: 20 % at its start, fading quickly; 0 without a flash
    static func flash(at time: Double, seed: Int) -> Double {
        for start in flashes(seed: seed) where time >= start && time < start + flashLength {
            return 0.2 * (1 - (time - start) / flashLength)
        }
        return 0
    }
}

/// The cloud and the rain, behind the butler.
struct SadWeatherSky: View {
    let weather: SadWeather
    var seed = 5
    /// draws one still frame at this many seconds instead of playing, for the gallery's shots
    var frozenAt: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var start = Date()
    @ViewState private var isDone = false

    var body: some View {
        Group {
            if let frozenAt {
                Canvas { context, size in draw(&context, size: size, time: frozenAt, fade: 1, still: false) }
            } else if !isDone {
                if reduceMotion {
                    Canvas { context, size in draw(&context, size: size, time: 1.2, fade: 1, still: true) }
                } else {
                    TimelineView(.animation(paused: isDone)) { timeline in
                        let time = timeline.date.timeIntervalSince(start)
                        let length = SadWeatherTimeline.duration(weather)
                        Canvas { context, size in
                            draw(&context, size: size, time: time, fade: min(1, max(0, (length - time) / 0.5)), still: false)
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
            try? await Task.sleep(for: .seconds(reduceMotion ? 2 : SadWeatherTimeline.duration(weather)))
            isDone = true
        }
    }

    /// how far above the butler the canvas starts, so the cloud can sit over his head (the window's padding is 20)
    static let headroom: CGFloat = 20

    /// Draws the cloud, the rain and the bolt at a time. The origin is the top of the canvas, which starts ``headroom`` above
    /// the butler; the cloud sits in its upper part, centered, and the rain falls from its belly.
    func draw(_ context: inout GraphicsContext, size: CGSize, time: Double, fade: Double, still: Bool) {
        let centerX = size.width / 2
        let storm = weather == .storm
        // The cloud drifts in from the left in 0.7 s and then sways a little.
        let arrive = min(1, time / 0.7)
        let eased = 1 - pow(1 - arrive, 3)
        let drift = still ? 0 : -70 * (1 - eased) + 5 * sin(time * 1.3)
        let cloudWidth: CGFloat = storm ? 150 : 112
        let cloudCenter = CGPoint(x: centerX + drift, y: storm ? 38 : 34)
        var cloudContext = context
        cloudContext.opacity = fade * (still ? 1 : min(1, time / 0.3 + 0.001))
        Self.drawCloud(&cloudContext, center: cloudCenter, width: cloudWidth, storm: storm)

        guard !still else {
            return
        }
        // The rain: seeded drops that start one after the other and fall in loops from the cloud's belly to a fade-out.
        var generator = SeededGenerator(seed: UInt64(seed) &* 7_919 &+ 3)
        let count = switch weather {
        case .drizzle: 9
        case .rain: 52
        case .storm: 110
        }
        let belly = cloudCenter.y + cloudWidth * 0.2
        let fall = size.height - belly
        let tint = colorScheme == .dark
            ? Color(red: 0.66, green: 0.78, blue: 0.98) : Color(red: 0.25, green: 0.42, blue: 0.75)
        for _ in 0..<count {
            let x = cloudCenter.x + Double.random(in: -0.46...0.46, using: &generator) * cloudWidth
            let speed = Double.random(in: storm ? 360...520 : weather == .rain ? 250...340 : 170...230, using: &generator)
            let length = Double.random(in: storm ? 13...20 : weather == .rain ? 8...13 : 6...9, using: &generator)
            let delay = Double.random(in: 0.25...max(0.3, SadWeatherTimeline.duration(weather) - 0.9), using: &generator)
            let phase = Double.random(in: 0...fall, using: &generator)
            guard time >= delay else { continue }
            let travelled = ((time - delay) * speed + phase).truncatingRemainder(dividingBy: fall)
            let y = belly + travelled
            // fade in under the cloud, out near the bottom
            let alpha = min(1, travelled / 12) * (1 - travelled / fall) * 0.95 * fade
            var drop = Path()
            drop.move(to: CGPoint(x: x, y: y))
            drop.addLine(to: CGPoint(x: x - length * 0.12, y: y + length))
            context.stroke(drop, with: .color(tint.opacity(alpha)), style: StrokeStyle(lineWidth: storm ? 1.8 : 1.5, lineCap: .round))
        }
        // The bolt shows for the first 0.1 s of each flash.
        if storm {
            for start in SadWeatherTimeline.flashes(seed: seed) where time >= start && time < start + 0.1 {
                Self.drawBolt(&context, from: CGPoint(x: cloudCenter.x + (start < 1 ? -14 : 18), y: belly - 4), to: belly + 70)
            }
        }
    }

    /// a cloud from five overlapping ellipses and a flat base
    private static func drawCloud(_ context: inout GraphicsContext, center: CGPoint, width: CGFloat, storm: Bool) {
        let body = storm ? Color(red: 0.30, green: 0.32, blue: 0.39) : Color(red: 0.66, green: 0.69, blue: 0.75)
        let shade = storm ? Color(red: 0.20, green: 0.21, blue: 0.27) : Color(red: 0.55, green: 0.58, blue: 0.65)
        let unit = width / 112
        // (x, y, width, height) around the center, in units
        let puffs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (-30, 8, 46, 28), (28, 8, 46, 28), (-14, -6, 44, 36), (14, -10, 44, 40), (0, 12, 84, 24),
        ]
        for layer in [(shade, CGFloat(3)), (body, CGFloat(0))] {
            for puff in puffs {
                let rect = CGRect(
                    x: center.x + (puff.0 - puff.2 / 2) * unit, y: center.y + (puff.1 - puff.3 / 2) * unit + layer.1 * unit,
                    width: puff.2 * unit, height: puff.3 * unit)
                context.fill(Path(ellipseIn: rect), with: .color(layer.0))
            }
        }
    }

    private static func drawBolt(_ context: inout GraphicsContext, from start: CGPoint, to bottom: CGFloat) {
        var bolt = Path()
        bolt.move(to: start)
        let step = (bottom - start.y) / 4
        let zig: [CGFloat] = [-9, 8, -7, 6]
        var point = start
        for offset in zig {
            point = CGPoint(x: point.x + offset, y: point.y + step)
            bolt.addLine(to: point)
        }
        context.stroke(bolt, with: .color(Color(red: 1, green: 0.96, blue: 0.7)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }
}

/// The white flash of the storm's lightning over the whole panel, about 20 % at its start, for a tenth of a second. Nothing
/// under Reduce Motion.
struct SadWeatherFlash: View {
    let weather: SadWeather
    var seed = 5
    var frozenAt: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var start = Date()
    @ViewState private var isDone = false

    var body: some View {
        Group {
            if weather == .storm, !reduceMotion {
                if let frozenAt {
                    Color.white.opacity(SadWeatherTimeline.flash(at: frozenAt, seed: seed))
                } else if !isDone {
                    TimelineView(.animation(paused: isDone)) { timeline in
                        Color.white.opacity(SadWeatherTimeline.flash(at: timeline.date.timeIntervalSince(start), seed: seed))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            guard frozenAt == nil, weather == .storm else { return }
            start = Date()
            try? await Task.sleep(for: .seconds(SadWeatherTimeline.duration(.storm)))
            isDone = true
        }
    }
}
