#if DEBUG
import MenubarCore
import SwiftUI

/// The Slots section as the gallery shows it, on Fri 30 Oct 2026: 2026.45 current (release Mon 2 Nov), 2026.48 freezing
/// today, 2026.51 with two of the user's items, 2027.03 empty. Made-up items of `group/subgroup/project`.
struct SlotsGalleryView: View {
    let fixtures: Fixtures
    let size: CGSize

    var body: some View {
        let today = Self.today
        SlotsContent(
            model: SlotsListModel(plan: plan(today: today), team: fixtures.team, hasLoaded: true, needsToken: false, query: ""),
            chip: .constant(.me), today: today, actions: .none)
            .frame(width: size.width, height: size.height)
            .background(.windowBackground)
    }

    /// Fri 30 Oct 2026, 10:42
    static var today: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 10, minute: 42))!
    }

    private func plan(today: Date) -> SlotPlan {
        let w = fixtures.workItemsScreen
        let slot = "slot::2026.51"
        let items = [
            w.item(31, "Rework the color tokens", labels: ["workflow::committed", slot, "type::feature", "workflow::in-progress"]),
            w.item(28, "Speed up the search index rebuild", labels: ["workflow::committed", slot, "type::bug"]),
        ]
        let related: [String: [RelatedMergeRequest]] = [
            items[0].reference: [w.related(14, "Rework the color tokens", .merged)],
            items[1].reference: [w.related(17, "Speed up the search index rebuild", .opened)],
        ]
        let builds: [Int: BuildReality] = [14: BuildReality(signal: .green, label: "#212"), 17: BuildReality(signal: .running, label: "#215")]
        let known = ["2026.45", "2026.48", "2026.51", "2027.03"].map { Label(title: "slot::\($0)", color: "#9B59B6") }
        return SlotPlan.make(
            workItems: items, mergeRequests: { related[$0.reference] }, build: { builds[$0.iid] }, knownLabels: known,
            team: fixtures.team, today: today)
    }
}

extension GalleryCatalog {
    /// The Slots section at a usual width and at its narrowest.
    static var slotsEntries: [GalleryEntry] {
        let typical = CGSize(width: 760, height: 980)
        let narrow = CGSize(width: 480, height: 1020)
        return [
            GalleryEntry(screen: "slots", state: "typical", size: typical) { f in
                SlotsGalleryView(fixtures: f, size: typical)
            },
            GalleryEntry(screen: "slots", state: "narrow", size: narrow) { f in
                SlotsGalleryView(fixtures: f, size: narrow)
            },
        ]
    }
}
#endif
