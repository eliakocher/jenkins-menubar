import AppKit
import MenubarCore
import SwiftUI

/// The art of the peeking butler (`icons/peek-side.png`, `peek-bottom.png`, `peek-top.png`, `caught.png`), trimmed of its
/// transparent margin, with where its straight cut line sits. Without the files, the happy butler, clipped and rotated at the
/// edge, stands in.
@MainActor
enum PeekArt {
    /// One image, ready to place: its cut line on the window's edge.
    struct Art {
        var image: NSImage
        /// the pixel size of the trimmed image
        var size: CGSize
        /// the part of the image outside the window, along the edge's normal: the left of a side peek's cut line, what hangs
        /// below a bottom peek's cut line, what is above a top peek's edge
        var hidden: CGFloat
        /// a turn for the stand-in, which isn't straight
        var rotation: Angle = .zero

        var aspect: CGFloat { size.width / max(size.height, 1) }
    }

    private static var cache: [String: Art?] = [:]

    /// Returns the art that comes out of an edge: left and right share one file, the right one mirrored by the view.
    static func art(for edge: FunModel.PeekEdge) -> Art {
        switch edge {
        case .left, .right:
            return load("peek-side", cut: 0.18, axis: .horizontal) ?? standIn(hidden: 0.5, rotation: edge == .left ? .degrees(16) : .degrees(-16))
        case .bottom:
            return load("peek-bottom", cut: 0.81, axis: .vertical, inverted: true) ?? standIn(hidden: 0.5, rotation: .zero)
        case .top:
            return load("peek-top", cut: 0, axis: .vertical) ?? standIn(hidden: 0.5, rotation: .degrees(180))
        }
    }

    /// the surprised butler, for the catch; the happy butler stands in
    static var caught: Art {
        load("caught", cut: 0, axis: .vertical) ?? standIn(hidden: 0, rotation: .zero)
    }

    private enum Axis { case horizontal, vertical }

    private static func standIn(hidden: CGFloat, rotation: Angle) -> Art {
        Art(image: AppImages.happy, size: CGSize(width: 238, height: 238), hidden: hidden, rotation: rotation)
    }

    /// Loads a file from the bundle, trims it, and works out where its cut line lies in the trimmed image.
    ///
    /// - Parameters:
    ///   - name: the file's name without `.png`
    ///   - cut: the cut line's place as a fraction of the original image along the axis: from the left, or from the top
    ///   - axis: the axis the cut line crosses
    ///   - inverted: whether the part after the cut line is the part outside the window (a bottom peek)
    private static func load(_ name: String, cut: CGFloat, axis: Axis, inverted: Bool = false) -> Art? {
        if let known = cache[name] {
            return known
        }
        let art = read(name, cut: cut, axis: axis, inverted: inverted)
        cache[name] = .some(art)
        return art
    }

    private static func read(_ name: String, cut: CGFloat, axis: Axis, inverted: Bool) -> Art? {
        var url = Bundle.main.url(forResource: name, withExtension: "png")
        #if DEBUG
        // Outside a bundle, as in the tests and the renders, the repo's own icons stand in.
        if url == nil {
            let file = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "icons/\(name).png")
            url = FileManager.default.fileExists(atPath: file.path) ? file : nil
        }
        #endif
        guard let url, let image = NSImage(contentsOf: url),
            var cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }
        let original = CGSize(width: cgImage.width, height: cgImage.height)
        let box = opaqueBox(of: cgImage) ?? CGRect(origin: .zero, size: original)
        if let cropped = cgImage.cropping(to: box) {
            cgImage = cropped
        }
        let trimmed = NSImage(cgImage: cgImage, size: box.size)
        let along: CGFloat
        switch axis {
        case .horizontal: along = max(0, (cut * original.width - box.minX) / box.width)
        case .vertical: along = max(0, (cut * original.height - box.minY) / box.height)
        }
        let hidden = inverted ? min(1, max(0, 1 - along)) : along
        return Art(image: trimmed, size: box.size, hidden: hidden)
    }

    /// Returns the box of the pixels that aren't transparent, in the image's own pixels from its top left.
    private static func opaqueBox(of image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            return nil
        }
        var (minX, minY, maxX, maxY) = (width, height, -1, -1)
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 12 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else {
            return nil
        }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// The butler at an edge of a surface, placed so his cut line sits on the edge, and slid in by `slide` (0 hidden, 1 out).
/// Left and right share one picture; the right one is mirrored.
struct ButlerPeekFigure: View {
    let edge: FunModel.PeekEdge
    /// where along the edge he is, 0 to 1
    var along: CGFloat = 0.5
    var slide: CGFloat = 1
    /// the hat the catches unlocked
    var hat: ButlerHat?
    /// the figure's own height; the bottom peek is wide and low
    var length: CGFloat = 120

    var body: some View {
        let art = PeekArt.art(for: edge)
        let frame = Self.size(of: art, edge: edge, length: length)
        GeometryReader { proxy in
            let origin = Self.origin(art: art, edge: edge, frame: frame, in: proxy.size, along: along, slide: slide)
            figure(art, frame: frame)
                .frame(width: frame.width, height: frame.height)
                .position(x: origin.x + frame.width / 2, y: origin.y + frame.height / 2)
        }
    }

    private func figure(_ art: PeekArt.Art, frame: CGSize) -> some View {
        ZStack {
            Image(nsImage: art.image)
                .resizable()
                .interpolation(.high)
                .rotationEffect(art.rotation)
                .scaleEffect(x: edge == .right ? -1 : 1)
            if let hat, edge == .left || edge == .right {
                // The hats show on the side peeks, where his head is upright.
                SeasonalHatOverlay(hat: hat, head: UnitPoint(x: edge == .right ? 0.38 : 0.62, y: 0.075))
                    .frame(width: frame.width, height: frame.width)
                    .frame(width: frame.width, height: frame.height, alignment: .top)
                    .allowsHitTesting(false)
            }
        }
    }

    /// the figure's size: `length` tall for a side or top peek, `length` wide-and-low for the bottom one
    static func size(of art: PeekArt.Art, edge: FunModel.PeekEdge, length: CGFloat) -> CGSize {
        switch edge {
        case .left, .right, .top: CGSize(width: length * art.aspect, height: length)
        case .bottom: CGSize(width: length * 1.35, height: length * 1.35 / art.aspect)
        }
    }

    /// Returns the figure's top left in a surface: his cut line on the edge, slid `1 - slide` of what shows back out of sight.
    static func origin(
        art: PeekArt.Art, edge: FunModel.PeekEdge, frame: CGSize, in size: CGSize, along: CGFloat, slide: CGFloat
    ) -> CGPoint {
        let shown = 1 - art.hidden
        let back = (1 - slide)
        let center = { (extent: CGFloat, length: CGFloat) in min(max(extent * along - length / 2, 8), max(8, extent - length - 8)) }
        switch edge {
        case .left:
            return CGPoint(x: -art.hidden * frame.width - back * shown * frame.width, y: center(size.height, frame.height))
        case .right:
            return CGPoint(
                x: size.width - frame.width + art.hidden * frame.width + back * shown * frame.width,
                y: center(size.height, frame.height))
        case .bottom:
            return CGPoint(
                x: center(size.width, frame.width), y: size.height - shown * frame.height + back * shown * frame.height)
        case .top:
            return CGPoint(x: center(size.width, frame.width), y: -art.hidden * frame.height - back * shown * frame.height)
        }
    }
}

/// The butler that peeks out of the surface's edge for about two seconds when the fun layer arms him; a click on him while he
/// is out is a catch: confetti, his secret line, and the counter of the About window.
///
/// - He slides in and out; under Reduce Motion he just shows and goes.
/// - He ducks back when the pointer rests on him for more than a third of a second, so catching him is a game.
/// - He never comes while the user types or drags, or just after an alert (``FunModel/claimPeek(busy:)``).
struct ButlerPeekOverlay: View {
    /// the kind of surface this is: a peek made for the other kind waits for it
    var surface = FunModel.PeekSurface.window
    /// the edges this surface lets him come out of
    var edges = Set(FunModel.PeekEdge.allCases)
    /// how much of him shows, of what would
    var reveal: CGFloat = 1
    /// whether this overlay draws him; the menu bar pane's peek is drawn by a panel beside the pane instead
    var drawsFigure = true
    /// whether he can't come out now: the menu bar pane has no room for his panel
    var isBlocked: (@MainActor () -> Bool)?
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// this surface's own name, so he is drawn only where he was taken
    @ViewState private var ownerID = UUID().uuidString
    /// how far out he is drawn, 0 to 1; follows the model's phase with an animation
    @ViewState private var slide: CGFloat = 0
    @ViewState private var fuse: Task<Void, Never>?

    private var owner: String { surface == .menuPane ? FunModel.paneOwner : ownerID }

    var body: some View {
        let fun = model?.fun
        ZStack {
            if drawsFigure, let playing = fun?.playing, playing.owner == owner {
                ButlerPeekFigure(
                    edge: playing.peek.edge, along: CGFloat(playing.along), slide: slide * reveal,
                    hat: FunModel.peekHat(catches: fun?.catches ?? 0), length: playing.peek.edge == .bottom ? 78 : 118)
                    .contentShape(Rectangle())
                    .onTapGesture { fun?.catchButler() }
                    .onHover { near in near ? startFuse() : cancelFuse() }
                    .accessibilityLabel("The butler peeks out. Click to catch him.")
                    .accessibilityAddTraits(.isButton)
            }
            if let caught = fun?.caughtPlay, caught.owner == owner {
                CaughtPopup(
                    caught: caught.result, edge: caught.edge, along: CGFloat(caught.along), level: fun?.level ?? .normal)
                    .id(caught.id)
            }
        }
        // The slide follows the phase the model plays; the playback itself lives in the model, so nothing here can end it.
        .onChange(of: fun?.playing?.phase, initial: true) { _, phase in
            // Where another view draws him (the menu bar pane's panel), nothing here slides: an animation of a value that
            // nothing draws would still update the surface's window every frame.
            guard drawsFigure else {
                return
            }
            let target: CGFloat = phase == .slidingOut || phase == nil ? 0 : 1
            if reduceMotion || phase == nil {
                slide = target
            } else {
                withAnimation(phase == .slidingOut ? .easeIn(duration: 0.2) : .spring(duration: 0.38, bounce: 0.3)) { slide = target }
            }
        }
        // The model knows which surfaces show, so a random peek picks one that is on screen.
        .onAppear { model?.fun.surface(surface, isShown: true) }
        .onDisappear { model?.fun.surface(surface, isShown: false) }
        .task(id: fun?.peek?.id) {
            // Armed: try now, then every few seconds while this surface shows and the moment may be calm.
            while !Task.isCancelled, let fun, fun.peek != nil {
                if fun.claimPeek(busy: FunQuiet.isBusy() || isBlocked?() == true, edges: edges, owner: owner, surface: surface) != nil {
                    return
                }
                try? await Task.sleep(for: .seconds(6))
            }
        }
    }

    /// The pointer rests on him: after a third of a second he ducks, if he has been out long enough to be seen.
    private func startFuse() {
        cancelFuse()
        fuse = Task {
            try? await Task.sleep(for: .milliseconds(380))
            if !Task.isCancelled {
                model?.fun.duck()
            }
        }
    }

    private func cancelFuse() {
        fuse?.cancel()
        fuse = nil
    }
}

/// The catch: the peeking butler turns into the surprised one in the same spot of his edge, his secret line in a bubble next
/// to him, and the confetti.
struct CaughtPopup: View {
    let caught: FunModel.Catch
    let edge: FunModel.PeekEdge
    /// where along the edge he was
    var along: CGFloat = 0.5
    let level: FunLevel
    /// freezes the confetti at one frame, for the gallery's shots
    var frozenAt: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var appeared = false

    private static let height: CGFloat = 104

    var body: some View {
        let art = PeekArt.caught
        GeometryReader { proxy in
            let size = proxy.size
            let width = Self.height * art.aspect
            ZStack(alignment: .topLeading) {
                ConfettiBurst(
                    level: level, origin: UnitPoint(x: center(size, width).x / max(size.width, 1), y: center(size, width).y / max(size.height, 1)),
                    seed: caught.total, frozenAt: frozenAt)
                group(art, width: width)
                    .fixedSize()
                    .position(center(size, width))
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.55, anchor: Self.anchor(edge))
                    .opacity(appeared || reduceMotion ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.spring(duration: 0.35, bounce: 0.4)) { appeared = true }
        }
    }

    /// the butler and his bubble: the bubble inside of him, so the pair stays in the surface
    @ViewBuilder
    private func group(_ art: PeekArt.Art, width: CGFloat) -> some View {
        let butler = Image(nsImage: art.image)
            .resizable()
            .interpolation(.high)
            .rotationEffect(art.rotation)
            .aspectRatio(art.aspect, contentMode: .fit)
            .frame(width: width, height: Self.height)
        switch edge {
        case .left: HStack(alignment: .center, spacing: 6) { butler; bubble }
        case .right: HStack(alignment: .center, spacing: 6) { bubble; butler }
        case .bottom: VStack(spacing: 6) { bubble; butler }
        case .top: VStack(spacing: 6) { butler; bubble }
        }
    }

    /// the middle of the pair, kept inside the surface and on his spot of the edge
    private func center(_ size: CGSize, _ width: CGFloat) -> CGPoint {
        let pair = CGSize(width: width + 6 + 220, height: Self.height + 6 + 60)
        switch edge {
        case .left, .right:
            let x = edge == .left ? pair.width / 2 + 6 : size.width - pair.width / 2 - 6
            return CGPoint(x: max(pair.width / 2, min(x, size.width - pair.width / 2)), y: max(Self.height / 2 + 6, min(size.height * along, size.height - Self.height / 2 - 6)))
        case .bottom:
            return CGPoint(x: max(pair.width / 2 - 100, min(size.width * along, size.width - pair.width / 2 + 100)), y: size.height - pair.height / 2 - 4)
        case .top:
            return CGPoint(x: max(pair.width / 2 - 100, min(size.width * along, size.width - pair.width / 2 + 100)), y: pair.height / 2 + 4)
        }
    }

    private var bubble: some View {
        VStack(spacing: 2) {
            Text(verbatim: caught.line)
                .font(.callout)
                .multilineTextAlignment(.center)
            if let unlock = caught.unlock {
                Text(verbatim: unlock)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 190)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.12)))
    }

    private static func anchor(_ edge: FunModel.PeekEdge) -> UnitPoint {
        switch edge {
        case .left: .leading
        case .right: .trailing
        case .bottom: .bottom
        case .top: .top
        }
    }
}

extension View {
    /// Lets the peeking butler come out of this surface's edges (the fun layer).
    ///
    /// - Parameters:
    ///   - surface: the kind of surface, which a peek made for the other kind leaves alone
    ///   - edges: the edges he may come out of
    ///   - reveal: how much of him shows, 1 for all of what would
    ///   - drawsFigure: whether the overlay draws him; the pane's panel does it for the pane
    ///   - isBlocked: whether he can't come out now
    func butlerPeek(
        surface: FunModel.PeekSurface = .window, edges: Set<FunModel.PeekEdge> = Set(FunModel.PeekEdge.allCases),
        reveal: CGFloat = 1, drawsFigure: Bool = true, isBlocked: (@MainActor () -> Bool)? = nil
    ) -> some View {
        overlay {
            ButlerPeekOverlay(surface: surface, edges: edges, reveal: reveal, drawsFigure: drawsFigure, isBlocked: isBlocked)
        }
    }
}

/// Whether the user is busy with something that a surprise would disturb: a mouse button held down (a drag), or a text field
/// being edited (typing).
@MainActor
public enum FunQuiet {
    public static func isBusy() -> Bool {
        if NSEvent.pressedMouseButtons != 0 {
            return true
        }
        return (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true
    }
}
