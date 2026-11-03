import MenubarCore
import Observation
import SwiftUI

/// What the Inbox's big panel holds: the events to page through (INBOX-14). The panel's view reads it; the app adds an event
/// when one comes and removes a page when it is dismissed.
@MainActor
@Observable
public final class InboxEventPanelModel {
    public var pages = InboxEventPages()

    public init() {}
}

/// The big panel's content (Task 7.03, INBOX-14): the shown event as an ``InboxEventView``, with the pager above its symbol and
/// Dismiss All next to Dismiss while the panel holds more than one event. The page is as tall as its content; `onSizeChange`
/// tells the window, which keeps its top left corner where it is.
public struct InboxEventPanelView: View {
    let model: InboxEventPanelModel
    let perform: @MainActor (InboxDeliveryAction, InboxEvent) -> Void
    let dismissAll: @MainActor () -> Void
    let onSizeChange: @MainActor (CGSize) -> Void

    /// - Parameters:
    ///   - model: the events
    ///   - perform: runs a button's action for an event; the window then dismisses the page
    ///   - dismissAll: closes the panel
    ///   - onSizeChange: the content's size, when it changed
    public init(
        model: InboxEventPanelModel, perform: @escaping @MainActor (InboxDeliveryAction, InboxEvent) -> Void,
        dismissAll: @escaping @MainActor () -> Void, onSizeChange: @escaping @MainActor (CGSize) -> Void
    ) {
        self.model = model
        self.perform = perform
        self.dismissAll = dismissAll
        self.onSizeChange = onSizeChange
    }

    public var body: some View {
        if let event = model.pages.current {
            InboxEventView(event: event, pager: pager) { action in
                perform(action, event)
            }
            .id(event.id)
            .onGeometryChange(for: CGSize.self, of: \.size) { onSizeChange($0) }
            // Pinned to the top: while the window changes its height, the page doesn't slide.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var pager: AlertPager? {
        guard model.pages.count > 1 else {
            return nil
        }
        let model = model
        return AlertPager(
            position: model.pages.position, hasPrevious: model.pages.hasPrevious, hasNext: model.pages.hasNext,
            previous: { model.pages.previous() }, next: { model.pages.next() }, dismissAll: dismissAll)
    }
}

/// One event in the big panel, in the look of the failed-build alert: a symbol where the butler is, the reference chip, the
/// headline, the target's title, a line, and the buttons: Show, Done, Snooze 1 Hour and Dismiss. The coffee break
/// wears a ☕ on a warm disc and has no Show and no Snooze (its Done says "On My Way ☕"). 320 pt wide; the height fits the content.
public struct InboxEventView: View {
    let event: InboxEvent
    let pager: AlertPager?
    let perform: (InboxDeliveryAction) -> Void
    @Environment(\.colorScheme) private var colorScheme

    public init(event: InboxEvent, pager: AlertPager? = nil, perform: @escaping (InboxDeliveryAction) -> Void) {
        self.event = event
        self.pager = pager
        self.perform = perform
    }

    private var isCoffee: Bool { event.kind == .coffeeBreak }
    /// whether there is somewhere to go: the coffee break and a local item without a link have none
    private var canShow: Bool { event.targetURL != nil }
    private var entry: InboxEntry { InboxEntry(event: event) }

    public var body: some View {
        let look = Look(event)
        VStack(spacing: 0) {
            if let pager {
                AlertPagerBar(pager: pager)
                    .padding(.bottom, 4)
            }
            InboxEventSymbol(look: look)
            if let reference = InboxRowModel.reference(of: entry) {
                ReferenceChip(kind: reference.kind, text: reference.text)
                    .padding(.top, 12)
            }
            Text(verbatim: look.headline)
                .font(.title3)
                .bold()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            if let subtitle = look.subtitle {
                Text(verbatim: subtitle)
                    .lineLimit(3)
                    .padding(.top, 4)
            }
            if let line = look.line {
                Text(verbatim: line)
                    .font(.callout)
                    .foregroundStyle(.alertGrey)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            VStack(spacing: 8) {
                if canShow {
                    button(.show, isDefault: true)
                }
                if event.kind.canSnooze {
                    HStack(spacing: 8) {
                        button(.done, isDefault: !canShow)
                        button(.snooze)
                    }
                } else {
                    // The coffee break can't be snoozed: Done is the one way to take it, full width.
                    button(.done, isDefault: !canShow)
                }
                if let pager {
                    HStack(spacing: 8) {
                        button(.dismiss)
                        Button("Dismiss All", action: pager.dismissAll)
                            .controlSize(.large)
                            .buttonSizing(.flexible)
                            .frame(maxWidth: .infinity)
                            .background { plainFill }
                    }
                } else {
                    button(.dismiss)
                }
            }
            .padding(.top, 20)
        }
        .multilineTextAlignment(.center)
        .padding([.horizontal, .bottom], 20)
        .padding(.top, 20)
        .frame(width: BuildAlertView.width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            // The same tint over the glass as the build alert's, so the white text stands out over a light window.
            RoundedRectangle(cornerRadius: BuildAlertView.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(colorScheme == .dark ? BuildAlertView.darkTint : BuildAlertView.lightTint))
        }
    }

    private func button(_ action: InboxDeliveryAction, isDefault: Bool = false) -> some View {
        Button(action.panelTitle(for: event.kind)) {
            perform(action)
        }
        .controlSize(.large)
        .buttonSizing(.flexible)
        .frame(maxWidth: .infinity)
        .background {
            if !isDefault {
                plainFill
            }
        }
        .keyboardShortcut(isDefault ? .defaultAction : action == .dismiss ? .cancelAction : nil)
    }

    private var plainFill: some View {
        Capsule().fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0))
    }

    /// The words and the symbol of an event in the panel.
    struct Look {
        var symbol: String
        var tint: InboxRowModel.Tint
        /// the coffee break's emoji, in the symbol's place
        var emoji: String?
        var headline: String
        /// the target's title; `nil` for none
        var subtitle: String?
        /// a line under it: Claude's first line, or the coffee break's line
        var line: String?

        init(_ event: InboxEvent) {
            let entry = InboxEntry(event: event)
            (symbol, tint) = InboxRowModel.symbol(of: entry)
            emoji = event.kind == .coffeeBreak ? "☕" : nil
            switch event.kind {
            case .coffeeBreak:
                headline = "Coffee Break"
                subtitle = event.excerpt
                line = nil
            default:
                headline = event.headline
                // A local item's title is the thing it is about; for the digest it repeats the headline.
                subtitle = event.title.isEmpty || event.title == headline ? nil : event.title
                line = event.excerpt
            }
        }
    }
}

/// The picture at the top of an event's page: the kind's symbol on a disc in its color, or the coffee break's ☕ on a warm
/// glowing disc, where the build alert has its butler.
struct InboxEventSymbol: View {
    let look: InboxEventView.Look
    static let size: CGFloat = 96

    var body: some View {
        let color = look.emoji == nil ? look.tint.color : Color(red: 0.93, green: 0.55, blue: 0.22)
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [color.opacity(0.95), color.opacity(0.55)], center: .topLeading, startRadius: 4,
                        endRadius: Self.size))
            Circle()
                .strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
            if let emoji = look.emoji {
                Text(verbatim: emoji)
                    .font(.system(size: 54))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            } else {
                Image(systemName: look.symbol)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .shadow(color: color.opacity(0.45), radius: 14, y: 4)
        .accessibilityHidden(true)
    }
}
