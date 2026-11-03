import MenubarCore
import SwiftUI

/// The butler of an alert moves once when the alert shows: a small happy bounce on a green build, a sad shake on a red one
/// (Normal and Party; Party moves a little more). Under Reduce Motion it stays still.
struct FunButlerMotion: ViewModifier {
    let isHappy: Bool
    let level: FunLevel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var trigger = false

    private struct Frame {
        var lift = 0.0
        var shake = 0.0
        var tilt = 0.0
        var scale = 1.0
    }

    func body(content: Content) -> some View {
        if let level, level.animates, !reduceMotion {
            let amount = level.isParty ? 1.35 : 1.0
            content
                .keyframeAnimator(initialValue: Frame(), trigger: trigger) { view, frame in
                    view
                        .scaleEffect(frame.scale, anchor: .bottom)
                        .rotationEffect(.degrees(frame.tilt), anchor: .bottom)
                        .offset(x: frame.shake, y: frame.lift)
                } keyframes: { _ in
                    // A green build bounces, a red one shakes: the other kind's tracks stay at zero.
                    let up = isHappy ? 1.0 : 0.0
                    let side = isHappy ? 0.0 : 1.0
                    KeyframeTrack(\.lift) {
                        CubicKeyframe(-16 * amount * up, duration: 0.16)
                        CubicKeyframe(0, duration: 0.16)
                        CubicKeyframe(-7 * amount * up, duration: 0.12)
                        CubicKeyframe(0, duration: 0.12)
                    }
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(1 + 0.05 * up, duration: 0.16)
                        CubicKeyframe(1, duration: 0.4)
                    }
                    KeyframeTrack(\.shake) {
                        CubicKeyframe(-7 * amount * side, duration: 0.06)
                        CubicKeyframe(7 * amount * side, duration: 0.09)
                        CubicKeyframe(-5 * amount * side, duration: 0.09)
                        CubicKeyframe(4 * amount * side, duration: 0.08)
                        CubicKeyframe(0, duration: 0.1)
                    }
                    KeyframeTrack(\.tilt) {
                        CubicKeyframe(-3 * amount * side, duration: 0.1)
                        CubicKeyframe(3 * amount * side, duration: 0.14)
                        CubicKeyframe(0, duration: 0.18)
                    }
                }
                .task {
                    // A moment after the alert's glass is up.
                    try? await Task.sleep(for: .milliseconds(350))
                    trigger.toggle()
                }
        } else {
            content
        }
    }
}

extension View {
    /// Makes the alert's butler bounce or shake once, by the fun level the alert was made under.
    func funButlerMotion(isHappy: Bool, level: FunLevel?) -> some View {
        modifier(FunButlerMotion(isHappy: isHappy, level: level))
    }
}
