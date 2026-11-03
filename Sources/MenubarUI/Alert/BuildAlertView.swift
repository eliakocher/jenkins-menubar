import AppKit
import MenubarCore
import SwiftUI

/// The alert window's content (Task 4.5, `docs/design/alert.md`): the happy or sad butler, the headline with the
/// result's SF Symbol, the title, the facts, and the buttons, the default one on top (ALERT-02, ALERT-03).
///
/// `NativeEffects` hosts it in a non-activating panel that never takes the keyboard by itself; once a click makes the
/// panel key, Return presses the default button and Esc presses Dismiss. A live alert keeps Open Console and Hide Until
/// the Next Build in the context menu of its background, so the buttons stay calm. A dark tint over the glass and a
/// lighter grey for the facts keep it readable over a light window (the user, 2026-10-30). 320 pt wide; the height
/// fits the content.
///
/// When the window holds several alerts, a ``AlertPager`` adds "1 of 3" with ‹ › above the butler and Dismiss All next to
/// Dismiss; the page keeps its own buttons and its own butler.
public struct BuildAlertView: View {
    let alert: BuildAlert
    let notificationsOff: Bool
    let pager: AlertPager?
    let rebuildWithChanges: (() -> Void)?
    let perform: (AlertContent.Action) -> Void
    /// freezes the celebration at one frame, for the gallery's shots; `nil` plays it
    var frozenCelebrationAt: Double?
    /// freezes the cloud and the rain at one frame, for the gallery's shots; `nil` plays them
    var frozenWeatherAt: Double?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme

    /// the alert's fixed width
    public static let width: CGFloat = 320

    /// the glass's corners, which are the window's corners too
    public static let cornerRadius: CGFloat = 16

    /// - Parameters:
    ///   - alert: the alert
    ///   - notificationsOff: whether it shows as a window because its banner couldn't (ALERT-03)
    ///   - pager: the paging of a window with several alerts; `nil` for one
    ///   - rebuildWithChanges: opens the sheet of "Rebuild with Changes…" for the build; with it, Rebuild is a split
    ///     button; `nil` keeps the plain button (PIPE-09)
    ///   - perform: runs a button's action; the panel opens its link and dismisses the page
    public init(
        alert: BuildAlert, notificationsOff: Bool, pager: AlertPager? = nil, rebuildWithChanges: (() -> Void)? = nil,
        perform: @escaping (AlertContent.Action) -> Void
    ) {
        self.alert = alert
        self.notificationsOff = notificationsOff
        self.pager = pager
        self.rebuildWithChanges = rebuildWithChanges
        self.perform = perform
    }

    public var body: some View {
        let content = alert.content
        VStack(spacing: 0) {
            if let pager {
                AlertPagerBar(pager: pager)
                    .padding(.bottom, 4)
            }
            butler(content)
            if let ownership = content.ownership {
                // Whose build it is, before anything else: "Watching · by Sam Lee" or "Your build".
                AlertOwnershipTag(ownership: ownership, author: content.watchedAuthor)
                    .padding(.top, 10)
            }
            if let project = content.project {
                // With several projects, which one the build is of (plan Phase 13).
                Text(verbatim: project)
                    .font(.callout)
                    .foregroundStyle(.alertGrey)
                    .padding(.top, content.ownership == nil ? 12 : 6)
            }
            headline(content)
                .font(.title3)
                .bold()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, content.project != nil ? 2 : content.ownership != nil ? 8 : 12)
            if let title = content.title {
                Text(verbatim: title)
                    .lineLimit(lineLimit)
                    .help(title)
                    .padding(.top, 4)
            }
            VStack(spacing: 0) {
                ForEach(content.facts, id: \.self) { fact in
                    Text(verbatim: fact)
                        .lineLimit(fact.hasPrefix(Self.failedStagesPrefix) ? lineLimit : 1)
                        .help(fact.hasPrefix(Self.failedStagesPrefix) ? String(fact.dropFirst(Self.failedStagesPrefix.count)) : "")
                }
            }
            .font(.callout)
            .foregroundStyle(.alertGrey)
            .padding(.top, 4)
            if notificationsOff {
                Text("Notifications are off, so this alert shows as a window.")
                    .font(.footnote)
                    .foregroundStyle(.alertGrey)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            if let eggLine = content.eggLine {
                // An easter egg adds a line under the facts, never in place of one (EGG-11).
                Text(verbatim: eggLine)
                    .font(.callout)
                    .foregroundStyle(.alertGrey)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            VStack(spacing: 8) {
                ForEach(content.buttons, id: \.self) { action in
                    if action == .dismiss, let pager {
                        // Dismiss takes this page, Dismiss All the whole window.
                        HStack(spacing: 8) {
                            button(action, content: content)
                            Button("Dismiss All", action: pager.dismissAll)
                                .controlSize(.large)
                                .buttonSizing(.flexible)
                                .frame(maxWidth: .infinity)
                                .background { plainFill }
                        }
                    } else if action == .rebuild, let rebuildWithChanges {
                        RebuildSplitButton(
                            identically: { perform(.rebuild) }, withChanges: rebuildWithChanges
                        )
                        .controlSize(.large)
                        .buttonSizing(.flexible)
                        .frame(maxWidth: .infinity)
                        .background { plainFill }
                    } else {
                        button(action, content: content)
                    }
                }
            }
            .padding(.top, 20)
        }
        .multilineTextAlignment(.center)
        .padding([.horizontal, .bottom], 20)
        .padding(.top, 20)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .overlay {
            // The storm's lightning: a white flash over the panel, in its corners.
            if let weather = content.weather {
                SadWeatherFlash(weather: weather, seed: alert.build.number, frozenAt: frozenWeatherAt)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            }
        }
        .overlay {
            // Confetti or fireworks over the alert, for a redemption, a streak, a merge or New Year (the fun layer).
            if let celebration = content.celebration, let level = content.funLevel {
                FunCelebrationOverlay(celebration: celebration, level: level, seed: alert.build.number, frozenAt: frozenCelebrationAt)
            }
        }
        .background {
            // A tint over the glass, so the white title and buttons stand out over a light window; the glass still
            // shows through. The corners match the panel's glass.
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(colorScheme == .dark ? Self.darkTint : Self.lightTint))
        }
        .contextMenu {
            // The secondary actions: Open Console and Hide Until the Next Build (ALERT-03, HIDE-01).
            ForEach(content.moreActions, id: \.self) { action in
                Button(action.title) {
                    perform(action)
                }
            }
        }
    }

    /// The butler, with the hat of the season and the weather of a failed build behind him. The plain art fills the 96 pt
    /// box; the seasonal art is taller than square, shown at the plain butler's scale (see
    /// ``AppImages/alertSize(of:box:)``): his face reads as big as ever and the hat rises above the box.
    private func butler(_ content: AlertContent) -> some View {
        let art = AppImages.alert(content.icon, hat: content.hat)
        let size = AppImages.alertSize(of: art, box: 96)
        return Image(nsImage: art)
            .resizable()
            .interpolation(.high)
            .frame(width: size.width, height: size.height)
            .overlay {
                // The witch's and New Year's hats are drawn in code only when their art is missing (the fallback).
                if let hat = content.hat, AppImages.drawsFallbackHat(content.icon, hat: hat) {
                    SeasonalHatOverlay(hat: hat)
                }
            }
            // The butler bounces on a green build and shakes on a red one, once (Normal and Party).
            .funButlerMotion(isHappy: content.icon == .happy, level: content.funLevel)
            .background(alignment: .top) {
                // A cloud and rain behind a failed build's butler (Normal and Party).
                if let weather = content.weather {
                    SadWeatherSky(weather: weather, seed: alert.build.number, frozenAt: frozenWeatherAt)
                        .frame(width: 300, height: size.height + 44 + SadWeatherSky.headroom)
                        .offset(y: -SadWeatherSky.headroom)
                }
            }
    }

    private func button(_ action: AlertContent.Action, content: AlertContent) -> some View {
        Button(action.title) {
            perform(action)
        }
        .controlSize(.large)
        .buttonSizing(.flexible)
        .frame(maxWidth: .infinity)
        .background {
            // The plain buttons' fill a touch more visible on the darker glass.
            if action != content.defaultAction {
                plainFill
            }
        }
        .keyboardShortcut(shortcut(for: action))
    }

    private var plainFill: some View {
        Capsule().fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0))
    }

    /// how dark the glass's tint is: strong in dark, where light text sits on glass over a light window, slight in
    /// light, where the text is dark
    static let darkTint = 0.42
    static let lightTint = 0.07

    private static let failedStagesPrefix = "Failed stages: "

    /// Three lines, six at accessibility sizes (`docs/design/alert.md`, Layout).
    private var lineLimit: Int {
        typeSize.isAccessibilitySize ? 6 : 3
    }

    /// The result's SF Symbol in its color, then "!1 #7 SUCCESS"; the emoji is for banners only (ALERT-02).
    private func headline(_ content: AlertContent) -> Text {
        let state = Self.state(of: content.result)
        let symbol = Text(Image(systemName: state.symbol))
        let tinted = state.color.map { symbol.foregroundStyle($0) } ?? symbol
        let text = content.headlineParts?.text ?? content.headline
        return Text("\(tinted) \(Text(verbatim: text))")
    }

    private static func state(of result: AlertContent.ResultKind) -> BuildState {
        switch result {
        case .success: .successful
        case .unstable: .unstable
        case .failure: .failed
        case .aborted: .aborted
        case .other: .other("")
        }
    }

    private func shortcut(for action: AlertContent.Action) -> KeyboardShortcut? {
        if action == alert.content.defaultAction {
            return .defaultAction
        }
        return action == .dismiss ? .cancelAction : nil
    }
}

/// The tag under the butler that tells whose build the alert is about (the user, 2026-11-03: "it should be obvious").
///
/// A watched build gets a filled capsule with an eye, "Watching", and "by Sam Lee" next to it, in neutral grey so it
/// stays apart from the result's colors; my own build gets a quiet, lighter "Your build".
struct AlertOwnershipTag: View {
    let ownership: AlertContent.Ownership
    let author: String?

    var body: some View {
        HStack(spacing: 8) {
            switch ownership {
            case .watched:
                Label("Watching", systemImage: "eye.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.18)))
                    .fixedSize()
                if let author {
                    Text(verbatim: "by \(author)")
                        .font(.callout)
                        .foregroundStyle(.alertGrey)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(author)
                }
            case .mine:
                Label("Your build", systemImage: "person.fill")
                    .font(.caption)
                    .foregroundStyle(.alertGrey)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The grey of the alert's facts and notes, lighter than `.secondary` over the tinted glass: the vibrant primary style
/// at a fixed opacity (the user, 2026-10-30: "the grey text a bit lighter").
struct AlertGreyStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        HierarchicalShapeStyle.primary.opacity(environment.colorScheme == .dark ? 0.80 : 0.72)
    }
}

extension ShapeStyle where Self == AlertGreyStyle {
    static var alertGrey: AlertGreyStyle { AlertGreyStyle() }
}

/// The paging of an alert window that holds several alerts (ALERT-03): where the shown page is and what ‹, › and Dismiss
/// All do.
public struct AlertPager {
    /// "1 of 3"; the newest alert is the first
    public var position: String
    public var hasPrevious: Bool
    public var hasNext: Bool
    public var previous: () -> Void
    public var next: () -> Void
    public var dismissAll: () -> Void

    public init(
        position: String, hasPrevious: Bool, hasNext: Bool, previous: @escaping () -> Void, next: @escaping () -> Void,
        dismissAll: @escaping () -> Void
    ) {
        self.position = position
        self.hasPrevious = hasPrevious
        self.hasNext = hasNext
        self.previous = previous
        self.next = next
        self.dismissAll = dismissAll
    }
}

/// "‹ 1 of 3 ›" above the butler.
struct AlertPagerBar: View {
    let pager: AlertPager

    var body: some View {
        HStack(spacing: 10) {
            Button(action: pager.previous) {
                Image(systemName: "chevron.left")
            }
            .disabled(!pager.hasPrevious)
            .help("Newer Alert")
            Text(verbatim: pager.position)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.alertGrey)
            Button(action: pager.next) {
                Image(systemName: "chevron.right")
            }
            .disabled(!pager.hasNext)
            .help("Older Alert")
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
    }
}
