import MenubarCore
import SwiftUI

/// The rules of the Digest section's page (AI-04).
enum DigestPage {
    /// Returns whether the digest can be written now, by the page's button: while the Claude features are on, not while
    /// the facts are gathered or Claude answers, and not while the first send waits for the person's Send. Reload and ⌘R
    /// don't write it: a stray ⌘R must not send the person's data to Claude.
    ///
    /// - Parameters:
    ///   - state: where the digest stands
    ///   - isOffered: whether the Claude features are on and `claude` is installed
    static func canWrite(state: AIAnswerState, isOffered: Bool) -> Bool {
        if case .review = state {
            return false
        }
        return isOffered && !state.isBusy
    }

    /// Returns the window's subtitle: when the shown digest was written; `nil` without one.
    static func subtitle(state: AIAnswerState) -> String? {
        guard case .answered(let answer) = state else {
            return nil
        }
        return "Written \(answer.answeredAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Returns what the search says about the digest: how many places it marked, or that there are none. `nil` without
    /// a search.
    ///
    /// - Parameters:
    ///   - query: the search field's text
    ///   - matches: the marks in the digest's text
    static func searchNote(query: String, matches: Int) -> String? {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else {
            return nil
        }
        return switch matches {
        case 0: "No matches for “\(words.joined(separator: " "))”"
        case 1: "1 match"
        default: "\(matches) matches"
        }
    }

    /// Returns what Copy as Markdown copies: the digest's cards as Markdown, or Claude's words; `nil` without an answer.
    static func markdown(of state: AIAnswerState) -> String? {
        guard case .answered(let answer) = state else {
            return nil
        }
        return answer.digest?.markdown ?? answer.text
    }

    /// Returns a time of the day for a count of minutes since midnight, as Settings keeps the morning digest's.
    static func timeOfDay(minutes: Int) -> String {
        let midnight = Calendar.current.startOfDay(for: Date())
        let date = Calendar.current.date(byAdding: .minute, value: minutes, to: midnight) ?? midnight
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// The Digest section (AI-04): the daily digest as cards, from the app's own stores with Claude's priorities, as a
/// detail page. The gallery draws ``DigestContent`` from fixtures.
struct DigestView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    /// the window's search text; the digest's rows that match stay
    let searchText: String

    var body: some View {
        let ai = model.ai
        let state = ai.state(of: .digest)
        DigestContent(
            availability: ai.availability, isOffered: ai.isOffered, state: state,
            turnStatuses: ai.turns(of: .digest).map(\.status),
            morningMinutes: ai.settings.morningDigest ? ai.settings.digestMinutes : nil, searchText: searchText,
            rebuilding: Self.rebuilding(state, model: model),
            write: { picked in Task { await ai.writeDigest(model: picked) } },
            send: { Task { await ai.send(.digest) } }, dismiss: { ai.dismiss(.digest) },
            openSettings: { router.open(.settings(pane: .claude)) }, actions: actions)
            .marksClaudeCardVisible(.digest)
    }

    private var actions: DigestActions {
        let gitLab = GitLabSectionActions.live(model: model, router: router, openURL: openURL)
        return DigestActions(
            links: gitLab.itemLinks, showSlots: { router.section = .slots }, showWorkItems: { router.section = .workItems },
            rebuild: { [model] in model.projects.rebuild($0) },
            copyText: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            })
    }

    /// The jobs whose rebuild is on its way, read only while the digest shows a build that offers Rebuild.
    private static func rebuilding(_ state: AIAnswerState, model: AppModel) -> Set<String> {
        guard case .answered(let answer) = state, answer.digest?.rows.contains(where: { $0.item.rebuild != nil }) == true else {
            return []
        }
        return Set(model.projects.rebuilds.keys)
    }
}

/// The Digest page from plain values: the header with Write Digest and Copy as Markdown; then the digest as cards (the
/// summary, Needs You Now, the sections in columns, and Claude's card for follow-ups), or Claude's words as Markdown when
/// its answer wasn't the digest's JSON; skeleton cards while it is written; or the reason there is none; or, while the
/// Claude features are off, a card that says so. A page of ``DetailPage``: it takes the content width like the other
/// details.
struct DigestContent: View {
    /// whether `claude` was found; `.unknown` while it is looked for
    let availability: ClaudeAvailability
    /// whether the Claude features are on and `claude` is installed
    let isOffered: Bool
    let state: AIAnswerState
    /// the statuses of the follow-up questions, so a new question or answer scrolls into view
    var turnStatuses: [ConversationTurn.Status] = []
    /// the morning digest's time in minutes since midnight; `nil` while it is off
    var morningMinutes: Int?
    /// the window's search text; the rows that match stay, and the summary says how many there are
    var searchText = ""
    /// the jobs whose rebuild is on its way, by ``BuildID/jobKey``
    var rebuilding: Set<String> = []
    /// writes the digest, with the model picked for this run, or `nil` for Settings' model
    let write: (ClaudeModel?) -> Void
    let send: () -> Void
    let dismiss: () -> Void
    let openSettings: () -> Void
    var actions = DigestActions.none

    @ViewState private var copied = false

    var body: some View {
        DetailPage(id: "digest") { proxy in
            header
            if isOffered {
                content
                    // A new question or answer scrolls into view.
                    .onChange(of: turnStatuses) {
                        withAnimation(.snappy) { proxy.scrollTo(ConversationThread.endID, anchor: .bottom) }
                    }
            } else if availability == .unknown {
                // `claude` is still being looked for.
                SkeletonCard(title: "Digest", symbol: "sparkles", lines: 6, width: .fullWidth)
            } else {
                offCard
            }
        }
    }

    // MARK: Header

    private var header: some View {
        // No badge line: the sidebar and the title already say what this is (the user, 2026-11-02, the "Daily Digest"
        // badge above "Your Digest").
        DetailHeader(title: "Your Digest") {
        } menu: {
        } byline: {
            Text("What needs you today, from your merge requests, the reviews waiting for you, your builds and your work items, put in order by Claude.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } chips: {
            if let morningMinutes, isOffered {
                DetailChip(
                    symbol: "alarm", text: "Every morning at \(DigestPage.timeOfDay(minutes: morningMinutes))",
                    help: "Change the morning digest in Settings", action: openSettings)
            }
        } footer: {
            if isOffered {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ClaudeActionButton(
                        title: state == .idle ? "Write Digest" : "Write Again", systemImage: "sparkles", prominent: true,
                        help: "Write the digest from your merge requests, reviews, builds and work items.",
                        isDisabled: !DigestPage.canWrite(state: state, isOffered: isOffered), action: write)
                    if let markdown = DigestPage.markdown(of: state) {
                        Button {
                            actions.copyText(markdown)
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied" : "Copy as Markdown", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .help("Copies the digest as Markdown, for a chat message")
                    }
                    if morningMinutes == nil {
                        Button("Write One Every Morning…", action: openSettings)
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: The content

    @ViewBuilder private var content: some View {
        switch state {
        case .idle:
            DetailCard("Digest", symbol: "sparkles", width: .fullWidth) {
                empty
            }
        case .preparing, .running:
            loading
        case .answered(let answer):
            if let report = answer.digest {
                cards(report, answer: answer)
            } else {
                textCard
            }
        case .review, .failed:
            textCard
        }
    }

    /// The digest as cards: the summary, Needs You Now across the page, the other sections in columns, then Claude's
    /// card for follow-ups.
    @ViewBuilder private func cards(_ report: DigestReport, answer: AIAnswer) -> some View {
        let found = report.matching(searchText)
        let isSearching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        DigestSummaryCard(
            report: report, answeredAt: answer.answeredAt, modelName: answer.modelName,
            searchNote: DigestPage.searchNote(query: searchText, matches: found.matches), searchFound: found.matches > 0)
        let sections = found.report.sections
        if let now = sections.first(where: { $0.kind == .needsYou }) {
            DigestSectionCard(kind: .needsYou, rows: now.rows, actions: actions, rebuilding: rebuilding)
        }
        let cleared = isSearching ? [] : report.changes.cleared
        let others = sections.filter { $0.kind != .needsYou }
        if !others.isEmpty || !cleared.isEmpty {
            CardColumnsLayout(minColumnWidth: 380) {
                ForEach(others) { section in
                    DigestSectionCard(
                        kind: section.kind, rows: section.rows, cleared: section.kind == .fyi ? cleared : [],
                        more: section.more, actions: actions, rebuilding: rebuilding)
                }
                if !cleared.isEmpty, !others.contains(where: { $0.kind == .fyi }) {
                    DigestSectionCard(kind: .fyi, rows: [], cleared: cleared, actions: actions)
                }
            }
        }
        DetailCard("Ask About Your Day", symbol: "sparkles", width: .fullWidth) {
            AIAnswerRows(state: state, subject: .digest, send: send, dismiss: dismiss) { _ in
                EmptyView()
            }
        }
    }

    /// Skeleton cards in the digest's shape, with "Claude is thinking…" and Stop.
    @ViewBuilder private var loading: some View {
        DigestHeroSurface {
            VStack(alignment: .leading, spacing: 14) {
                Label("Writing Your Digest", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.purple)
                SkeletonBlock(fraction: 0.72, height: 14, lineHeight: 28)
                HStack(spacing: 8) {
                    ForEach([150, 128, 118, 164], id: \.self) { width in
                        SkeletonBlock(width: CGFloat(width), height: 24)
                    }
                }
                AIAnswerRows(state: state, subject: .digest, send: send, dismiss: dismiss) { _ in
                    EmptyView()
                }
            }
        }
        DetailCard(DigestReport.SectionKind.needsYou.title, symbol: "bolt.fill", tint: .orange, width: .fullWidth) {
            VStack(alignment: .leading, spacing: 12) {
                SkeletonRows(count: 3, lines: 3)
            }
        }
        CardColumnsLayout(minColumnWidth: 380) {
            DetailCard(DigestReport.SectionKind.myMergeRequests.title, symbol: DigestReport.SectionKind.myMergeRequests.symbol) {
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonRows(count: 3)
                }
            }
            DetailCard(DigestReport.SectionKind.reviews.title, symbol: DigestReport.SectionKind.reviews.symbol) {
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonRows(count: 2)
                }
            }
        }
    }

    /// Claude's answer in words, the first send's review, or the failure with Try Again: one card, as before the cards.
    private var textCard: some View {
        DetailCard("Digest", symbol: "sparkles", width: .fullWidth) {
            VStack(alignment: .leading, spacing: 12) {
                AIAnswerRows(state: state, subject: .digest, send: send, dismiss: dismiss) { answer in
                    if let text = answer.text {
                        let found = MarkdownCache.searched(text, base: nil, query: searchText)
                        if let note = DigestPage.searchNote(query: searchText, matches: found.matches) {
                            Label(note, systemImage: found.matches == 0 ? "magnifyingglass" : "text.magnifyingglass")
                                .font(.callout)
                                .foregroundStyle(found.matches == 0 ? .secondary : .primary)
                        }
                        CollapsibleMarkdown(document: found.document, startsExpanded: true)
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.largeTitle)
                .foregroundStyle(.purple.opacity(0.7))
            Text("No Digest Yet")
                .font(.headline)
            Text("Write Digest sends the facts of your merge requests, reviews, builds and work items to Claude, which puts them in order. You see what goes out before the first send.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    /// The Claude features are off, or `claude` isn't installed: Digest is reachable by a link or a restored section.
    private var offCard: some View {
        DetailCard("Claude Is Off", symbol: "sparkles", width: .fullWidth) {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    availability == .missing
                        ? "Claude Code isn't installed. Install it, then turn the Claude features on in Settings."
                        : "The digest is written by Claude. Turn the Claude features on in Settings to get one.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings…", action: openSettings)
                    .buttonStyle(.bordered)
            }
        }
    }
}
