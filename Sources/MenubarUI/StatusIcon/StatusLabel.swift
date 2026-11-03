import AppKit
import MenubarCore
import SwiftUI

/// The status item's label (Task 4.2): the counts of the builds that show and the problem marker,
/// or the butler when nothing is going on (PIPE-05).
///
/// An offered update never changes it (the user, 2026-10-29). It reads `ProjectsPipelines` from the environment (``SwiftUICore/View/appEnvironment(_:router:)``).
/// No tooltip: `.help` doesn't reach the status item, and the user decided the icon needs none, so the idle tooltip egg
/// (EGG-05) isn't built. The butler wears a hat during a green streak or all of December, and bows for the Konami
/// code (the easter eggs, `docs/easter-eggs.md`).
public struct StatusLabel: View {
    @Environment(ProjectsPipelines.self) private var pipelines
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router

    public init() {}

    public var body: some View {
        // Every project's builds and problems, summed (plan Phase 13). The layout is a plain value; a store the layout
        // doesn't show is never read, so it never redraws the label (APP-11).
        let preferences = pipelines.preferences
        let layout = preferences.menuBarLayout
        StatusLabelContent(model: StatusLabelModel(
            problem: pipelines.problem, counts: pipelines.counts,
            style: preferences.iconStyle, hat: pipelines.butlerHat,
            bow: preferences.easterEggs ? model.eggs.bow : nil,
            inboxCount: layout.isOn(.inbox) ? model.inbox.badgeCount : 0,
            reviewCount: layout.isOn(.reviews) ? model.mergeRequests.reviewCount : 0,
            slot: layout.isOn(.slot) ? Self.slot(model) : nil,
            layout: layout))
            // With the review count on, the merge requests load in the background too, every few minutes while nobody
            // looks (OD-02, OD-06): the count is the menu bar's own, not the pane's.
            .onChange(of: layout.isOn(.reviews), initial: true) { _, isOn in
                router.report(isOn ? [.mergeRequests] : [], shownBy: Self.host, to: model.scheduler)
            }
    }

    /// the host the status item reports its GitLab surfaces as
    static let host = "statusItem"

    /// Returns the next date of my committed slot, from the work items already loaded: the slot most committed items
    /// have, as the pane's Work Items row shows it (WI-04, SLOT-02).
    static func slot(_ model: AppModel, calendar: Calendar = .current) -> StatusLabelModel.SlotCountdown? {
        let team = model.pipelines.project.team
        guard !team.slotPrefix.isEmpty, !team.committedLabel.isEmpty,
            let committed = model.workItems.lists?.committed?.items, !committed.isEmpty,
            let label = MenuPaneModel.slot(of: committed, prefix: team.slotPrefix, colors: [:]),
            let name = SlotName(label: label.title, prefix: team.slotPrefix)
        else { return nil }
        let rules = SlotRules(team: team)
        guard let dates = rules.dates(of: name, calendar: calendar) else { return nil }
        return StatusLabelModel.SlotCountdown(
            dates: dates, warnDays: rules.warnDays, today: model.dependencies.now(), calendar: calendar)
    }
}

/// Draws a ``StatusLabelModel`` the way the menu bar can show it: the status button keeps one image and one title, so
/// the label is exactly one `Image` (`docs/decisions.md`, Task 4.2). The butler alone is the template file; any
/// other state is one image rendered from the parts by ``StatusMarkersImage``, which does not depend on how the menu
/// bar lays out a `Text`. Nothing animates but the Konami bow (EGG-02), whose frames are separate images.
public struct StatusLabelContent: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: StatusLabelModel

    public init(model: StatusLabelModel) {
        self.model = model
    }

    public var body: some View {
        switch model.rendering {
        case .identity:
            Image(nsImage: AppImages.butler(hat: model.hat, bow: model.bow))
        case .image:
            Image(nsImage: StatusMarkersImage.image(for: model, colorScheme: colorScheme))
        }
    }
}

/// The parts of a label, the butler, the markers and the counts with their symbols, rendered into one image in the
/// menu bar's font. The monochrome style is a template, which the menu bar tints like its own icons. The color style is
/// not: the symbols take their colors and the rest the label color of the menu bar's appearance, which the label's
/// `colorScheme` stands for (inferred: nobody can look at the real menu bar from a test).
@MainActor
enum StatusMarkersImage {
    /// What an image depends on; the scheme only matters where the image isn't a template.
    private struct Key: Hashable {
        let parts: [StatusLabelModel.Part]
        let style: Preferences.IconStyle
        let colorScheme: ColorScheme?
        let hat: ButlerHat?
        let bow: BowFrame?
    }

    /// the height of every label image, the butler's, so the label doesn't jump between states
    static let height: CGFloat = 18

    private static var cache: [Key: NSImage] = [:]

    /// Returns the image of a model's parts.
    ///
    /// - Parameters:
    ///   - model: the model
    ///   - colorScheme: the menu bar's appearance, as the label sees it
    /// - Returns: the image, cached by parts, style and, in the color style, scheme
    static func image(for model: StatusLabelModel, colorScheme: ColorScheme) -> NSImage {
        let isTemplate = model.style != .color
        // Computed once: the parts walk the layout.
        let parts = model.parts
        let key = Key(
            parts: parts, style: model.style, colorScheme: isTemplate ? nil : colorScheme, hat: model.hat,
            bow: model.bow)
        if let image = cache[key] {
            return image
        }
        // Template images use the alpha only, so the label color is black there; the color style needs the real one.
        let label: Color = isTemplate ? .black : (colorScheme == .dark ? .white : .black)
        let content = HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                view(of: part, in: model, label: label)
            }
        }
        .font(Font(NSFont.menuBarFont(ofSize: 0)))
        .monospacedDigit()
        .foregroundStyle(label)
        .frame(height: height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = renderer.nsImage ?? AppImages.butler(hat: nil, bow: nil)
        image.isTemplate = isTemplate
        cache[key] = image
        return image
    }

    @ViewBuilder
    private static func view(of part: StatusLabelModel.Part, in model: StatusLabelModel, label: Color) -> some View {
        let color = model.color(of: part) ?? label
        switch part {
        case .inboxDot:
            // Red in the color style; the monochrome template only keeps its shape, which the menu bar tints.
            Circle().fill(Color.red).frame(width: 6, height: 6)
        case .count(_, let count), .inboxCount(let count), .reviews(let count):
            HStack(spacing: 2) {
                Image(systemName: StatusLabelModel.symbol(of: part) ?? "").foregroundStyle(color)
                // A `String`, so the count has no grouping.
                Text(verbatim: String(count))
            }
        case .slot(let text, _):
            HStack(spacing: 2) {
                Image(systemName: StatusLabelModel.symbol(of: part) ?? "").foregroundStyle(color)
                Text(verbatim: text).foregroundStyle(color)
            }
        case .problem:
            Image(systemName: Marker.problem).foregroundStyle(color)
        case .identity:
            Image(nsImage: AppImages.butler(hat: model.hat, bow: model.bow))
        }
    }
}
