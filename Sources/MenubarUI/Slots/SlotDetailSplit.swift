import MenubarCore
import SwiftUI

/// The Slots section's list with the selected item's detail beside it (SLOT-09): in a window wide enough, a column on the
/// right whose divider drags, its width remembered; in a narrow one, the detail slides in over the list from the right,
/// with a scrim that closes it. Esc and the close button hide it; the button beside it opens the item in a tab.
struct SlotDetailSplit<ListContent: View, DetailContent: View>: View {
    /// whether the detail shows
    let isShown: Bool
    /// what the strip over the detail names, like "#31"
    let title: String
    let close: () -> Void
    /// opens the item in a tab, full window; `nil` shows no button
    var openInTab: (() -> Void)?
    private let list: ListContent
    private let detail: DetailContent

    /// the detail column's width in points, kept across launches
    @AppStorage("slots.detailWidth") private var storedWidth = SlotDetailLayout.idealWidth
    /// the width when a drag began
    @ViewState private var dragBase: Double?
    /// the width the drag asks for, kept apart from the stored one until it ends, so a drag that closes the detail
    /// leaves the last width for the next time
    @ViewState private var dragWidth: Double?

    init(
        isShown: Bool, title: String, close: @escaping () -> Void, openInTab: (() -> Void)? = nil,
        @ViewBuilder list: () -> ListContent, @ViewBuilder detail: () -> DetailContent
    ) {
        self.isShown = isShown
        self.title = title
        self.close = close
        self.openInTab = openInTab
        self.list = list()
        self.detail = detail()
    }

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            if SlotDetailLayout.isSplit(total: total) {
                split(total: total)
            } else {
                overlay(total: total)
            }
        }
    }

    // MARK: Side by side

    private func split(total: CGFloat) -> some View {
        let width = SlotDetailLayout.width(stored: dragWidth ?? storedWidth, total: total)
        let isClosing = dragWidth.map(SlotDetailLayout.closes) ?? false
        return HStack(spacing: 0) {
            list
                .frame(maxWidth: .infinity)
            if isShown {
                divider(width: width, total: total)
                pane
                    .frame(width: width)
                    // Past the minimum the pane fades: letting go closes it.
                    .opacity(isClosing ? 0.4 : 1)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.smooth(duration: 0.22), value: isShown)
        .animation(.smooth(duration: 0.15), value: isClosing)
    }

    /// A hairline with a wider strip to grab, which resizes the column; a double click puts it back to the ideal width,
    /// and dragging it well past the minimum to the right closes the detail, like an inspector collapsing.
    private func divider(width: CGFloat, total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .onTapGesture(count: 2) {
                        storedWidth = Double(SlotDetailLayout.width(stored: SlotDetailLayout.idealWidth, total: total))
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = dragBase ?? Double(width)
                                dragBase = base
                                dragWidth = base - value.translation.width
                            }
                            .onEnded { _ in
                                if let raw = dragWidth {
                                    if SlotDetailLayout.closes(raw) {
                                        close()
                                    } else {
                                        storedWidth = Double(SlotDetailLayout.width(stored: raw, total: total))
                                    }
                                }
                                dragBase = nil
                                dragWidth = nil
                            })
            }
            .accessibilityHidden(true)
    }

    // MARK: Over the list

    private func overlay(total: CGFloat) -> some View {
        ZStack(alignment: .trailing) {
            list
            if isShown {
                Color.black.opacity(0.10)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                    .transition(.opacity)
                    .accessibilityHidden(true)
                pane
                    .frame(width: SlotDetailLayout.overlayWidth(total: total))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 18, x: -4)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.smooth(duration: 0.22), value: isShown)
    }

    // MARK: The detail

    /// The shared strip with the item's name, "Open in a Tab" and the close button, over the detail.
    private var pane: some View {
        DetailPane(title: title, close: close) {
            if let openInTab {
                Button(action: openInTab) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // ⌘↩ sends in the Claude composer inside the detail, so the shortcut adds ⌥.
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .help("Open in a Tab (⌥⌘↩)")
                .accessibilityLabel("Open in a Tab")
            }
        } content: {
            detail
        }
        .background(.windowBackground)
    }
}

/// Where the detail goes and how wide (SLOT-09). Pure, so the tests check the limits.
enum SlotDetailLayout {
    /// the window's content width from which the detail sits beside the list
    static let splitFrom: CGFloat = 840
    static let idealWidth: Double = 480
    static let minimumWidth: CGFloat = 320
    /// how far under the minimum a drag to the right has to go to close the detail
    static let closeDistance: CGFloat = 60
    /// the room the list keeps beside the detail: enough for an item's title and a pill
    static let listMinimum: CGFloat = 300

    static func isSplit(total: CGFloat) -> Bool {
        total >= splitFrom
    }

    /// Returns the detail column's width: the stored one, at least the least, and never so wide that the list falls
    /// under its minimum. There is no other maximum.
    static func width(stored: Double, total: CGFloat) -> CGFloat {
        let most = max(total - listMinimum, minimumWidth)
        return min(max(CGFloat(stored), minimumWidth), most)
    }

    /// Returns whether a drag asking for this width, ended, closes the detail: it is `closeDistance` under the minimum.
    static func closes(_ requested: Double) -> Bool {
        CGFloat(requested) < minimumWidth - closeDistance
    }

    /// Returns the width of the detail that slides over the list: its ideal, but at most most of the window.
    static func overlayWidth(total: CGFloat) -> CGFloat {
        min(CGFloat(idealWidth), total * 0.85)
    }
}

/// What opens a slot's work item in a tab under "Opened", full window: the window sets it, the detail's button, the
/// double click on a row and the menu use it. `nil` in the gallery, so no button shows.
typealias SlotOpenInTab = @MainActor (WorkItem.ID) -> Void

private struct SlotOpenInTabKey: EnvironmentKey {
    static var defaultValue: SlotOpenInTab? { nil }
}

extension EnvironmentValues {
    var slotOpenInTab: SlotOpenInTab? {
        get { self[SlotOpenInTabKey.self] }
        set { self[SlotOpenInTabKey.self] = newValue }
    }
}
