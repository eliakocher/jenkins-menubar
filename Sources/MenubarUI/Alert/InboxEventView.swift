import MenubarCore
import SwiftUI

/// One event in the pop-up, in the look of the failed-build alert: the butler (sad for a failure, happy for the rest, with
/// the season's hat) with the kind's symbol in a badge at his corner, the reference chip, the headline, the target's
/// title, a line, and the buttons: Show, Done, Snooze 1 Hour and Dismiss. The coffee break wears the butler sipping a
/// coffee (a ☕ on a warm disc without the art), bigger so his face matches the others', and has one button, "On My Way ☕"
/// (the Done): no Show, no Snooze, no Dismiss, and Esc does nothing. 320 pt wide;
/// the height fits the content. With two or more events (or builds) the window shows an ``AlertSummaryView`` instead.
public struct InboxEventView: View {
    let event: InboxEvent
    /// why GitLab refused the Done, shown above the buttons
    let refusal: Problem?
    /// whether a Done is waiting for GitLab's answer
    let isBusy: Bool
    let hatSource: ButlerHatSource
    let perform: (InboxDeliveryAction) -> Void
    @Environment(\.colorScheme) private var colorScheme

    public init(
        event: InboxEvent, refusal: Problem? = nil, isBusy: Bool = false, hatSource: ButlerHatSource = .today,
        perform: @escaping (InboxDeliveryAction) -> Void
    ) {
        self.event = event
        self.refusal = refusal
        self.isBusy = isBusy
        self.hatSource = hatSource
        self.perform = perform
    }

    /// whether there is somewhere to go: the coffee break and a local item without a link have none
    private var canShow: Bool { event.targetURL != nil }
    private var entry: InboxEntry { InboxEntry(event: event) }

    public var body: some View {
        let look = Look(event, hatSource: hatSource)
        VStack(spacing: 0) {
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
            if let refusal {
                RefusalNote(text: refusal.message)
                    .padding(.top, 12)
            }
            VStack(spacing: 8) {
                let buttons = Self.buttons(for: event)
                if buttons.contains(.show) {
                    button(.show, isDefault: true)
                }
                if buttons.contains(.snooze) {
                    HStack(spacing: 8) {
                        button(.done, isDefault: !canShow)
                        button(.snooze)
                    }
                } else {
                    // The coffee break can't be snoozed or dismissed: Done is the one way to take it, full width.
                    button(.done, isDefault: !canShow)
                }
                if buttons.contains(.dismiss) {
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

    /// Returns the buttons of an event's pop-up: Show where there is somewhere to go, Done, Snooze 1 Hour where the kind can
    /// be snoozed, and Dismiss. The coffee break has Done alone ("On My Way ☕"): it is never snoozed or dismissed.
    ///
    /// - Parameter event: the event
    /// - Returns: the actions, in the order the buttons show
    static func buttons(for event: InboxEvent) -> [InboxDeliveryAction] {
        if event.kind == .coffeeBreak {
            return [.done]
        }
        var actions: [InboxDeliveryAction] = []
        if event.targetURL != nil {
            actions.append(.show)
        }
        actions.append(.done)
        if event.kind.canSnooze {
            actions.append(.snooze)
        }
        actions.append(.dismiss)
        return actions
    }

    private func button(_ action: InboxDeliveryAction, isDefault: Bool = false) -> some View {
        Button(action.panelTitle(for: event.kind)) {
            perform(action)
        }
        .controlSize(.large)
        .buttonSizing(.flexible)
        .frame(maxWidth: .infinity)
        .disabled(isBusy && action == .done)
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
        /// whether the butler is the sad one: a failure
        var isSad: Bool
        /// the hat the butler wears, the season's; `nil` for none
        var hat: ButlerHat?
        var headline: String
        /// the target's title; `nil` for none
        var subtitle: String?
        /// a line under it: Claude's first line, or the coffee break's line
        var line: String?

        @MainActor init(_ event: InboxEvent, hatSource: ButlerHatSource = .today) {
            let entry = InboxEntry(event: event)
            (symbol, tint) = InboxRowModel.symbol(of: entry)
            emoji = event.kind == .coffeeBreak ? "☕" : nil
            isSad = Self.sad(for: event)
            hat = hatSource.hat
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

extension InboxEventView.Look {
    /// Returns whether an event gets the sad butler: a failed pipeline or build, changes requested on my merge request, and
    /// a Claude answer that is a failure. Every other kind gets the happy one.
    ///
    /// - Parameter event: the event
    /// - Returns: `true` for the sad butler
    static func sad(for event: InboxEvent) -> Bool {
        event.isFailure
    }
}

/// A Done that GitLab refused, on the page: a tinted note with the reason, above the buttons, which stay for another try.
private struct RefusalNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(MergeRequestStatus.Color.orange.swiftUI)
            Text(verbatim: text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            MergeRequestStatus.Color.orange.swiftUI.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The picture at the top of an event's page, where the build alert has its butler: the same butler in the same stage, sad for a failure and happy for the rest, in the season's hat, with the kind's
/// symbol on a small disc in its color at his bottom right corner. The coffee break has its own butler
/// (``AppImages/coffee``; a ☕ on a warm glowing disc without the file), at the same size.
struct InboxEventSymbol: View {
    let look: InboxEventView.Look
    static var size: CGFloat { ButlerStage<EmptyView, EmptyView>.artBox }
    /// the coffee butler's box, bigger than the others' because his art has a wide margin around its circle
    static var coffeeSize: CGFloat { AppImages.coffeeBox }
    /// the badge's disc
    static let badgeSize: CGFloat = 30

    var body: some View {
        if look.emoji != nil {
            if let butler = AppImages.coffee {
                // The coffee break's own butler, with no disc, in a box that makes his circle as big as the build alert's butler.
                Image(nsImage: butler)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Self.coffeeSize, height: Self.coffeeSize)
                    .overlay {
                        // Steam rises from the cup at Normal and Party (the fun layer).
                        if let level = FunModel.currentLevel, level.animates {
                            CoffeeSteam(level: level)
                        }
                    }
                    .accessibilityHidden(true)
            } else {
                disc
            }
        } else {
            butler
        }
    }

    /// The build alert's butler, with the kind's badge.
    private var butler: some View {
        let icon: AlertContent.Icon = look.isSad ? .sad : .happy
        let level = FunModel.currentLevel.flatMap { $0.showsMoments ? $0 : nil }
        return ButlerStage(
            art: AppImages.alert(icon, hat: look.hat), icon: icon, hat: look.hat, level: level,
            behind: { EmptyView() },
            front: {
                badge
                    .offset(x: 6, y: 2)
            }
        )
        .accessibilityHidden(true)
    }

    /// the kind's symbol, white on a disc in its color
    private var badge: some View {
        Image(systemName: look.symbol)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: Self.badgeSize, height: Self.badgeSize)
            .background(look.tint.color, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }

    @ViewBuilder private var disc: some View {
        let color = Color(red: 0.93, green: 0.55, blue: 0.22)
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [color.opacity(0.95), color.opacity(0.55)], center: .topLeading, startRadius: 4,
                        endRadius: Self.size))
            Circle()
                .strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
            Text(verbatim: look.emoji ?? "☕")
                .font(.system(size: Self.size * 0.56))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        }
        .frame(width: Self.size, height: Self.size)
        .shadow(color: color.opacity(0.45), radius: 14, y: 4)
        .accessibilityHidden(true)
    }
}
