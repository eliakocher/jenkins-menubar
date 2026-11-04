import AppKit
import MenubarCore
import SwiftUI

/// The butler's place at the top of an alert page: his art at the alert's scale, standing at the bottom, centered.
///
/// The page takes its own height (the user, 2026-11-04: "the butler was relatively small… and there was a lot of empty
/// space in some cases"): the stage is as tall as his art, plus the sky's headroom only while there is a sky. The cloud and
/// the rain of a failed build draw inside the stage, behind him, so nothing is drawn outside what the page measures and
/// nothing clips at the window's top.
struct ButlerStage<Behind: View, Front: View>: View {
    /// the box the plain butler fills, in points (96 until 1.0.7)
    static var artBox: CGFloat { 128 }

    /// Returns the height of the stage for art of a size.
    ///
    /// - Parameters:
    ///   - art: the art's size at the alert's scale
    ///   - hasSky: whether a cloud and rain draw behind him, which need the headroom above his art
    static func height(of art: CGSize, hasSky: Bool) -> CGFloat {
        art.height + (hasSky ? SadWeatherSky.headroom : 0)
    }

    /// whether a sky draws behind the butler
    let hasSky: Bool
    let art: NSImage
    let icon: AlertContent.Icon
    let hat: ButlerHat?
    /// the fun level, which sets how much the butler moves; `nil` for none
    let level: FunLevel?
    /// what draws behind him, from the sky's top to his feet; the cloud and the rain
    let behind: Behind
    /// what sits over the bottom right corner of his art, like a badge
    let front: Front

    init(
        art: NSImage, icon: AlertContent.Icon, hat: ButlerHat?, level: FunLevel?, hasSky: Bool = false,
        @ViewBuilder behind: () -> Behind, @ViewBuilder front: () -> Front
    ) {
        self.hasSky = hasSky
        self.art = art
        self.icon = icon
        self.hat = hat
        self.level = level
        self.behind = behind()
        self.front = front()
    }

    var body: some View {
        let size = AppImages.alertSize(of: art, box: Self.artBox)
        Image(nsImage: art)
            .resizable()
            .interpolation(.high)
            .frame(width: size.width, height: size.height)
            .overlay {
                // The witch's and New Year's hats are drawn in code only when their art is missing (the fallback).
                if let hat, AppImages.drawsFallbackHat(icon, hat: hat) {
                    SeasonalHatOverlay(hat: hat)
                }
            }
            // The butler bounces on a green build and shakes on a red one, once (Normal and Party).
            .funButlerMotion(isHappy: icon == .happy, level: level)
            .overlay(alignment: .bottomTrailing) { front }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .frame(height: Self.height(of: size, hasSky: hasSky))
            .background(alignment: .bottom) {
                // The sky starts the headroom above his art and ends at his feet, inside the stage.
                if hasSky {
                    behind
                        .frame(width: 300, height: size.height + SadWeatherSky.headroom)
                }
            }
    }
}

extension ButlerStage where Front == EmptyView {
    init(
        art: NSImage, icon: AlertContent.Icon, hat: ButlerHat?, level: FunLevel?, hasSky: Bool = false,
        @ViewBuilder behind: () -> Behind
    ) {
        self.init(art: art, icon: icon, hat: hat, level: level, hasSky: hasSky, behind: behind, front: { EmptyView() })
    }
}
