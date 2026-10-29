#if DEBUG
import MenubarCore
import SwiftUI

/// The pane and its flyouts as the gallery shows them: both on glass over a desktop-like backdrop, the flyout beside
/// the pane with its first row level with the open area's row, as the real flyout is placed. The real pane's glass is
/// the system's panel and the real flyout a child window; here both are views in one window, with the hover look set
/// directly, since the gallery's windows show no real hover.
struct MenuPaneGalleryView: View {
    let data: PanelData
    var open: MainWindowSection?
    /// the pane row the pointer is on; `nil` leaves only the open area highlighted
    var highlight: MenuNavigation.PaneRow?
    /// the flyout row the pointer is on, by index
    var flyoutHighlight: Int?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .menuFlyoutTop, spacing: MenuFlyoutPlacement.gap) {
            MenuPaneContent(model: MenuPaneModel(data), navigation: navigation)
                .containerShape(.rect(cornerRadius: 16))
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
            if let open {
                MenuFlyoutContent(flyout: MenuFlyout(data, area: open), highlight: flyoutHighlight)
                    .glassEffect(.regular, in: .rect(cornerRadius: MenuMetrics.flyoutCorner))
            }
        }
        .padding(28)
        .background { backdrop }
        .environment(\.panelSpinnerDelay, .zero)
    }

    private var navigation: MenuNavigation {
        var navigation = MenuNavigation()
        navigation.openArea = open
        navigation.highlight = highlight
        if flyoutHighlight != nil {
            navigation.focus = .flyout
            navigation.flyoutHighlight = flyoutHighlight
        }
        return navigation
    }

    /// A soft wallpaper of the season's colors, so the glass has something to refract.
    private var backdrop: some View {
        let dark = colorScheme == .dark
        return ZStack {
            LinearGradient(
                colors: dark
                    ? [Color(red: 0.09, green: 0.10, blue: 0.20), Color(red: 0.18, green: 0.10, blue: 0.26)]
                    : [Color(red: 0.62, green: 0.76, blue: 0.95), Color(red: 0.93, green: 0.78, blue: 0.86)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(dark ? Color.indigo.opacity(0.55) : Color.white.opacity(0.55))
                .frame(width: 420)
                .blur(radius: 90)
                .offset(x: -160, y: -120)
            Circle()
                .fill(dark ? Color.teal.opacity(0.35) : Color.orange.opacity(0.35))
                .frame(width: 380)
                .blur(radius: 100)
                .offset(x: 260, y: 200)
            if busy {
                busyWindow
            }
        }
    }

    /// whether a busy, bright window lies behind the glass, for judging the text's contrast on it
    var busy = false

    /// Lines of bold colored text and blocks, like a busy editor or web page behind the menu.
    private var busyWindow: some View {
        let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .white, .black]
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<36, id: \.self) { line in
                HStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) { word in
                        Text(verbatim: ["Build", "failed:", "tests", "deploy", "merge", "review"][(line + word) % 6])
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(colors[(line * 3 + word) % colors.count])
                        RoundedRectangle(cornerRadius: 3)
                            .fill(colors[(line + word * 2) % colors.count].opacity(0.8))
                            .frame(width: CGFloat(20 + (line * 7 + word * 13) % 50), height: 12)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

/// The pane with its real flyout: the controller puts the glass panel beside the open area's row as a child window
/// of the gallery's window, as in the menu bar. The flyout's window isn't in the manifest; find it by the gallery's
/// pid (`CGWindowListCopyWindowInfo`) to take its screenshot.
struct MenuPaneLiveGalleryView: View {
    let data: PanelData
    let open: MainWindowSection
    @ViewState private var controller = MenuPaneController()

    var body: some View {
        let controller = controller
        MenuPaneContent(
            model: MenuPaneModel(data), navigation: controller.navigation,
            events: MenuPaneEvents(
                hover: { controller.hover($0) }, leave: { controller.leavePane() },
                activate: { if case .area(let section) = $0 { controller.open(section) } },
                anchor: { controller.register($0, view: $1) }))
            .onAppear {
                let data = data
                controller.flyout = { MenuFlyout(data, area: $0) }
                controller.makeFlyoutRoot = {
                    AnyView(MenuFlyoutHost(controller: controller, actions: .none) { _ in data }
                        .environment(\.panelSpinnerDelay, .zero))
                }
                controller.paneAppeared()
                let open = open
                Task {
                    // Once the window is on screen, so the row has its place.
                    try? await Task.sleep(for: .milliseconds(800))
                    controller.open(open)
                }
            }
    }
}

/// Lays its content out at the least height it takes, as the menubar's window sizes itself: the gallery's windows ask
/// for the ideal size instead, which hid rows that give in below it (the user's screenshot of 2026-10-29).
struct MenuBarWindowSizing: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = subviews.map { $0.sizeThatFits(ProposedViewSize(width: nil, height: nil)).width }.max() ?? 0
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: 0)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

extension GalleryCatalog {
    /// The pane alone and with each area's flyout open, in a typical state, and the states it reads quietly in.
    static var menuPaneEntries: [GalleryEntry] {
        [
            GalleryEntry(screen: "menu-pane", state: "typical", size: CGSize(width: 410, height: 470)) { f in
                MenuPaneGalleryView(data: f.menuPaneData, highlight: .area(.mergeRequests))
            },
            GalleryEntry(screen: "menu-pane", state: "pipelines", size: CGSize(width: 800, height: 470)) { f in
                MenuPaneGalleryView(data: f.menuPaneData, open: .pipelines, flyoutHighlight: 1)
            },
            GalleryEntry(screen: "menu-pane", state: "merge-requests", size: CGSize(width: 800, height: 470)) { f in
                MenuPaneGalleryView(data: f.menuPaneData, open: .mergeRequests, flyoutHighlight: 0)
            },
            GalleryEntry(screen: "menu-pane", state: "work-items", size: CGSize(width: 800, height: 520)) { f in
                MenuPaneGalleryView(data: f.menuPaneData, open: .workItems, flyoutHighlight: 2)
            },
            GalleryEntry(screen: "menu-pane", state: "menu-bar-sizing", size: CGSize(width: 364, height: 420)) { f in
                MenuBarWindowSizing {
                    MenuPaneContent(model: MenuPaneModel(f.menuPaneData), navigation: MenuNavigation())
                }
                .environment(\.dynamicTypeSize, .xLarge)
            },
            GalleryEntry(screen: "menu-pane", state: "busy-backdrop", size: CGSize(width: 840, height: 470)) { f in
                MenuPaneGalleryView(data: f.menuPaneData, open: .pipelines, flyoutHighlight: 1, busy: true)
            },
            GalleryEntry(screen: "menu-pane", state: "live-flyout", size: CGSize(width: 364, height: 420)) { f in
                MenuPaneLiveGalleryView(data: f.menuPaneData, open: .mergeRequests)
            },
            GalleryEntry(screen: "menu-pane", state: "work-items-unmarked", size: CGSize(width: 840, height: 520)) { f in
                // No related MR marks an item: the flyout has no symbol column.
                MenuPaneGalleryView(data: f.menuPaneData(markers: false), open: .workItems, flyoutHighlight: 1)
            },
            GalleryEntry(screen: "menu-pane", state: "problems", size: CGSize(width: 800, height: 520)) { f in
                MenuPaneGalleryView(
                    data: f.panel(
                        problem: .rejectedToken(.jenkins), mine: f.typicalBuilds,
                        mergeRequests: PanelData.MergeRequests(problem: .noToken(.gitLab)),
                        workItems: PanelData.WorkItems(problem: .noToken(.gitLab))),
                    open: .mergeRequests)
            },
            GalleryEntry(screen: "menu-pane", state: "loading", size: CGSize(width: 800, height: 470)) { f in
                MenuPaneGalleryView(
                    data: f.panel(
                        hasLoaded: false, isChecking: true, lastChecked: false,
                        mergeRequests: PanelData.MergeRequests(isLoading: true),
                        workItems: PanelData.WorkItems(isLoading: true)),
                    open: .pipelines)
            },
        ]
    }
}

extension Fixtures {
    /// A busy day: two builds running, one failed, one passed, one watched; the MRs in all three sections; the
    /// committed work items with their slot.
    var menuPaneData: PanelData {
        menuPaneData(markers: true)
    }

    /// The busy day, with or without the work items' related-MR markers.
    func menuPaneData(markers: Bool) -> PanelData {
        var workItems = typicalWorkItems
        if !markers {
            workItems.markers = [:]
        }
        return panel(
            mine: [
                running("MR-12", 7, "Fix the login redirect after a timeout", startedMinutesAgo: 5, estimateMinutes: 25,
                        stages: ["build", "tests"]),
                running("MR-14", 2, "Show the merge status in the tooltip", startedMinutesAgo: 9, estimateMinutes: nil,
                        stages: ["build"]),
                finished("MR-16", 3, "Add a retry to the export job", .failure, durationMinutes: 12, finishedMinutesAgo: 30,
                         failedStages: ["tests", "deploy"], tests: TestCounts(failed: 3, total: 1200)),
                finished("MR-21", 4, "Remove the old onboarding page", .success, durationMinutes: 18, finishedMinutesAgo: 12),
            ],
            watched: [
                running("MR-2", 14, "Retry the upload when the connection drops", startedMinutesAgo: 8, estimateMinutes: 20,
                        stages: ["tests"], kind: .watched, author: "Sam Lee"),
            ],
            hiddenCount: 1, workItems: workItems)
    }
}
#endif
