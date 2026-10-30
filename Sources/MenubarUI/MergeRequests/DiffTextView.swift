import AppKit
import MenubarCore
import SwiftUI

// MARK: - Look

/// The diff's fonts and colors in AppKit, so that the text of a diff can be selected like any editor's.
@MainActor
enum DiffAppearance {
    static let fontSize: CGFloat = 11.5
    static let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    /// a character's advance in the monospaced font
    static let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
    /// a line's height: the font's and a point of air, as the rows of the SwiftUI diff had
    static let lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
    /// a hunk header's height: the band's padding on top
    static let headerHeight = lineHeight + 4

    static let added = dynamic(.green)
    static let removed = dynamic(.red)
    static let blue = dynamic(.blue)

    /// the color of the status color's light or dark value, by the appearance it draws in
    static func dynamic(_ color: MergeRequestStatus.Color) -> NSColor {
        let light = NSColor(hex: color.light)
        let dark = NSColor(hex: color.dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// the tint of an added or removed line
    static func tint(_ change: DiffLine.Kind?) -> NSColor? {
        switch change {
        case .added: added
        case .removed: removed
        case .context, nil: nil
        }
    }

    static func paragraphStyle(height: CGFloat, spacing: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        style.paragraphSpacing = spacing
        style.lineBreakMode = .byWordWrapping
        style.defaultTabInterval = advance * 4
        style.tabStops = []
        return style
    }

    /// The column's rows as one attributed text: the code in its syntax colors, the changed part on a stronger tint.
    static func attributedText(of column: DiffTextDocument.Column) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lineStyle = paragraphStyle(height: lineHeight)
        let headerStyle = paragraphStyle(height: headerHeight)
        for row in column.rows {
            let style = row.kind == .header ? headerStyle : lineStyle
            if row.kind == .header {
                result.append(NSAttributedString(string: row.text + "\n", attributes: [
                    .font: font, .foregroundColor: blue.withAlphaComponent(0.9), .paragraphStyle: style,
                ]))
                continue
            }
            let tint = tint(row.change)
            for segment in row.segments where !segment.text.isEmpty {
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: segment.token?.nsColor ?? NSColor.labelColor, .paragraphStyle: style,
                ]
                if segment.isChanged, let tint {
                    attributes[.backgroundColor] = tint.withAlphaComponent(0.32)
                }
                result.append(NSAttributedString(string: segment.text, attributes: attributes))
            }
            result.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
        }
        return result
    }
}

// MARK: - The text view of a column

/// One column of a diff: a read-only text view that draws the rows' tints and the line numbers behind and beside the
/// code. Its text is the code alone.
final class DiffTextView: NSTextView {
    var column = 0
    weak var surface: DiffSurface?

    override var isFlipped: Bool { true }

    override func drawBackground(in rect: NSRect) {
        surface?.drawBackdrop(of: self, in: rect)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if surface?.gutterMouseDown(in: self, event: event) == true {
            return
        }
        // The tracking loop of the drag runs in here, so the selection is whole when this returns.
        super.mouseDown(with: event)
        surface?.selectionSettled(in: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // The line numbers press and drag to select lines.
        if let surface {
            addCursorRect(NSRect(x: 0, y: 0, width: surface.textOrigin(in: self), height: bounds.height), cursor: .pointingHand)
        }
    }

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        surface?.hover(in: self, at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        surface?.hover(in: self, at: nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        surface?.addAskItems(to: menu, in: self, at: convert(event.locationInWindow, from: nil))
        return menu
    }

    override func scrollWheel(with event: NSEvent) {
        // Sideways where the code is wider than the diff; a vertical wheel keeps scrolling the page.
        if let surface, surface.scrollsSideways, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            surface.scroll(sidewaysBy: -event.scrollingDeltaX)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    override func scrollToVisible(_ rect: NSRect) -> Bool {
        // A selection dragged past the edge scrolls the long lines along; the page takes the vertical part.
        surface?.reveal(horizontally: rect)
        return super.scrollToVisible(rect)
    }

    override func copy(_ sender: Any?) {
        guard let code = surface?.selectedCode(in: self) else {
            super.copy(sender)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}

// MARK: - The surface

/// A file's diff in text views, inline or side by side: the row geometry, the number gutters, the selection and its
/// "Ask Claude" button and menu items (AI-07). It sizes itself to its content, for the lazy list of files.
final class DiffSurface: NSView, NSTextViewDelegate {
    @MainActor
    private final class Column {
        let text: DiffTextView
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer()
        /// the column's text before the paragraph spacing that lines the two columns up
        var base = NSAttributedString()

        init(index: Int, surface: DiffSurface) {
            storage.addLayoutManager(layoutManager)
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            layoutManager.addTextContainer(container)
            text = DiffTextView(frame: .zero, textContainer: container)
            text.column = index
            text.surface = surface
            text.delegate = surface
            text.isEditable = false
            text.isSelectable = true
            text.isRichText = true
            text.drawsBackground = false
            text.isVerticallyResizable = false
            text.isHorizontallyResizable = false
            text.usesFontPanel = false
            text.isAutomaticLinkDetectionEnabled = false
            text.displaysLinkToolTips = false
            text.textContainerInset = .zero
        }
    }

    // MARK: Inputs

    private(set) var document = DiffTextDocument.empty
    private var path = ""
    private var hunks: [DiffHunk] = []
    private var contentKey: ContentKey?
    /// the lines picked by their numbers, in this file
    private var lineSelection: DiffSelection?
    private var pickedIDs: Set<DiffLineID> = []
    /// whether the Claude features are on: the button, the menu items and the number clicks
    private var asks: ((CodeScope) -> Void)?
    private var pickLine: ((DiffLineID) -> Void)?
    private var clearLinePick: () -> Void = {}
    private var textOwnerChanged: (Bool) -> Void = { _ in }
    /// whether this file's text selection is the one the card knows
    private var isTextOwner = false

    private struct ContentKey: Equatable {
        var hunks: [DiffHunk]
        var stamp: Int
        var layout: DiffLayoutChoice
        var limit: Int
        var path: String
    }

    // MARK: Layout state

    private var columns: [Column] = []
    private(set) var rowTops: [CGFloat] = [0]
    private var laidOutWidth: CGFloat?
    /// the inline diff's width, which its longest line sets
    private var contentWidth: CGFloat = 0
    private var scrollX: CGFloat = 0
    private var columnFrames: [NSRect] = []
    private let indicator = DiffScrollIndicator()
    private var fadeTask: Task<Void, Never>?
    private var height: CGFloat = 0
    /// where a line's baseline is below its row's top, to draw the numbers on the code's baseline
    private var baseline: CGFloat = DiffAppearance.font.ascender
    private let pill = NSHostingView(rootView: DiffAskPill(title: "", ask: {}, clear: {}))
    private var textPick: (pick: DiffTextDocument.TextPick, span: LineSpan, column: Int)?
    private var isClearing = false
    /// the row whose line number the mouse is over
    private var hoverRow: (column: Int, row: Int)?

    private static let sidePadding: CGFloat = 12

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        pill.sizingOptions = [.intrinsicContentSize]
        pill.isHidden = true
        indicator.isHidden = true
        addSubview(indicator)
        addSubview(pill)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var canPickLines: Bool { pickLine != nil }

    // MARK: Updating

    /// Takes what the SwiftUI side says: rebuilds the text when the content changed, otherwise only redraws.
    func update(
        hunks: [DiffHunk], styled: [[StyledLine]]?, stamp: Int, path: String, layout: DiffLayoutChoice, limit: Int,
        lineSelection: DiffSelection?, isTextOwner: Bool, asks: ((CodeScope) -> Void)?, pickLine: ((DiffLineID) -> Void)?,
        clearLinePick: @escaping () -> Void, textOwnerChanged: @escaping (Bool) -> Void
    ) {
        self.asks = asks
        self.pickLine = pickLine
        self.clearLinePick = clearLinePick
        self.textOwnerChanged = textOwnerChanged
        self.isTextOwner = isTextOwner
        let key = ContentKey(hunks: hunks, stamp: stamp, layout: layout, limit: limit, path: path)
        if key != contentKey {
            contentKey = key
            self.hunks = hunks
            self.path = path
            let styled =
                styled ?? hunks.map { $0.lines.map { StyledLine(line: $0, segments: [.init(text: $0.text)]) } }
            rebuild(DiffTextDocument.make(hunks: hunks, styled: styled, layout: layout, limit: limit))
        }
        if lineSelection != self.lineSelection {
            self.lineSelection = lineSelection
            pickedIDs = Set(lineSelection?.lines(in: hunks).map(DiffLineID.init) ?? [])
            needsDisplay(allColumns: true)
        }
        // Another file's selection, or a pick of lines, took over: this file's selection goes.
        if !isTextOwner, textPick != nil || columns.contains(where: { $0.text.selectedRange().length > 0 }),
            NSEvent.pressedMouseButtons & 1 == 0
        {
            clearTextSelection()
        }
        updatePill()
    }

    private func rebuild(_ document: DiffTextDocument) {
        clearTextSelection(quietly: true)
        self.document = document
        while columns.count < document.columns.count {
            let column = Column(index: columns.count, surface: self)
            columns.append(column)
            addSubview(column.text, positioned: .below, relativeTo: pill)
        }
        while columns.count > document.columns.count {
            columns.removeLast().text.removeFromSuperview()
        }
        for (column, source) in zip(columns, document.columns) {
            column.base = DiffAppearance.attributedText(of: source)
            column.storage.setAttributedString(column.base)
        }
        laidOutWidth = nil
        invalidateIntrinsicContentSize()
    }

    private func needsDisplay(allColumns: Bool) {
        for column in columns {
            column.text.needsDisplay = true
        }
    }

    // MARK: Sizing

    /// Lays the text out for a width and returns the height it needs.
    func fit(width: CGFloat) -> CGFloat {
        if laidOutWidth != width {
            layoutColumns(width: width)
        }
        return height
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        if laidOutWidth != width {
            layoutColumns(width: width)
        }
        placeColumns()
        updatePill()
        indicator.isHidden = true
    }

    private func layoutColumns(width: CGFloat) {
        needsLayout = true
        laidOutWidth = width
        contentWidth = width
        guard !columns.isEmpty else {
            return
        }
        switch document.layout {
        case .inline:
            let column = columns[0]
            let origin = Self.inlineOrigin(gutter: gutter)
            column.container.size = NSSize(width: 10_000_000, height: 10_000_000)
            column.layoutManager.ensureLayout(for: column.container)
            let measured = measure(column, rows: document.columns[0])
            let textWidth = max(width, origin + measured.width + 24)
            rowTops = measured.tops
            column.text.textContainerInset = NSSize(width: origin, height: 0)
            height = rowTops.last ?? 0
            contentWidth = textWidth
            measureBaseline(column, rows: document.columns[0], tops: rowTops)
        case .sideBySide:
            let half = ((width - 1) / 2).rounded(.down)
            let origin = Self.sideOrigin(gutter: gutter)
            for column in columns {
                column.storage.setAttributedString(column.base)
                column.container.size = NSSize(width: max(half - origin - Self.sidePadding, 40), height: 10_000_000)
                column.text.textContainerInset = NSSize(width: origin, height: 0)
                column.layoutManager.ensureLayout(for: column.container)
            }
            var perColumn = zip(columns, document.columns).map { measure($0, rows: $1).tops }
            let count = document.rowCount
            var spaced = false
            for row in 0..<count {
                let tallest = perColumn.map { $0[row + 1] - $0[row] }.max() ?? 0
                for (index, column) in columns.enumerated() {
                    let extra = tallest - (perColumn[index][row + 1] - perColumn[index][row])
                    if extra > 0.5 {
                        spaced = true
                        let style = DiffAppearance.paragraphStyle(
                            height: document.columns[index].rows[row].kind == .header
                                ? DiffAppearance.headerHeight : DiffAppearance.lineHeight, spacing: extra)
                        column.storage.addAttribute(
                            .paragraphStyle, value: style, range: document.columns[index].range(ofRow: row))
                    }
                }
            }
            if spaced {
                for column in columns {
                    column.layoutManager.ensureLayout(for: column.container)
                }
                perColumn = zip(columns, document.columns).map { measure($0, rows: $1).tops }
            }
            rowTops = perColumn[0]
            height = rowTops.last ?? 0
            measureBaseline(columns[0], rows: document.columns[0], tops: rowTops)
        }
    }

    private func placeColumns() {
        guard !columns.isEmpty else {
            return
        }
        let width = bounds.width
        switch document.layout {
        case .inline:
            scrollX = min(max(scrollX, 0), maxScroll)
            columnFrames = [NSRect(x: 0, y: 0, width: width, height: height)]
            columns[0].text.frame = NSRect(x: -scrollX, y: 0, width: contentWidth, height: height)
        case .sideBySide:
            let half = ((width - 1) / 2).rounded(.down)
            columnFrames = [
                NSRect(x: 0, y: 0, width: half, height: height),
                NSRect(x: half + 1, y: 0, width: width - half - 1, height: height),
            ]
            for (column, frame) in zip(columns, columnFrames) {
                column.text.frame = frame
            }
        }
    }

    // MARK: Scrolling sideways

    /// whether the inline diff has code wider than its width
    var scrollsSideways: Bool { document.layout == .inline && maxScroll > 0 }

    private var maxScroll: CGFloat { max(contentWidth - bounds.width, 0) }

    /// Scrolls the inline diff sideways and shows its scroll bar for a moment.
    func scroll(sidewaysBy delta: CGFloat) {
        let target = min(max(scrollX + delta, 0), maxScroll)
        guard target != scrollX else {
            return
        }
        scrollX = target
        columns.first?.text.setFrameOrigin(NSPoint(x: -scrollX, y: 0))
        updateIndicator()
    }

    /// Scrolls sideways just far enough to show a rectangle of the text view.
    func reveal(horizontally rect: NSRect) {
        guard scrollsSideways else {
            return
        }
        if rect.maxX > scrollX + bounds.width {
            scroll(sidewaysBy: rect.maxX - scrollX - bounds.width)
        } else if rect.minX < scrollX {
            scroll(sidewaysBy: rect.minX - scrollX)
        }
    }

    private func updateIndicator() {
        let track = max(bounds.width - 8, 0)
        guard maxScroll > 0, track > 0 else {
            indicator.isHidden = true
            return
        }
        let thumb = max(track * bounds.width / contentWidth, 24)
        let x = 4 + (track - thumb) * (scrollX / maxScroll)
        indicator.frame = NSRect(x: x, y: max(height - 7, 0), width: thumb, height: 4)
        indicator.isHidden = false
        indicator.alphaValue = 1
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else {
                return
            }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0.3
            self?.indicator.animator().alphaValue = 0
            NSAnimationContext.endGrouping()
        }
    }

    /// Each row's top in the column's layout, then the bottom of the last row, and the width of the longest line.
    private func measure(_ column: Column, rows source: DiffTextDocument.Column) -> (tops: [CGFloat], width: CGFloat) {
        let manager = column.layoutManager
        var tops: [CGFloat] = []
        var bottom: CGFloat = 0
        var width: CGFloat = 0
        for index in source.rows.indices {
            let range = manager.glyphRange(forCharacterRange: source.range(ofRow: index), actualCharacterRange: nil)
            guard range.length > 0 else {
                tops.append(bottom)
                continue
            }
            let first = manager.lineFragmentRect(forGlyphAt: range.location, effectiveRange: nil)
            let last = manager.lineFragmentRect(forGlyphAt: range.location + range.length - 1, effectiveRange: nil)
            tops.append(first.minY)
            bottom = last.maxY
            width = max(width, manager.lineFragmentUsedRect(forGlyphAt: range.location + range.length - 1, effectiveRange: nil).maxX)
        }
        tops.append(bottom)
        return (tops, width)
    }

    private func measureBaseline(_ column: Column, rows source: DiffTextDocument.Column, tops: [CGFloat]) {
        guard let index = source.rows.firstIndex(where: { $0.kind == .line }) else {
            return
        }
        let manager = column.layoutManager
        let range = manager.glyphRange(forCharacterRange: source.range(ofRow: index), actualCharacterRange: nil)
        guard range.length > 0 else {
            return
        }
        let fragment = manager.lineFragmentRect(forGlyphAt: range.location, effectiveRange: nil)
        baseline = fragment.minY + manager.location(forGlyphAt: range.location).y - tops[index]
    }

    /// the digits' width of the widest line number
    private var gutter: CGFloat {
        let widest = hunks.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 1
        return CGFloat(max(2, String(widest).count)) * DiffAppearance.advance + 10
    }

    private static let signWidth: CGFloat = 14

    /// where the code starts: both numbers and the sign
    private static func inlineOrigin(gutter: CGFloat) -> CGFloat { gutter * 2 + signWidth + 4 }

    /// where the code starts in a side-by-side column: its number and the sign
    private static func sideOrigin(gutter: CGFloat) -> CGFloat { gutter + signWidth + 2 }

    func textOrigin(in view: DiffTextView) -> CGFloat {
        document.layout == .inline ? Self.inlineOrigin(gutter: gutter) : Self.sideOrigin(gutter: gutter)
    }

    // MARK: Drawing

    /// Draws what is behind the code of a column: the rows' tints, the picked lines, the line numbers and signs.
    func drawBackdrop(of view: DiffTextView, in dirty: NSRect) {
        guard document.columns.indices.contains(view.column), rowTops.count == document.rowCount + 1,
            let first = DiffTextDocument.row(at: dirty.minY, tops: rowTops)
        else {
            return
        }
        let source = document.columns[view.column]
        let gutter = gutter
        let plainNumbers = numberAttributes(picked: false)
        let pickedNumbers = numberAttributes(picked: true)
        for index in first..<source.rows.count where rowTops[index] <= dirty.maxY {
            let row = source.rows[index]
            let rect = NSRect(x: 0, y: rowTops[index], width: view.bounds.width, height: rowTops[index + 1] - rowTops[index])
            let isPicked = row.id.map(pickedIDs.contains) ?? false
            switch row.kind {
            case .header:
                DiffAppearance.blue.withAlphaComponent(0.07).setFill()
                rect.fill()
            case .blank:
                NSColor.quaternaryLabelColor.withAlphaComponent(0.05).setFill()
                rect.fill()
            case .line:
                if let tint = DiffAppearance.tint(row.change) {
                    tint.withAlphaComponent(0.12).setFill()
                    rect.fill()
                }
            }
            if isPicked {
                NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
                rect.fill()
            }
            if let hoverRow, hoverRow.column == view.column, hoverRow.row == index {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSRect(x: 0, y: rect.minY, width: textOrigin(in: view), height: rect.height).fill()
            }
            guard row.kind == .line else {
                continue
            }
            let y = rowTops[index] + baseline - DiffAppearance.font.ascender
            let attributes = isPicked ? pickedNumbers : plainNumbers
            let numbers: [Int?] =
                document.layout == .inline ? [row.oldNumber, row.newNumber] : [view.column == 0 ? row.oldNumber : row.newNumber]
            for (slot, number) in numbers.enumerated() {
                if let number {
                    let box = NSRect(x: CGFloat(slot) * gutter, y: y, width: gutter - 2, height: DiffAppearance.lineHeight)
                    (String(number) as NSString).draw(in: box, withAttributes: attributes)
                }
            }
            let signX = CGFloat(numbers.count) * gutter
            let sign = row.change == .added ? "+" : row.change == .removed ? "−" : " "
            (sign as NSString).draw(
                at: NSPoint(x: signX + 2, y: y),
                withAttributes: [
                    .font: DiffAppearance.font,
                    .foregroundColor: DiffAppearance.tint(row.change) ?? NSColor.secondaryLabelColor,
                ])
            if row.noNewlineAtEnd {
                drawNoNewlineMark(of: row, at: index, in: view, y: y)
            }
        }
        if document.layout == .sideBySide, view.column == 1 {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: dirty.minY, width: 0.5, height: dirty.height).fill()
        }
    }

    private func numberAttributes(picked: Bool) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        return [
            .font: picked ? NSFont.monospacedSystemFont(ofSize: DiffAppearance.fontSize, weight: .semibold) : DiffAppearance.font,
            .foregroundColor: picked ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor,
            .paragraphStyle: style,
        ]
    }

    /// ⊘ after the code of a line the file ends on without a newline
    private func drawNoNewlineMark(of row: DiffTextDocument.Row, at index: Int, in view: DiffTextView, y: CGFloat) {
        let column = columns[view.column]
        let source = document.columns[view.column]
        let range = column.layoutManager.glyphRange(forCharacterRange: source.range(ofRow: index), actualCharacterRange: nil)
        guard range.length > 1 else {
            return
        }
        let used = column.layoutManager.lineFragmentUsedRect(forGlyphAt: range.location + range.length - 2, effectiveRange: nil)
        ("⊘" as NSString).draw(
            at: NSPoint(x: used.maxX + textOrigin(in: view) + 6, y: y),
            withAttributes: [.font: DiffAppearance.font, .foregroundColor: NSColor.secondaryLabelColor])
    }

    // MARK: Clicks on line numbers

    /// A press on a line number: a click picks the line by its number (Shift extends the pick), a drag selects whole lines
    /// from the first to the line under the mouse, like a drag in the text, scrolling the page near its edges.
    ///
    /// - Returns: `false` when the press isn't on a line number, which leaves it to the text
    func gutterMouseDown(in view: DiffTextView, event: NSEvent) -> Bool {
        let start = view.convert(event.locationInWindow, from: nil)
        guard start.x < textOrigin(in: view) - Self.signWidth, document.columns.indices.contains(view.column),
            let anchor = DiffTextDocument.row(at: start.y, tops: rowTops),
            document.columns[view.column].rows[anchor].kind == .line, let window = view.window
        else {
            return false
        }
        window.makeFirstResponder(view)
        var dragged = false
        var latest = event
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            if next.type == .leftMouseUp {
                break
            }
            if next.type == .leftMouseDragged {
                latest = next
            }
            view.autoscroll(with: latest)
            let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard let row = DiffTextDocument.row(at: point.y, tops: rowTops) else {
                continue
            }
            dragged = dragged || row != anchor
            if dragged {
                view.setSelectedRange(document.characters(ofRows: anchor, row, inColumn: view.column))
            }
        }
        if dragged {
            selectionSettled(in: view)
        } else if let pickLine, let id = document.columns[view.column].rows[anchor].id {
            pickLine(id)
        } else {
            view.setSelectedRange(document.characters(ofRows: anchor, anchor, inColumn: view.column))
            selectionSettled(in: view)
        }
        return true
    }

    /// Lights the row of the line number under the mouse, so that the numbers show they can be pressed.
    func hover(in view: DiffTextView, at point: NSPoint?) {
        var next: (column: Int, row: Int)?
        if let point, point.x < textOrigin(in: view) - Self.signWidth, document.columns.indices.contains(view.column),
            let row = DiffTextDocument.row(at: point.y, tops: rowTops), document.columns[view.column].rows[row].kind == .line
        {
            next = (view.column, row)
        }
        guard next?.column != hoverRow?.column || next?.row != hoverRow?.row else {
            return
        }
        for spot in [hoverRow, next] {
            if let spot, columns.indices.contains(spot.column), rowTops.indices.contains(spot.row + 1) {
                columns[spot.column].text.setNeedsDisplay(
                    NSRect(x: 0, y: rowTops[spot.row], width: textOrigin(in: view), height: rowTops[spot.row + 1] - rowTops[spot.row]))
            }
        }
        hoverRow = next
    }

    private func line(in view: DiffTextView, atY y: CGFloat) -> DiffTextDocument.Row? {
        guard let index = DiffTextDocument.row(at: y, tops: rowTops), document.columns.indices.contains(view.column) else {
            return nil
        }
        let row = document.columns[view.column].rows[index]
        return row.kind == .line ? row : nil
    }

    // MARK: Selection

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isClearing, let view = notification.object as? DiffTextView else {
            return
        }
        // One selection at a time: the other column's goes.
        if view.selectedRange().length > 0 {
            isClearing = true
            for other in columns where other.text !== view && other.text.selectedRange().length > 0 {
                other.text.setSelectedRange(NSRange(location: 0, length: 0))
            }
            isClearing = false
        }
        // While the mouse drags, the button waits for the end of the drag.
        if NSEvent.pressedMouseButtons & 1 == 0 {
            selectionSettled(in: view)
        }
    }

    func selectionSettled(in view: DiffTextView) {
        let range = view.selectedRange()
        if range.length > 0, let pick = document.pick(of: range, inColumn: view.column, path: path),
            let span = pick.selection.span(in: hunks)
        {
            textPick = (pick, span, view.column)
            if !isTextOwner {
                isTextOwner = true
                textOwnerChanged(true)
            }
        } else if textPick != nil, !columns.contains(where: { $0.text.selectedRange().length > 0 }) {
            textPick = nil
            if isTextOwner {
                isTextOwner = false
                textOwnerChanged(false)
            }
        }
        updatePill()
    }

    private func clearTextSelection(quietly: Bool = false) {
        isClearing = true
        for column in columns where column.text.selectedRange().length > 0 {
            column.text.setSelectedRange(NSRange(location: 0, length: 0))
        }
        isClearing = false
        let owned = textPick != nil
        textPick = nil
        if owned, !quietly, isTextOwner {
            isTextOwner = false
            textOwnerChanged(false)
        }
        updatePill()
    }

    /// The code ⌘C copies: the selected lines without numbers, signs and hunk headers.
    func selectedCode(in view: DiffTextView) -> String? {
        let range = view.selectedRange()
        guard range.length > 0, document.columns.indices.contains(view.column) else {
            return nil
        }
        let code = document.code(in: range, inColumn: view.column)
        return code.isEmpty ? nil : code
    }

    // MARK: Menu

    /// Adds "Ask Claude About Selection…" on top of the standard menu where the click is in the selection, and "Ask
    /// Claude About This Line…" for the line under the click otherwise.
    func addAskItems(to menu: NSMenu, in view: DiffTextView, at point: NSPoint) {
        guard let asks else {
            return
        }
        var items: [NSMenuItem] = []
        let selectedRows = textPick.flatMap { $0.column == view.column ? $0.pick.rows : nil }
        let clickedRow = DiffTextDocument.row(at: point.y, tops: rowTops)
        if let textPick, let selectedRows, let clickedRow, selectedRows.contains(clickedRow) {
            let (selection, span) = (textPick.pick.selection, textPick.span)
            items.append(MenuAction.item("Ask Claude About Selection…") { asks(.lines(selection, span)) })
        } else if let row = line(in: view, atY: point.y), let id = row.id {
            let single = DiffSelection(path: path, anchor: id, head: id)
            if let span = single.span(in: hunks) {
                items.append(MenuAction.item("Ask Claude About This Line…") { asks(.lines(single, span)) })
            }
        }
        guard !items.isEmpty else {
            return
        }
        for (offset, item) in (items + [.separator()]).enumerated() {
            menu.insertItem(item, at: offset)
        }
    }

    // MARK: The button

    /// Shows, hides and places the button: by the text selection, or by the last line picked by its number.
    private func updatePill() {
        guard let asks, !columns.isEmpty else {
            pill.isHidden = true
            return
        }
        let target: (selection: DiffSelection, span: LineSpan, row: Int, column: Int, isText: Bool)?
        if let textPick {
            target = (textPick.pick.selection, textPick.span, textPick.pick.rows.upperBound, textPick.column, true)
        } else if let lineSelection, let span = lineSelection.span(in: hunks), let last = lastPickedRow() {
            target = (lineSelection, span, last.row, last.column, false)
        } else {
            target = nil
        }
        guard let target, target.row + 1 < rowTops.count, laidOutWidth != nil, columnFrames.indices.contains(target.column) else {
            pill.isHidden = true
            return
        }
        let title = target.span.buttonTitle
        let clear: () -> Void = { [weak self] in
            if target.isText {
                self?.clearTextSelection()
            } else {
                self?.clearLinePick()
            }
        }
        pill.rootView = DiffAskPill(title: title, ask: { asks(.lines(target.selection, target.span)) }, clear: clear)
        let size = pill.intrinsicContentSize
        let columnFrame = columnFrames[target.column]
        let rowHeight = rowTops[target.row + 1] - rowTops[target.row]
        let x = max(columnFrame.maxX - size.width - 6, columnFrame.minX)
        // Centered on the row, kept inside the diff.
        let y = min(max(rowTops[target.row] + (rowHeight - size.height) / 2, 0), max(height - size.height, 0))
        pill.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        pill.isHidden = false
    }

    /// the last row of the lines picked by their numbers, and the column it is in; the new file's side by side
    private func lastPickedRow() -> (row: Int, column: Int)? {
        var best: (row: Int, column: Int)?
        for (column, source) in document.columns.enumerated() {
            if let row = source.rows.lastIndex(where: { $0.id.map(pickedIDs.contains) ?? false }),
                row >= (best?.row ?? -1)
            {
                best = (row, column)
            }
        }
        return best
    }
}

/// The thin bar that shows how far the inline diff is scrolled sideways.
private final class DiffScrollIndicator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A menu item that runs a closure.
private final class MenuAction: NSObject {
    let run: () -> Void

    init(run: @escaping () -> Void) {
        self.run = run
    }

    @objc func perform(_ sender: Any?) {
        run()
    }

    static func item(_ title: String, run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run: run)
        let item = NSMenuItem(title: title, action: #selector(perform(_:)), keyEquivalent: "")
        item.target = action
        // The item keeps its action alive.
        item.representedObject = action
        return item
    }
}

/// The floating button by a selection: "Ask Claude About Lines 12–30…" and a small clear button (AI-07).
struct DiffAskPill: View {
    let title: String
    let ask: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: ask) {
                Label("Ask Claude About \(title)…", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .controlSize(.small)
            Button(action: clear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Clear the selection")
            .accessibilityLabel("Clear the Selection")
        }
        .font(.system(size: 12))
        .padding(.leading, 3)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay { Capsule().strokeBorder(.separator, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
        .fixedSize()
        .padding(6)
    }
}

// MARK: - In SwiftUI

/// A file's diff in text views, in the size its rows need at the width it gets.
struct DiffSurfaceView: NSViewRepresentable {
    let hunks: [DiffHunk]
    /// the hunks' lines styled, once the styling is done; plain before
    let styled: [[StyledLine]]?
    /// changes when `styled` does, which is cheaper to compare
    let stamp: Int
    let path: String
    let layout: DiffLayoutChoice
    let limit: Int
    /// the lines picked by their numbers
    var lineSelection: DiffSelection?
    var isTextOwner = false
    /// opens the sheet; `nil` while the Claude features are off
    var asks: ((CodeScope) -> Void)?
    /// picks a line by a click on its number; `nil` leaves the numbers plain
    var pickLine: ((DiffLineID) -> Void)?
    var clearLinePick: () -> Void = {}
    var textOwnerChanged: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> DiffSurface {
        DiffSurface(frame: .zero)
    }

    func updateNSView(_ surface: DiffSurface, context: Context) {
        surface.update(
            hunks: hunks, styled: styled, stamp: stamp, path: path, layout: layout, limit: limit,
            lineSelection: lineSelection, isTextOwner: isTextOwner, asks: asks, pickLine: pickLine,
            clearLinePick: clearLinePick, textOwnerChanged: textOwnerChanged)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView surface: DiffSurface, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 600
        return CGSize(width: width, height: surface.fit(width: width))
    }
}

extension CodeToken {
    /// Xcode's default theme, its light and its dark color
    var nsColor: NSColor {
        switch self {
        case .keyword: Self.color(light: 0x9B2393, dark: 0xFC5FA3)
        case .string: Self.color(light: 0xC41A16, dark: 0xFC6A5D)
        case .comment: Self.color(light: 0x5D6C79, dark: 0x7F8C98)
        case .number: Self.color(light: 0x1C00CF, dark: 0xD0BF69)
        case .type: Self.color(light: 0x0B4F79, dark: 0x5DD8FF)
        case .attribute: Self.color(light: 0x815F03, dark: 0xFD8F3F)
        }
    }

    private static func color(light: UInt32, dark: UInt32) -> NSColor {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let light = ns(light)
        let dark = ns(dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
