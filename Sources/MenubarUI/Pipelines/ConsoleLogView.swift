import AppKit
import MenubarCore
import Observation
import SwiftUI

// MARK: - Look

/// The console log's fonts and colors in AppKit (PIPE-12): a terminal's palette, tuned for a light and a dark window.
@MainActor
enum ConsoleLogAppearance {
    static let fontSize: CGFloat = 11.5
    static let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    static let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
    /// one line's height, the same for every line, so the line numbers sit where the lines are
    static let lineHeight = ceil(font.ascender - font.descender + font.leading) + 3

    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byClipping
        style.defaultTabInterval = advance * 8
        style.tabStops = []
        return style
    }()

    /// the log's ground: a touch darker than the card in dark, a faint grey in light
    static let background = dynamic(light: 0xFAFAFB, dark: 0x16171A)
    static let gutter = dynamic(light: 0xF2F2F4, dark: 0x1C1D21)
    static let text = dynamic(light: 0x24262B, dark: 0xD7D9DE)
    static let pipeline = dynamic(light: 0x9A9DA6, dark: 0x6E727C)
    static let number = dynamic(light: 0xA3A6AE, dark: 0x5E626B)
    static let errorText = dynamic(light: 0xC4302B, dark: 0xFF7B72)
    static let warningText = dynamic(light: 0x9A6200, dark: 0xE3B341)
    static let successText = dynamic(light: 0x1A7F37, dark: 0x56D364)
    static let errorBand = dynamic(light: 0xFF3B30, dark: 0xFF453A, alpha: (0.08, 0.13))
    static let warningBand = dynamic(light: 0xFF9F0A, dark: 0xFFB340, alpha: (0.08, 0.10))
    static let successBand = dynamic(light: 0x34C759, dark: 0x30D158, alpha: (0.07, 0.09))
    static let currentBand = dynamic(light: 0xFF3B30, dark: 0xFF453A, alpha: (0.18, 0.26))
    /// the line a click on a stage jumped to: blue, since it is no error
    static let stageBand = dynamic(light: 0x0A84FF, dark: 0x409CFF, alpha: (0.18, 0.28))

    /// The color of a light and a dark hex value, by the appearance it draws in.
    static func dynamic(light: UInt32, dark: UInt32, alpha: (CGFloat, CGFloat) = (1, 1)) -> NSColor {
        let lightColor = rgb(light).withAlphaComponent(alpha.0)
        let darkColor = rgb(dark).withAlphaComponent(alpha.1)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// the 16 ANSI colors, light and dark: VS Code's terminal palette, with black and white kept readable on the ground
    private static let palette: [NSColor] = {
        let light: [UInt32] = [
            0x24262B, 0xCD3131, 0x10893E, 0x949800, 0x0451A5, 0xBC05BC, 0x0598BC, 0x6E7079,
            0x666666, 0xE5484D, 0x14A44D, 0xB58900, 0x2F6FEB, 0xC23CC2, 0x0AA3C2, 0x8A8D96,
        ]
        let dark: [UInt32] = [
            0x8B8F98, 0xF14C4C, 0x23D18B, 0xE5E510, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xD7D9DE,
            0x9DA1AA, 0xFF6B6B, 0x4AE3A0, 0xF5F543, 0x5CA8FF, 0xE48CE4, 0x4CC9E8, 0xFFFFFF,
        ]
        return zip(light, dark).map { dynamic(light: $0, dark: $1) }
    }()

    private static let cubeLevels: [CGFloat] = [0, 95, 135, 175, 215, 255]

    static func color(_ color: ConsoleLogColor) -> NSColor {
        switch color {
        case .indexed(let index) where index < 16:
            return palette[Int(index)]
        case .indexed(let index) where index < 232:
            let cube = Int(index) - 16
            return NSColor(
                srgbRed: cubeLevels[cube / 36] / 255, green: cubeLevels[(cube / 6) % 6] / 255,
                blue: cubeLevels[cube % 6] / 255, alpha: 1)
        case .indexed(let index):
            let grey = CGFloat(8 + 10 * (Int(index) - 232)) / 255
            return NSColor(srgbRed: grey, green: grey, blue: grey, alpha: 1)
        case .rgb(let red, let green, let blue):
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    static func band(_ kind: ConsoleLogLineKind) -> NSColor? {
        switch kind {
        case .error: errorBand
        case .warning: warningBand
        case .success: successBand
        case .plain, .pipeline: nil
        }
    }

    static func lineColor(_ kind: ConsoleLogLineKind) -> NSColor? {
        switch kind {
        case .error: errorText
        case .warning: warningText
        case .success: successText
        case .pipeline: pipeline
        case .plain: nil
        }
    }

    /// A slice as attributed text: the lines' kinds tint them, the ANSI runs go over that.
    static func attributed(_ slice: ConsoleLogSlice) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: slice.text, attributes: [.font: font, .foregroundColor: text, .paragraphStyle: paragraph])
        result.beginEditing()
        let count = slice.lineCount
        for line in 0..<count {
            guard let color = lineColor(slice.kinds[line]) else { continue }
            let start = slice.lineStarts[line]
            let end = line + 1 < count ? slice.lineStarts[line + 1] : slice.utf16Count
            result.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: end - start))
        }
        for run in slice.runs {
            result.addAttributes(attributes(of: run.style), range: NSRange(location: run.location, length: run.length))
        }
        result.endEditing()
        return result
    }

    private static func attributes(of style: ConsoleLogStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        var foreground = style.foreground.map(color)
        var background = style.background.map { color($0).withAlphaComponent(0.85) }
        if style.traits.contains(.inverse) {
            (foreground, background) = (background ?? self.background, foreground ?? text)
        }
        if style.traits.contains(.faint) {
            foreground = (foreground ?? text).withAlphaComponent(0.6)
        }
        if let foreground {
            attributes[.foregroundColor] = foreground
        }
        if let background {
            attributes[.backgroundColor] = background
        }
        if style.traits.contains(.bold) {
            attributes[.font] = boldFont
        }
        if style.traits.contains(.italic) {
            attributes[.obliqueness] = 0.18
        }
        if style.traits.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.traits.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }
}

// MARK: - The text view

/// The log's read-only text view: TextKit 1 with non-contiguous layout, so only what shows is laid out; the error,
/// warning and success lines get a band across the whole width. ⌘F opens the find bar.
final class ConsoleLogTextView: NSTextView {
    weak var controller: ConsoleLogController?

    /// The colors are dynamic and resolve as they draw, so a switch of Settings → Appearance only needs a redraw: the
    /// text, the bands and the line numbers.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let layoutManager, let length = textStorage?.length, length > 0 {
            layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: length))
        }
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let controller, let layoutManager, let textContainer, !controller.kinds.isEmpty else { return }
        let origin = textContainerOrigin
        let local = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: local, in: textContainer)
        let current = controller.currentErrorLine
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let line = controller.line(at: layoutManager.characterIndexForGlyph(at: range.location))
            let kind = controller.kinds[line]
            let marked = controller.currentIsStage ? ConsoleLogAppearance.stageBand : ConsoleLogAppearance.currentBand
            let color = line == current ? marked : ConsoleLogAppearance.band(kind)
            guard let color else { return }
            color.setFill()
            NSRect(x: rect.minX, y: fragment.minY + origin.y, width: rect.width, height: fragment.height).fill(using: .sourceOver)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "f":
                controller?.showFind()
                return true
            case "g":
                finderAction(.nextMatch)
                return true
            default:
                break
            }
        }
        if window?.firstResponder === self, flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "g" {
            finderAction(.previousMatch)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func finderAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
    }
}

/// The line numbers beside the log, drawn for the visible lines only; an error line's number is red.
final class ConsoleLogRuler: NSRulerView {
    weak var controller: ConsoleLogController?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Views don't clip to their bounds since macOS 14: the dirty rect may reach over the log.
        let rect = dirtyRect.intersection(bounds)
        ConsoleLogAppearance.gutter.setFill()
        rect.fill()
        NSColor.separatorColor.withAlphaComponent(0.3).setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        drawHashMarksAndLabels(in: rect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let controller, let textView = controller.textView, let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer, !controller.kinds.isEmpty
        else { return }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let base = controller.linesBefore ?? 0
        let known = controller.linesBefore != nil
        let width = bounds.width - 8
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let line = controller.line(at: layoutManager.characterIndexForGlyph(at: range.location))
            let y = self.convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
            let isError = controller.kinds[line] == .error
            let color: NSColor =
                isError ? ConsoleLogAppearance.errorText : ConsoleLogAppearance.number.withAlphaComponent(known ? 1 : 0.7)
            let number = String(base + line + 1) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: ConsoleLogAppearance.numberFont, .foregroundColor: color]
            let size = number.size(withAttributes: attributes)
            // On the line's own baseline, where the glyphs sit in their fixed-height fragment.
            let baseline = layoutManager.location(forGlyphAt: range.location).y
            number.draw(
                at: NSPoint(x: width - size.width, y: y + baseline - ConsoleLogAppearance.numberFont.ascender),
                withAttributes: attributes)
        }
    }
}

// MARK: - The controller

/// One viewer of a loaded log, the card's or the Full Log window's: its scroll view, text view and line numbers, the
/// blocks it shows, and the actions of the card's toolbar (jump between errors, find, copy).
///
/// The loader's blocks change only at their ends, so an update removes and adds whole blocks at the top or the bottom
/// and keeps what shows in place: at the end while following the end, at the same line after a page above was added.
@Observable @MainActor
final class ConsoleLogController {
    /// which loaded error the last jump went to, from 1
    private(set) var currentError: Int?

    @ObservationIgnored private(set) var textView: ConsoleLogTextView?
    @ObservationIgnored private var scrollView: NSScrollView?
    @ObservationIgnored private var ruler: ConsoleLogRuler?
    @ObservationIgnored private var shown: [(id: Int, length: Int)] = []
    /// where each shown line starts, in UTF-16 code units
    @ObservationIgnored private(set) var lineStarts: [Int] = []
    @ObservationIgnored private(set) var kinds: [ConsoleLogLineKind] = []
    @ObservationIgnored private var errorLines: [Int] = []
    /// the shown blocks' first lines, by block id, for a jump to a line of a block
    @ObservationIgnored private var firstLines: [Int: Int] = [:]
    /// a line to show once its block is in the text view
    @ObservationIgnored private var pendingReveal: ConsoleLogLocation?
    /// counts the jumps, so that the scroll to the end a first update schedules doesn't undo one
    @ObservationIgnored private var revealGeneration = 0
    @ObservationIgnored private(set) var linesBefore: Int?
    @ObservationIgnored private(set) var currentErrorLine: Int?
    /// whether the lit line is a stage's first line, not an error
    @ObservationIgnored private(set) var currentIsStage = false
    @ObservationIgnored nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []
    /// called when the reader scrolls to the top or the bottom, to load the next page
    @ObservationIgnored var reachedTop: () -> Void = {}
    @ObservationIgnored var reachedBottom: () -> Void = {}

    func makeScrollView() -> NSScrollView {
        if let scrollView {
            return scrollView
        }
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        // No layout of the whole text while idle: a long log would keep a core busy for nothing.
        layoutManager.backgroundLayoutEnabled = false
        storage.addLayoutManager(layoutManager)
        // Wide enough for any line, and far from the float limits that break the layout's arithmetic.
        let container = NSTextContainer(size: NSSize(width: 10_000_000, height: 10_000_000_000))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let text = ConsoleLogTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        text.controller = self
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.usesFontPanel = false
        text.importsGraphics = false
        text.allowsUndo = false
        text.isAutomaticLinkDetectionEnabled = false
        text.displaysLinkToolTips = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.drawsBackground = true
        text.backgroundColor = ConsoleLogAppearance.background
        text.textContainerInset = NSSize(width: 10, height: 8)
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: 10_000_000, height: 10_000_000_000)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = true
        // As wide and tall as the view at least, so the bands reach across; wider for a long line.
        text.autoresizingMask = [.width, .height]
        text.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        text.font = ConsoleLogAppearance.font
        text.typingAttributes = [.font: ConsoleLogAppearance.font, .paragraphStyle: ConsoleLogAppearance.paragraph]

        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = ConsoleLogAppearance.background
        scroll.borderType = .noBorder
        scroll.findBarPosition = .aboveContent
        let ruler = ConsoleLogRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clipsToBounds = true
        ruler.controller = self
        ruler.clientView = text
        ruler.reservedThicknessForMarkers = 0
        ruler.reservedThicknessForAccessoryView = 0
        ruler.ruleThickness = Self.gutterWidth(digits: 4)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true

        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) {
                [weak ruler] _ in
                MainActor.assumeIsolated {
                    ruler?.needsDisplay = true
                }
            })
        observers.append(
            center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scrolled()
                }
            })
        textView = text
        scrollView = scroll
        self.ruler = ruler
        return scroll
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private static func gutterWidth(digits: Int) -> CGFloat {
        ceil(CGFloat(max(digits, 3)) * ConsoleLogAppearance.advance * 0.95) + 18
    }

    // MARK: Updating

    /// Shows the loader's blocks: removes and adds whole blocks at the ends, and keeps the reader's place.
    func update(blocks: [ConsoleLogBlock], linesBefore: Int?) {
        guard let textView, let storage = textView.textStorage else { return }
        let numbersChanged = linesBefore != self.linesBefore
        self.linesBefore = linesBefore
        let newIDs = blocks.map(\.id)
        let oldIDs = shown.map(\.id)
        guard newIDs != oldIDs else {
            if numbersChanged {
                ruler?.needsDisplay = true
            }
            return
        }
        let wasEmpty = shown.isEmpty
        let wasAtBottom = isAtBottom
        let anchor = wasEmpty ? nil : topAnchor()

        let newSet = Set(newIDs)
        let firstKept = oldIDs.firstIndex { newSet.contains($0) }
        let lastKept = oldIDs.lastIndex { newSet.contains($0) }
        var removedAbove = 0
        var addedAbove = 0
        storage.beginEditing()
        if let firstKept, let lastKept, let newFirst = newIDs.firstIndex(of: oldIDs[firstKept]),
            let newLast = newIDs.firstIndex(of: oldIDs[lastKept]),
            Array(oldIDs[firstKept...lastKept]) == Array(newIDs[newFirst...newLast])
        {
            let below = shown[(lastKept + 1)...].reduce(0) { $0 + $1.length }
            if below > 0 {
                storage.deleteCharacters(in: NSRange(location: storage.length - below, length: below))
            }
            removedAbove = shown[..<firstKept].reduce(0) { $0 + $1.length }
            if removedAbove > 0 {
                storage.deleteCharacters(in: NSRange(location: 0, length: removedAbove))
            }
            let above = NSMutableAttributedString()
            for block in blocks[..<newFirst] {
                above.append(ConsoleLogAppearance.attributed(block.slice))
            }
            addedAbove = above.length
            storage.insert(above, at: 0)
            for block in blocks[(newLast + 1)...] {
                storage.append(ConsoleLogAppearance.attributed(block.slice))
            }
        } else {
            let all = NSMutableAttributedString()
            for block in blocks {
                all.append(ConsoleLogAppearance.attributed(block.slice))
            }
            storage.setAttributedString(all)
        }
        storage.endEditing()
        shown = blocks.map { ($0.id, $0.slice.utf16Count) }
        rebuildLines(blocks)
        defer { applyPendingReveal() }
        if removedAbove > 0 || addedAbove > 0 {
            // The lines above changed: the next jump starts from what shows.
            currentErrorLine = nil
            currentError = nil
        }
        updateGutterWidth()

        if wasEmpty || wasAtBottom {
            scrollToEnd()
        } else if let anchor {
            restore(anchor, shift: addedAbove - removedAbove)
        }
        ruler?.needsDisplay = true
    }

    private func rebuildLines(_ blocks: [ConsoleLogBlock]) {
        var starts: [Int] = []
        var kinds: [ConsoleLogLineKind] = []
        let count = blocks.reduce(0) { $0 + $1.slice.lineCount }
        starts.reserveCapacity(count)
        kinds.reserveCapacity(count)
        var offset = 0
        var firstLines: [Int: Int] = [:]
        for block in blocks {
            firstLines[block.id] = starts.count
            for start in block.slice.lineStarts {
                starts.append(offset + start)
            }
            kinds.append(contentsOf: block.slice.kinds)
            offset += block.slice.utf16Count
        }
        lineStarts = starts
        self.firstLines = firstLines
        self.kinds = kinds
        errorLines = kinds.indices.filter { kinds[$0] == .error }
    }

    private func updateGutterWidth() {
        let digits = String((linesBefore ?? 0) + kinds.count).count
        let width = Self.gutterWidth(digits: digits)
        if let ruler, ruler.ruleThickness != width {
            ruler.ruleThickness = width
        }
    }

    /// Returns the line a character is in.
    func line(at character: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        guard high >= 0 else { return 0 }
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= character {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    private func range(ofLine line: Int) -> NSRange {
        let start = lineStarts[line]
        var end = line + 1 < lineStarts.count ? lineStarts[line + 1] : (textView?.textStorage?.length ?? start)
        // Without the line break, so the jump lights the text only.
        if end > start, let storage = textView?.textStorage, (storage.string as NSString).character(at: end - 1) == 0x0A {
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Scrolling

    private var isAtBottom: Bool {
        guard let scrollView, let document = scrollView.documentView else { return true }
        let visible = scrollView.contentView.bounds
        return visible.maxY >= document.frame.height - ConsoleLogAppearance.lineHeight * 2
    }

    private struct Anchor {
        var character: Int
        var offset: CGFloat
    }

    private func topAnchor() -> Anchor? {
        guard let scrollView, let textView, let layoutManager = textView.layoutManager,
            let container = textView.textContainer, textView.textStorage?.length ?? 0 > 0
        else { return nil }
        let origin = textView.textContainerOrigin
        let top = scrollView.contentView.bounds.minY
        let point = NSPoint(x: 0, y: max(0, top - origin.y))
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return Anchor(character: layoutManager.characterIndexForGlyph(at: glyph), offset: top - (fragment.minY + origin.y))
    }

    private func restore(_ anchor: Anchor, shift: Int) {
        guard let scrollView, let textView, let layoutManager = textView.layoutManager,
            let storage = textView.textStorage, storage.length > 0
        else { return }
        let character = min(max(0, anchor.character + shift), storage.length - 1)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: character, length: 1))
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let y = fragment.minY + textView.textContainerOrigin.y + anchor.offset
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: max(0, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func scrollToEnd() {
        guard let textView else { return }
        textView.scrollToEndOfDocument(nil)
        // Again once the view has its size, as on the first update, unless a jump to a line came meanwhile.
        let generation = revealGeneration
        DispatchQueue.main.async { [weak self, weak textView] in
            MainActor.assumeIsolated {
                if self?.revealGeneration == generation {
                    textView?.scrollToEndOfDocument(nil)
                }
            }
        }
    }

    private func scrolled() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let visible = scrollView.contentView.bounds
        if visible.minY <= ConsoleLogAppearance.lineHeight {
            reachedTop()
        } else if visible.maxY >= document.frame.height - ConsoleLogAppearance.lineHeight {
            reachedBottom()
        }
    }

    // MARK: The toolbar's actions

    /// the number of loaded error lines
    var errorCount: Int { errorLines.count }

    /// Jumps to the next error line below the last jump or the top of the view, or back to the first.
    func nextError() {
        jump(forward: true)
    }

    func previousError() {
        jump(forward: false)
    }

    private func jump(forward: Bool) {
        guard !errorLines.isEmpty, let textView, let scrollView, let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else { return }
        let from: Int
        if let currentErrorLine {
            from = currentErrorLine
        } else {
            let origin = textView.textContainerOrigin
            let point = NSPoint(x: 0, y: max(0, scrollView.contentView.bounds.midY - origin.y))
            from = line(at: layoutManager.characterIndexForGlyph(at: layoutManager.glyphIndex(for: point, in: container)))
        }
        let index: Int
        if forward {
            index = errorLines.firstIndex { $0 > from } ?? 0
        } else {
            index = errorLines.lastIndex { $0 < from } ?? (errorLines.count - 1)
        }
        show(line: errorLines[index], errorNumber: index + 1)
    }

    /// Shows a line of the log in the middle of the view, lit like the current error.
    ///
    /// Asked before the line's block is in the text view, as when its page was just loaded, it waits for the update that
    /// brings it.
    ///
    /// - Parameter location: the line, by its block
    func reveal(_ location: ConsoleLogLocation) {
        pendingReveal = location
        revealGeneration += 1
        applyPendingReveal()
    }

    private func applyPendingReveal() {
        guard let location = pendingReveal, let first = firstLines[location.blockID] else { return }
        let line = first + location.line
        guard line < lineStarts.count else { return }
        pendingReveal = nil
        show(line: line, errorNumber: nil)
        // Again once the view has its size: a first layout may still move the text.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if let self, self.currentErrorLine == line {
                    self.show(line: line, errorNumber: nil)
                }
            }
        }
    }

    private func show(line: Int, errorNumber: Int?) {
        guard let textView, let scrollView, let layoutManager = textView.layoutManager,
            let container = textView.textContainer, line < lineStarts.count
        else { return }
        currentErrorLine = line
        currentError = errorNumber
        currentIsStage = errorNumber == nil
        let range = range(ofLine: line)
        layoutManager.ensureLayout(forCharacterRange: range)
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let y = rect.midY + textView.textContainerOrigin.y - scrollView.contentView.bounds.height / 2
        let top = max(0, min(y, textView.frame.height - scrollView.contentView.bounds.height))
        // Unscrolled sideways, the clip view's origin is minus the width of the line numbers beside it, not 0.
        let left = -(scrollView.verticalRulerView?.ruleThickness ?? 0)
        scrollView.contentView.scroll(to: NSPoint(x: left, y: top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.needsDisplay = true
        ruler?.needsDisplay = true
        textView.showFindIndicator(for: range)
        // The indicator may scroll sideways to its range; a line starts at the left edge.
        scrollView.contentView.scroll(to: NSPoint(x: left, y: top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Opens the find bar over the log, for the loaded text.
    func showFind() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.finderAction(.showFindInterface)
    }

    /// Puts the loaded text on the clipboard, the selection when there is one.
    func copy() {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let text = selection.length > 0 ? (storage.string as NSString).substring(with: selection) : storage.string
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// whether some text is selected, which Copy copies instead of all
    var hasSelection: Bool { (textView?.selectedRange().length ?? 0) > 0 }
}

// MARK: - In SwiftUI

/// The log's text in SwiftUI: the controller's scroll view, fed the loader's blocks.
struct ConsoleLogTextArea: NSViewRepresentable {
    let controller: ConsoleLogController
    let blocks: [ConsoleLogBlock]
    let linesBefore: Int?
    var reachedTop: () -> Void = {}
    var reachedBottom: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        controller.makeScrollView()
    }

    /// Whatever room it gets: the log scrolls inside, so its length never sizes the card.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 320)
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        controller.reachedTop = reachedTop
        controller.reachedBottom = reachedBottom
        controller.update(blocks: blocks, linesBefore: linesBefore)
    }
}
