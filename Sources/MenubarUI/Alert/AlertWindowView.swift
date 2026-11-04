import MenubarCore
import Observation
import SwiftUI

/// What the alert window holds (ALERT-03, INBOX-14): the finished builds' alerts and the Inbox events delivered as pop-ups,
/// newest first. The window's view reads it; the app adds an item when one comes and removes it when it is dismissed.
@MainActor
@Observable
public final class AlertWindowModel {
    public var items = AlertWindowItems()
    /// why GitLab refused a Done, by event id: the event's page stays and says it
    public var refusals: [String: Problem] = [:]
    /// the events whose Done is waiting for GitLab's answer, so a second click doesn't send it twice
    public var busy: Set<String> = []
    /// where the butler gets his hat; the gallery fixes it
    public var hatSource = ButlerHatSource.today

    public init() {}
}

/// The alert window's content: one item shows as its own pop-up, a ``BuildAlertView`` or an ``InboxEventView``, with a bigger
/// butler and its own height; two or more show as one ``AlertSummaryView`` with a list and "Open Inbox" (the user,
/// 2026-11-04). `onSizeChange` tells the window, which keeps its top left corner where it is.
public struct AlertWindowView: View {
    let model: AlertWindowModel
    let rebuildWithChanges: (@MainActor (BuildAlert) -> Void)?
    let perform: @MainActor (BuildAlert, AlertContent.Action) -> Void
    let performEvent: @MainActor (InboxDeliveryAction, InboxEvent) -> Void
    let openItem: @MainActor (AlertWindowItem) -> Void
    let openInbox: @MainActor () -> Void
    let dismissAll: @MainActor () -> Void
    let onSizeChange: @MainActor (CGSize) -> Void

    /// - Parameters:
    ///   - model: the items
    ///   - rebuildWithChanges: opens the sheet of "Rebuild with Changes…" for a build and dismisses its alert
    ///   - perform: runs a button's action for a build's alert; the window then dismisses it
    ///   - performEvent: runs a button's action for an event; the window then dismisses it
    ///   - openItem: opens a summary row's build or event in the app; the window then removes the row
    ///   - openInbox: opens the Inbox; the window then closes
    ///   - dismissAll: closes the window
    ///   - onSizeChange: the content's size, when it changed
    public init(
        model: AlertWindowModel, rebuildWithChanges: (@MainActor (BuildAlert) -> Void)?,
        perform: @escaping @MainActor (BuildAlert, AlertContent.Action) -> Void,
        performEvent: @escaping @MainActor (InboxDeliveryAction, InboxEvent) -> Void,
        openItem: @escaping @MainActor (AlertWindowItem) -> Void, openInbox: @escaping @MainActor () -> Void,
        dismissAll: @escaping @MainActor () -> Void, onSizeChange: @escaping @MainActor (CGSize) -> Void
    ) {
        self.model = model
        self.rebuildWithChanges = rebuildWithChanges
        self.perform = perform
        self.performEvent = performEvent
        self.openItem = openItem
        self.openInbox = openInbox
        self.dismissAll = dismissAll
        self.onSizeChange = onSizeChange
    }

    public var body: some View {
        content
            .onGeometryChange(for: CGSize.self, of: \.size) { onSizeChange($0) }
            // Pinned to the top: while the window changes its height, the page doesn't slide.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        if let item = model.items.single {
            switch item.payload {
            case .build(let alert, let notificationsOff):
                BuildAlertView(
                    alert: alert, notificationsOff: notificationsOff,
                    rebuildWithChanges: rebuildWithChanges.map { open in { open(alert) } }
                ) { action in
                    perform(alert, action)
                }
                .id(item.id)
            case .event(let event):
                InboxEventView(
                    event: event, refusal: model.refusals[event.id], isBusy: model.busy.contains(event.id), hatSource: model.hatSource
                ) { action in
                    performEvent(action, event)
                }
                .id(item.id)
            }
        } else if let summary = AlertSummary.make(model.items.items) {
            AlertSummaryView(
                summary: summary, hatSource: model.hatSource, openItem: openItem, openInbox: openInbox, dismissAll: dismissAll)
        }
    }
}

/// The window with two or more items: the butler (sad for all failures, happy for all good news, the shrugging one of
/// `mixed.png` for a mix, in the season's art, else the caught butler), a title, a list with one row per item, and Open Inbox and Dismiss All. A row opens its build or item in the app and
/// goes; the details of every pop-up live in the Inbox. The list shows ``AlertSummary/visibleRows`` rows and scrolls beyond,
/// with half a row more showing so the scrolling is no secret. A little wider than the single pop-ups (360 pt), so a title
/// next to the reference keeps some words.
public struct AlertSummaryView: View {
    let summary: AlertSummary
    let hatSource: ButlerHatSource
    let openItem: (AlertWindowItem) -> Void
    let openInbox: () -> Void
    let dismissAll: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// a row's height: one line, so the list's height is known without measuring it
    static let rowHeight: CGFloat = 34

    /// the summary's width, wider than the pop-ups' 320 pt
    public static let width: CGFloat = 360

    /// Returns the list's height: a row each up to ``AlertSummary/visibleRows``, then those and half a row of the next.
    ///
    /// - Parameter rows: how many rows the summary has
    static func listHeight(rows: Int) -> CGFloat {
        let visible = CGFloat(AlertSummary.visibleRows)
        return rows > AlertSummary.visibleRows ? (visible + 0.5) * rowHeight : CGFloat(rows) * rowHeight
    }

    public init(
        summary: AlertSummary, hatSource: ButlerHatSource = .today, openItem: @escaping (AlertWindowItem) -> Void,
        openInbox: @escaping () -> Void, dismissAll: @escaping () -> Void
    ) {
        self.summary = summary
        self.hatSource = hatSource
        self.openItem = openItem
        self.openInbox = openInbox
        self.dismissAll = dismissAll
    }

    public var body: some View {
        VStack(spacing: 0) {
            butler
            Text(verbatim: summary.title)
                .font(.title3)
                .bold()
                .multilineTextAlignment(.center)
                .padding(.top, 12)
            list
                .padding(.top, 14)
            VStack(spacing: 8) {
                Button("Open Inbox", action: openInbox)
                    .controlSize(.large)
                    .buttonSizing(.flexible)
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut(.defaultAction)
                Button("Dismiss All", action: dismissAll)
                    .controlSize(.large)
                    .buttonSizing(.flexible)
                    .frame(maxWidth: .infinity)
                    .background { Capsule().fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0)) }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 18)
        }
        .padding([.horizontal, .bottom], 20)
        .padding(.top, 20)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            // The same tint over the glass as the single pop-ups'.
            RoundedRectangle(cornerRadius: BuildAlertView.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(colorScheme == .dark ? BuildAlertView.darkTint : BuildAlertView.lightTint))
        }
    }

    /// The butler of the summary, in the season's hat for the sad and the happy one. The mixed one has the season's art
    /// (`mixed-halloween`, `mixed-santa`, `mixed-carnival`, `mixed-easter`; else `mixed.png`, else the caught butler) and no hat
    /// drawn over it.
    private var butler: some View {
        let hat = hatSource.hat
        let level = FunModel.currentLevel.flatMap { $0.showsMoments ? $0 : nil }
        let icon: AlertContent.Icon = summary.butler == .happy ? .happy : .sad
        let art: NSImage = switch summary.butler {
        case .sad, .happy: AppImages.alert(icon, hat: hat)
        case .mixed: AppImages.mixed(hat: hat)
        }
        return ButlerStage(
            art: art, icon: icon, hat: summary.butler == .mixed ? nil : hat, level: summary.butler == .mixed ? nil : level,
            behind: { EmptyView() }
        )
        .accessibilityHidden(true)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(summary.rows) { item in
                    AlertSummaryRow(item: item) { openItem(item) }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDisabled(summary.rows.count <= AlertSummary.visibleRows)
        .frame(height: Self.listHeight(rows: summary.rows.count))
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One row of the summary: the status symbol in its color, the reference, the short title on one line, and a quiet detail.
/// A click opens the item in the app.
struct AlertSummaryRow: View {
    let item: AlertWindowItem
    let open: () -> Void
    @ViewState private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                symbol
                    .frame(width: 18)
                if let reference = item.summaryReference {
                    referenceView(reference)
                        .layoutPriority(1)
                }
                Text(verbatim: item.summaryTitle)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail = item.summaryDetail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.alertGrey)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: AlertSummaryView.rowHeight)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(isHovering ? 0.08 : 0))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(item.summaryTitle)
    }

    @ViewBuilder private var symbol: some View {
        switch item.payload {
        case .build(let alert, _):
            let state = BuildAlertView.state(of: alert.content.result)
            Image(systemName: state.symbol)
                .foregroundStyle(state.color ?? .secondary)
        case .event(let event):
            let look = InboxRowModel.symbol(of: InboxEntry(event: event))
            Image(systemName: look.0)
                .foregroundStyle(look.1.color)
        }
    }

    /// the reference as the app's chip, green "!" and blue "#"; a branch build's label stays plain text
    @ViewBuilder private func referenceView(_ text: String) -> some View {
        if text.hasPrefix("!") {
            ReferenceChip(kind: .mergeRequest, text: text)
        } else if text.hasPrefix("#") {
            ReferenceChip(kind: .workItem, text: text)
        } else {
            Text(verbatim: text)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 110)
                .fixedSize()
        }
    }
}
