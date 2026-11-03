import MenubarCore
import SwiftUI

/// What the digest's rows do (AI-04): a click shows the item in the app, ⌥ the browser; the context menu offers the
/// browser and the link; a slot shows Slots; a red build starts again with the app's Rebuild (PIPE-09).
struct DigestActions {
    var links: ItemLinkActions
    /// switches the window to Slots
    var showSlots: @MainActor () -> Void
    /// switches the window to Work Items, for the "+N more" row of Work Items and Slots
    var showWorkItems: @MainActor () -> Void
    /// starts a build again, as Pipelines' Rebuild does: one click, no question
    var rebuild: @MainActor (BuildID) -> Void
    /// puts a text on the clipboard
    var copyText: @MainActor (String) -> Void

    /// actions that do nothing, for the gallery
    static let none = DigestActions(
        links: ItemLinkActions(follow: { _ in }, open: { _ in }, copy: { _ in }), showSlots: {}, showWorkItems: {},
        rebuild: { _ in },
        copyText: { _ in })
}

// MARK: - The summary on top

/// The digest's first card: the day, Claude's sentence about it, the summary as colored pills ("3 things need you",
/// "1 MR ready to merge", "Code freeze in 3 days"), and what changed since the last digest.
struct DigestSummaryCard: View {
    let report: DigestReport
    let answeredAt: Date
    /// "Opus 5.5"
    let modelName: String
    /// what the search found; `nil` without a search
    var searchNote: String?
    var searchFound = true

    var body: some View {
        DigestHeroSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(answeredAt.formatted(.dateTime.weekday(.wide).day().month(.wide)), systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.purple)
                    Spacer(minLength: 8)
                    Text(verbatim: "Written \(answeredAt.formatted(.relative(presentation: .named))) by \(modelName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Without Claude's sentence the pills say it all; the summary line would only repeat them.
                if let headline = report.headline {
                    Text(verbatim: headline)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                PillFlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(report.summary) { part in
                        DigestSummaryPill(part: part)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(report.summaryLine)
                DigestSinceLine(changes: report.changes)
                if let searchNote {
                    Label(searchNote, systemImage: searchFound ? "text.magnifyingglass" : "magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(searchFound ? .primary : .secondary)
                }
            }
        }
    }
}

/// The surface of the digest's first card: the detail card's, washed with Claude's purple from the top.
struct DigestHeroSurface<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: DetailCard<EmptyView, EmptyView>.cornerRadius, style: .continuous)
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(isDark ? Color(white: 1, opacity: 0.06) : Color.white)
                shape.fill(
                    LinearGradient(
                        colors: [Color.purple.opacity(isDark ? 0.22 : 0.13), Color.indigo.opacity(isDark ? 0.10 : 0.05), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay { shape.strokeBorder(Color.purple.opacity(isDark ? 0.35 : 0.22), lineWidth: 0.75) }
            .shadow(color: .black.opacity(isDark ? 0 : 0.06), radius: 6, y: 1)
    }
}

/// One part of the summary: its symbol and words in its color, on a soft capsule of it.
struct DigestSummaryPill: View {
    let part: DigestReport.SummaryPart

    var body: some View {
        let tint = part.color.swiftUI
        HStack(spacing: 6) {
            Image(systemName: part.symbol)
            Text(verbatim: part.text.prefix(1).uppercased() + part.text.dropFirst())
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(tint.opacity(0.13), in: Capsule())
        .overlay { Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.5) }
    }
}

/// "Since your last digest, yesterday: 2 new · 1 changed · 3 cleared", or that this is the first one.
struct DigestSinceLine: View {
    let changes: DigestChanges

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            if let previous = changes.previousAt {
                Text(verbatim: changes.isEmpty
                    ? "Nothing changed since your last digest, \(previous.formatted(.relative(presentation: .named)))."
                    : "Since your last digest, \(previous.formatted(.relative(presentation: .named))):")
                    .foregroundStyle(.secondary)
                if !changes.new.isEmpty {
                    DigestChangeCount(count: changes.new.count, text: "new", tint: .blue)
                }
                if !changes.changed.isEmpty {
                    DigestChangeCount(count: changes.changed.count, text: "changed", tint: .orange)
                }
                if !changes.cleared.isEmpty {
                    DigestChangeCount(count: changes.cleared.count, text: "cleared", tint: .green)
                }
            } else {
                Text("Your first digest here: the next one marks what is new and what changed.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DigestChangeCount: View {
    let count: Int
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(verbatim: "\(count) \(text)")
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - The sections

/// One section of the digest as a card: Needs You Now spans the page, with a colored rule before each row; the others
/// are compact cards that flow in two columns when there is room. FYI also lists what was cleared since the last
/// digest.
struct DigestSectionCard: View {
    let kind: DigestReport.SectionKind
    let rows: [DigestReport.Row]
    var cleared: [DigestSnapshot.Entry] = []
    /// how many open work items the card doesn't list: its last row says so and opens Work Items
    var more = 0
    let actions: DigestActions
    /// the jobs whose rebuild is on its way, by ``BuildID/jobKey``
    var rebuilding: Set<String> = []

    private var isNow: Bool { kind == .needsYou }

    var body: some View {
        DetailCard(kind.title, symbol: kind.symbol, tint: isNow ? .orange : nil, width: isNow ? .fullWidth : .compact) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider()
                            .padding(.leading, isNow ? 32 : 22)
                    }
                    DigestRowView(
                        row: row, prominent: isNow, actions: actions,
                        isRebuilding: row.item.rebuild.map { rebuilding.contains($0.jobKey) } ?? false)
                }
                if more > 0 {
                    if !rows.isEmpty {
                        Divider()
                            .padding(.leading, 22)
                    }
                    DigestMoreRow(count: more, listsRows: !rows.isEmpty, show: actions.showWorkItems)
                }
                if !cleared.isEmpty {
                    if !rows.isEmpty || more > 0 {
                        Divider()
                    }
                    DigestClearedRows(entries: cleared, actions: actions)
                        .padding(.top, rows.isEmpty ? 0 : 10)
                }
            }
        } accessory: {
            CountBadge(text: "\(rows.count + cleared.count)", tint: isNow ? .orange : .secondary)
        }
    }
}

/// The last row of Work Items and Slots: how many open work items of mine the card leaves out, and a click shows them in
/// Work Items.
struct DigestMoreRow: View {
    let count: Int
    /// whether rows come before it: "+3 more in Work Items", else "3 open in Work Items"
    let listsRows: Bool
    let show: @MainActor () -> Void

    @ViewState private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist")
                .foregroundStyle(.secondary)
                .frame(width: ListRowMetrics.symbolColumn)
            Text(verbatim: listsRows ? "+\(count) more in Work Items" : "\(count) open in Work Items")
                .foregroundStyle(Color.accentColor)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
        }
        .font(.callout.weight(.medium))
        .padding(.vertical, 9)
        .padding(.horizontal, 6)
        .background(
            Color.primary.opacity(isHovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { show() }
        .help("Show your work items")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { show() }
    }
}

/// One item of the digest, in the shape of the window's list rows: the state's symbol, the title with what changed and
/// the state's badge, Claude's why and next step, then the chips that lead to the item and its facts. A click shows
/// the item in the app (⌥ the browser); a slot shows Slots.
struct DigestRowView: View {
    let row: DigestReport.Row
    /// a row of Needs You Now: a colored rule before it, the title in bold
    var prominent = false
    let actions: DigestActions
    var isRebuilding = false

    @ViewState private var isHovered = false

    private var item: DigestItem { row.item }
    private var tint: Color { item.kind == .note ? .purple : item.state.color.swiftUI }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if prominent {
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: 3)
                    .padding(.vertical, 2)
            }
            ListRow(title: item.title) {
                Image(systemName: item.kind == .note ? "sparkles" : item.state.symbol)
                    .foregroundStyle(tint)
            } trailing: {
                if let change = row.change {
                    DigestChangeBadge(change: change)
                }
                if item.kind != .note {
                    StatusBadge(text: item.state.text, tint: tint)
                }
            } details: {
                VStack(alignment: .leading, spacing: 5) {
                    if let why = row.why {
                        Text(verbatim: why)
                            .font(.callout)
                            .foregroundStyle(.primary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let next = row.next {
                        Label {
                            Text(verbatim: next)
                        } icon: {
                            Image(systemName: "arrow.turn.down.right")
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if item.kind != .note {
                        facts
                            .padding(.top, row.why == nil && row.next == nil ? 0 : 2)
                    }
                }
                .padding(.top, 1)
            }
            .fontWeight(prominent ? .medium : nil)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 6)
        .background(
            Color.primary.opacity(isHovered && isClickable ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { follow() }
        .help(help)
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isClickable ? .isButton : [])
        .accessibilityAction { follow() }
    }

    /// the chips that lead to the item, the slot, the facts and Rebuild
    private var facts: some View {
        HStack(alignment: .center, spacing: 6) {
            refChip
            if let slot = item.slot, item.kind == .workItem {
                LabelPill(label: LabelPillModel(MenubarCore.Label(title: "slot::\(slot)", color: item.slotColor)), style: .compact)
            }
            DetailsLine(lead: item.details.first ?? "", more: Array(item.details.dropFirst().prefix(3)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            if let build = item.rebuild {
                rebuildButton(build)
            }
        }
    }

    @ViewBuilder private var refChip: some View {
        if item.kind == .slot {
            DetailChip(symbol: "calendar", tint: tint, text: item.shortRef, help: "Show Slots", action: actions.showSlots)
        } else if !item.shortRef.isEmpty {
            switch item.kind {
            case .mergeRequest, .review:
                // The small chips of the lists, blue and green by what they are; the row's click and menu lead to the item.
                MergeRequestNumberChip(text: item.shortRef)
            case .workItem:
                WorkItemNumberChip(text: item.shortRef)
            case .build, .slot, .note:
                ItemLinkChip(
                    symbol: kindSymbol, tint: tint, text: item.shortRef, help: "Show \(kindName) \(item.shortRef) in the app",
                    showTitle: "Show \(kindName) \(item.shortRef)", openTitle: openTitle, url: item.link, actions: actions.links)
            }
        }
    }

    @ViewBuilder private func rebuildButton(_ build: BuildID) -> some View {
        if isRebuilding {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Rebuilding…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            Button {
                actions.rebuild(build)
            } label: {
                Label("Rebuild", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Starts the job again with this build's parameters")
        }
    }

    @ViewBuilder private var menu: some View {
        if let link = item.link {
            ItemLinkMenuItems(showTitle: "Show \(kindName) \(item.shortRef)", openTitle: openTitle, url: link, actions: actions.links)
        } else if item.kind == .slot {
            Button("Show Slots", action: actions.showSlots)
        }
        if let build = item.rebuild, !isRebuilding {
            Divider()
            Button("Rebuild") { actions.rebuild(build) }
        }
        Divider()
        Button("Copy as Markdown") { actions.copyText(DigestReport.markdown(row)) }
    }

    private var isClickable: Bool { item.link != nil || item.kind == .slot }

    private func follow() {
        if let link = item.link {
            actions.links.follow(link)
        } else if item.kind == .slot {
            actions.showSlots()
        }
    }

    private var help: String {
        switch item.kind {
        case .slot: "Show Slots"
        case .note: ""
        default: item.link == nil ? item.title : "Show \(kindName) \(item.shortRef) in the app; ⌥-click opens it in \(item.kind == .build ? "Jenkins" : "GitLab")"
        }
    }

    private var kindName: String {
        switch item.kind {
        case .mergeRequest, .review: "Merge Request"
        case .build: "Build"
        case .workItem: "Work Item"
        case .slot: "Slot"
        case .note: "Note"
        }
    }

    private var kindSymbol: String {
        switch item.kind {
        case .mergeRequest, .review: "arrow.triangle.pull"
        case .build: "hammer"
        case .workItem: "checklist"
        case .slot: "calendar"
        case .note: "sparkles"
        }
    }

    private var openTitle: String {
        item.kind == .build ? "Open in Jenkins" : "Open in GitLab"
    }
}

/// "New" or "Changed", marked in the row's title line.
struct DigestChangeBadge: View {
    let change: DigestReport.Change

    var body: some View {
        switch change {
        case .new:
            CountBadge(text: "New", tint: .blue)
                .help("Not in your last digest")
        case .changed(let from):
            CountBadge(text: "Changed", tint: .orange)
                .help("Was “\(from)” in your last digest")
        }
    }
}

/// What the last digest had that is gone: merged, fixed or closed since. Struck through, with the chip to the item.
struct DigestClearedRows: View {
    let entries: [DigestSnapshot.Entry]
    let actions: DigestActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cleared Since the Last Digest")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(MergeRequestStatus.Color.green.swiftUI)
                        .frame(width: ListRowMetrics.symbolColumn)
                    if let link = entry.link {
                        if entry.kind == "build" {
                            ItemLinkChip(
                                symbol: "hammer", text: entry.shortRef, help: "Show \(entry.shortRef) in the app",
                                showTitle: "Show \(entry.shortRef)", openTitle: "Open in Jenkins", url: link, actions: actions.links)
                        } else {
                            ItemLinkChip(
                                reference: entry.kind == "workItem" ? .workItem : .mergeRequest, text: entry.shortRef,
                                help: "Show \(entry.shortRef) in the app", showTitle: "Show \(entry.shortRef)",
                                openTitle: "Open in GitLab", url: link, actions: actions.links)
                        }
                    }
                    Text(verbatim: entry.title)
                        .strikethrough(color: .secondary.opacity(0.6))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("\(entry.title): \(entry.state) in your last digest")
                }
            }
        }
    }
}
