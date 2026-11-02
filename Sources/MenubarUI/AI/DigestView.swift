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

    /// Returns a time of the day for a count of minutes since midnight, as Settings keeps the morning digest's.
    static func timeOfDay(minutes: Int) -> String {
        let midnight = Calendar.current.startOfDay(for: Date())
        let date = Calendar.current.date(byAdding: .minute, value: minutes, to: midnight) ?? midnight
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// The Digest section (AI-04): the daily digest Claude writes from the app's own stores, as a detail page. The
/// gallery draws ``DigestContent`` from fixtures.
struct DigestView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    /// the window's search text; the digest's matches are marked
    let searchText: String

    var body: some View {
        let ai = model.ai
        DigestContent(
            availability: ai.availability, isOffered: ai.isOffered, state: ai.state(of: .digest),
            turnStatuses: ai.turns(of: .digest).map(\.status),
            morningMinutes: ai.settings.morningDigest ? ai.settings.digestMinutes : nil, searchText: searchText,
            write: { picked in Task { await ai.writeDigest(model: picked) } },
            send: { Task { await ai.send(.digest) } }, dismiss: { ai.dismiss(.digest) },
            openSettings: { router.open(.settings(pane: .claude)) })
    }
}

/// The Digest page from plain values: the header with Write Digest, then the digest in a card, or its skeleton while it
/// is written, or the reason there is none; or, while the Claude features are off, a card that says so. A page of
/// ``DetailPage``: it takes the content width like the other details.
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
    /// the window's search text; the digest's matches are marked, and the card says how many there are
    var searchText = ""
    /// writes the digest, with the model picked for this run, or `nil` for Settings' model
    let write: (ClaudeModel?) -> Void
    let send: () -> Void
    let dismiss: () -> Void
    let openSettings: () -> Void

    var body: some View {
        DetailPage(id: "digest") { proxy in
            header
            if isOffered {
                card
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
        DetailHeader(title: "Your Digest") {
            StatusBadge(text: "Daily Digest", symbol: "sparkles.rectangle.stack", tint: .purple)
        } menu: {
        } byline: {
            Text("Claude writes a few lines from your merge requests, the reviews waiting for you, the red builds and your work items by slot.")
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

    // MARK: The cards

    private var card: some View {
        DetailCard("Digest", symbol: "sparkles", width: .fullWidth) {
            VStack(alignment: .leading, spacing: 12) {
                switch state {
                case .idle:
                    empty
                case .preparing, .running:
                    // The shape of the text that is on its way, over "Claude is thinking…" and Stop.
                    SkeletonLines(count: 6)
                    rows
                default:
                    rows
                }
            }
        }
    }

    private var rows: some View {
        AIAnswerRows(state: state, subject: .digest, send: send, dismiss: dismiss) { answer in
            if let text = answer.text {
                let found = MarkdownDocument(parsing: text, base: nil).highlighting(searchText)
                if let note = DigestPage.searchNote(query: searchText, matches: found.matches) {
                    Label(note, systemImage: found.matches == 0 ? "magnifyingglass" : "text.magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(found.matches == 0 ? .secondary : .primary)
                }
                CollapsibleMarkdown(document: found.document, startsExpanded: true)
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
            Text("Write Digest sends the facts of your merge requests, reviews, builds and work items to Claude. You see what goes out before the first send.")
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
