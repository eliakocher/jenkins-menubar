import AppKit
import MenubarCore
import SwiftUI

/// The corner glow (HOT-12): a soft light that plays once in a screen corner, in the glow's color, style and size. The
/// app's panel shows it over the real screen, and Settings plays it in its drawing of one.
///
/// It plays from the moment it appears, over ``HotCornerGlow/duration``, and draws nothing afterwards. Under
/// Reduce Motion every style is only a bloom that fades in and out, without growing, beating or spreading.
public struct HotCornerGlowView: View {
    private let corner: HotCorner
    private let glow: HotCornerGlow
    private let side: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var start = Date()

    /// - Parameters:
    ///   - corner: the corner the light comes from
    ///   - glow: the color, style and size
    ///   - side: how far the light reaches from the corner, in points; the glow's size by default
    public init(corner: HotCorner, glow: HotCornerGlow, side: CGFloat? = nil) {
        self.corner = corner
        self.glow = glow
        self.side = side ?? CGFloat(glow.size.points)
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            HotCornerGlowArt(
                corner: corner, glow: glow, progress: timeline.date.timeIntervalSince(start) / glow.duration,
                reduceMotion: reduceMotion
            )
        }
        .frame(width: side, height: side)
        .onAppear { start = Date() }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One frame of the corner glow, at a point of its animation: 0 is the start, 1 the end. The square's corner `corner`
/// is where the light comes from; the light fades out before the square's far sides.
struct HotCornerGlowArt: View {
    let corner: HotCorner
    let glow: HotCornerGlow
    /// 0…1; a value outside is clamped
    let progress: Double
    var reduceMotion = false

    var body: some View {
        let rgb = glow.color.resolvedRGB
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let side = min(size.width, size.height)
            let origin = CGPoint(x: corner.isLeft ? 0 : size.width, y: corner.isTop ? 0 : size.height)
            var layer = context
            layer.opacity = glow.opacity
            layer.blendMode = .plusLighter
            Self.draw(
                in: &layer, side: side, origin: origin, rgb: rgb, style: glow.style,
                progress: min(1, max(0, progress)), reduceMotion: reduceMotion)
        }
        .allowsHitTesting(false)
    }

    // MARK: Drawing

    private typealias RGB = (red: Double, green: Double, blue: Double)

    private static func draw(
        in context: inout GraphicsContext, side: CGFloat, origin: CGPoint, rgb: RGB, style: HotCornerGlowStyle,
        progress p: Double, reduceMotion: Bool
    ) {
        if reduceMotion {
            let intensity = smoothstep(0, 0.25, p) * (1 - smoothstep(0.3, 1, p))
            bloom(&context, side: side, origin: origin, rgb: rgb, radius: 0.8, intensity: intensity)
            return
        }
        switch style {
        case .glow:
            let rise = smoothstep(0, 0.14, p)
            let fall = 1 - easeInOut((p - 0.22) / 0.78)
            let radius = 0.45 + 0.55 * easeOut(p)
            bloom(&context, side: side, origin: origin, rgb: rgb, radius: radius, intensity: rise * pow(max(0, fall), 1.4))
        case .pulse:
            let first = exp(-pow((p - 0.24) / 0.12, 2))
            let second = 0.8 * exp(-pow((p - 0.64) / 0.14, 2))
            let beat = min(1, first + second) * smoothstep(0, 0.05, p)
            bloom(&context, side: side, origin: origin, rgb: rgb, radius: 0.5 + 0.38 * beat + 0.08 * p, intensity: beat)
        case .ripple:
            // A faint bloom at the source, then rings that leave one after the other and thin out as they spread.
            let source = smoothstep(0, 0.1, p) * (1 - smoothstep(0.1, 0.65, p))
            bloom(&context, side: side, origin: origin, rgb: rgb, radius: 0.34 + 0.2 * easeOut(p), intensity: source)
            for delay in [0.0, 0.17, 0.34] {
                let q = (p - delay) / 0.56
                guard q > 0, q < 1 else {
                    continue
                }
                let radius = Double(side) * 0.86 * easeOut(q)
                let width = Double(side) * (0.06 + 0.07 * q)
                let alpha = 1.0 * pow(1 - q, 1.3) * smoothstep(0, 0.08, q)
                ring(&context, side: side, origin: origin, rgb: rgb, radius: radius, width: width, alpha: alpha)
            }
        }
    }

    /// A bloom of three layers, wide and soft, tighter, and a small hot core that leans to white.
    private static func bloom(
        _ context: inout GraphicsContext, side: CGFloat, origin: CGPoint, rgb: RGB, radius: Double, intensity: Double
    ) {
        guard intensity > 0.002 else {
            return
        }
        let reach = Double(side) * radius
        let hot = mix(rgb, with: 0.4)
        fill(&context, side: side, origin: origin, radius: reach, stops: softStops(rgb, peak: 0.8 * intensity))
        fill(&context, side: side, origin: origin, radius: reach * 0.55, stops: softStops(rgb, peak: 0.85 * intensity))
        fill(&context, side: side, origin: origin, radius: reach * 0.22, stops: softStops(hot, peak: 0.8 * intensity))
    }

    /// One ring: a band of light with a soft edge on both sides, brightest in the middle.
    private static func ring(
        _ context: inout GraphicsContext, side: CGFloat, origin: CGPoint, rgb: RGB, radius: Double, width: Double,
        alpha: Double
    ) {
        guard alpha > 0.002, radius > 0 else {
            return
        }
        let outer = radius + width
        let samples = 16
        let stops = (0...samples).map { index -> Gradient.Stop in
            let x = -1 + 2 * Double(index) / Double(samples)
            let shape = pow(cos(x * .pi / 2), 2)
            return Gradient.Stop(
                color: color(mix(rgb, with: 0.3 * shape), alpha: alpha * shape), location: max(0, (radius + x * width) / outer))
        }
        fill(&context, side: side, origin: origin, radius: outer, stops: stops)
    }

    private static func fill(
        _ context: inout GraphicsContext, side: CGFloat, origin: CGPoint, radius: Double, stops: [Gradient.Stop]
    ) {
        // The square around the corner is as wide as the canvas, so the gradient never meets an edge before it is clear.
        let rect = CGRect(x: origin.x - side, y: origin.y - side, width: side * 2, height: side * 2)
        context.fill(
            Path(rect),
            with: .radialGradient(Gradient(stops: stops), center: origin, startRadius: 0, endRadius: CGFloat(radius)))
    }

    /// A falloff with no corner at its start or its end: a raised cosine, tighter than a plain one.
    private static func softStops(_ rgb: RGB, peak: Double) -> [Gradient.Stop] {
        let samples = 14
        return (0...samples).map { index in
            let x = Double(index) / Double(samples)
            return Gradient.Stop(color: color(rgb, alpha: peak * pow(cos(x * .pi / 2), 2.0)), location: x)
        }
    }

    private static func color(_ rgb: RGB, alpha: Double) -> Color {
        Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: alpha)
    }

    private static func mix(_ rgb: RGB, with white: Double) -> RGB {
        (rgb.red + (1 - rgb.red) * white, rgb.green + (1 - rgb.green) * white, rgb.blue + (1 - rgb.blue) * white)
    }

    // MARK: Easing

    private static func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = min(1, max(0, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }

    private static func easeOut(_ t: Double) -> Double {
        1 - pow(1 - min(1, max(0, t)), 2.6)
    }

    private static func easeInOut(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return t * t * (3 - 2 * t)
    }
}

extension HotCornerGlowColor {
    /// the color's red, green and blue (0…1); the accent is the system's
    var resolvedRGB: (red: Double, green: Double, blue: Double) {
        if let rgb {
            return rgb
        }
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.systemBlue
        return (Double(accent.redComponent), Double(accent.greenComponent), Double(accent.blueComponent))
    }

    /// the color as a SwiftUI color, for swatches
    var swiftUIColor: Color {
        let rgb = resolvedRGB
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}
