import MenubarCore
import SwiftUI

/// A thread of comments, the same in the merge request's Discussion card and the work item's (MR-07, WIN-02), built to
/// take little room: the first comment cut at about four lines, the replies folded behind one quiet line ("3 replies ·
/// last by Sam, 2h ago") that opens them in place, and a resolved thread folded to one line ("Resolved · Sam ·
/// file:line") that opens the whole thread.
struct CommentThreadView: View {
    let thread: CommentThread
    /// the item's page, which the Markdown's relative links resolve against
    let base: URL?
    let now: Date
    /// the ids of the threads the user opened, kept by the card while its item stays selected
    var expanded: Binding<Set<String>>?
    let open: (URL) -> Void

    @ViewState private var localExpanded: Set<String> = []
    @ViewState private var isHovering = false

    init(
        thread: CommentThread, base: URL?, now: Date = .now, expanded: Binding<Set<String>>? = nil,
        open: @escaping (URL) -> Void
    ) {
        self.thread = thread
        self.base = base
        self.now = now
        self.expanded = expanded
        self.open = open
    }

    // One set holds both folds, with a prefix: a thread that changes state (resolved, reopened) starts folded again.
    private func isOpened(_ key: String) -> Bool { (expanded?.wrappedValue ?? localExpanded).contains(key) }

    private func toggle(_ key: String) {
        withAnimation(.snappy(duration: 0.22)) {
            if let expanded {
                expanded.wrappedValue.formSymmetricDifference([key])
            } else {
                localExpanded.formSymmetricDifference([key])
            }
        }
    }

    private var foldKey: String { (thread.isResolved ? "resolved:" : "replies:") + thread.id }

    var body: some View {
        Group {
            if thread.isResolved {
                resolvedThread
            } else {
                openThread
            }
        }
        .onHover { isHovering = $0 }
    }

    // MARK: - An open thread

    private var openThread: some View {
        VStack(alignment: .leading, spacing: 6) {
            CommentNoteView(note: thread.first, location: thread.location, base: base, now: now, avatarSize: 20, open: open)
            if !thread.replies.isEmpty || thread.hasMoreReplies {
                let summary = ReplySummary(thread)
                let isOpen = isOpened(foldKey)
                ReplyToggle(summary: summary, now: now, isOpen: isOpen) { toggle(foldKey) }
                    .padding(.leading, 26)
                if isOpen {
                    replies
                        .padding(.leading, 26)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quaternary.opacity(isHovering ? 0.7 : 0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var replies: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(thread.replies) { reply in
                CommentNoteView(note: reply, location: nil, base: base, now: now, avatarSize: 16, open: open)
            }
            if thread.hasMoreReplies, let url = thread.first.url {
                Button("More Replies in GitLab") { open(url) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(.separator)
                .frame(width: 2)
        }
    }

    // MARK: - A resolved thread

    private var resolvedThread: some View {
        let isOpen = isOpened(foldKey)
        let line = ResolvedLine(thread)
        return VStack(alignment: .leading, spacing: 4) {
            Button { toggle(foldKey) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(MergeRequestStatus.Color.green.swiftUI)
                        .imageScale(.small)
                    Text("Resolved")
                        .fontWeight(.medium)
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Text(verbatim: line.author)
                        .lineLimit(1)
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    if thread.location != nil {
                        Text(verbatim: line.place)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                    } else {
                        Text(verbatim: line.place)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Hides the thread" : "Shows the thread")
            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    CommentNoteView(
                        note: thread.first, location: thread.location, base: base, now: now, avatarSize: 20, open: open)
                    ForEach(thread.replies) { reply in
                        CommentNoteView(note: reply, location: nil, base: base, now: now, avatarSize: 16, open: open)
                            .padding(.leading, 26)
                    }
                    if thread.hasMoreReplies, let url = thread.first.url {
                        Button("More Replies in GitLab") { open(url) }
                            .buttonStyle(.link)
                            .font(.callout)
                            .padding(.leading, 26)
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(isHovering ? 0.5 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - The summary lines

/// What the quiet line under the first comment says about the replies: how many, who, and when the last one came.
struct ReplySummary: Equatable {
    var count: Int
    /// whether GitLab has more replies than the thread holds
    var hasMore: Bool
    var lastAuthor: String?
    var lastDate: Date?
    /// who replied, each once, the latest replier last, at most three
    var repliers: [MergeRequest.Person]

    init(_ thread: CommentThread) {
        count = thread.replies.count
        hasMore = thread.hasMoreReplies
        lastAuthor = thread.replies.last.map { $0.author?.displayName ?? "Someone" }
        lastDate = thread.replies.last?.createdAt
        var seen = Set<String>()
        // The latest replier comes last, so the stack reads oldest to newest.
        let distinct = thread.replies.reversed().compactMap(\.author).filter { seen.insert($0.username).inserted }
        repliers = Array(distinct.prefix(3).reversed())
    }

    /// Returns "3 replies · last by Sam Lee, 2h ago", and "1 reply · by Sam Lee, 2h ago" for one; a thread GitLab cut
    /// says "50+ replies".
    func line(now: Date) -> String {
        let number = "\(count)\(hasMore ? "+" : "")"
        var text = "\(number) \(count == 1 && !hasMore ? "reply" : "replies")"
        if let lastAuthor {
            text += " · \(count == 1 && !hasMore ? "by" : "last by") \(lastAuthor)"
            if let lastDate {
                text += ", \(CommentNoteView.age(of: lastDate, now: now))"
            }
        }
        return text
    }
}

/// The parts of a resolved thread's one line: who started it, and where: the file and line, or the start of the text.
struct ResolvedLine: Equatable {
    var author: String
    var place: String

    init(author: String, place: String) {
        self.author = author
        self.place = place
    }

    init(_ thread: CommentThread) {
        author = thread.first.author?.displayName ?? "Someone"
        if let location = thread.location, !location.isEmpty {
            place = location
        } else {
            let firstLine = thread.first.body.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            place = firstLine ?? "No text"
        }
    }
}

/// The quiet line that opens and closes the replies: the repliers' initials overlapping, the summary and a chevron, with a
/// soft highlight on hover.
private struct ReplyToggle: View {
    let summary: ReplySummary
    let now: Date
    let isOpen: Bool
    let action: () -> Void

    @ViewState private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                HStack(spacing: -3) {
                    ForEach(Array(summary.repliers.enumerated()), id: \.offset) { _, person in
                        InitialsAvatar(name: person.name, username: person.username, size: 16)
                            .overlay { Circle().strokeBorder(.background.secondary, lineWidth: 1.5) }
                    }
                }
                Text(verbatim: summary.line(now: now))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .font(.callout)
            .foregroundStyle(isHovering ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(isHovering ? 0.9 : 0), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.leading, -6)
        .accessibilityHint(isOpen ? "Hides the replies" : "Shows the replies")
    }
}

// MARK: - One comment

/// One comment: a small avatar, the name, the age and the place on the diff on one line, a link to the note that shows on
/// hover, and the text as rendered Markdown under them, cut at about four lines.
private struct CommentNoteView: View {
    let note: ThreadNote
    let location: String?
    let base: URL?
    let now: Date
    let avatarSize: CGFloat
    let open: (URL) -> Void

    @ViewState private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 6) {
                InitialsAvatar(name: note.author?.name ?? "", username: note.author?.username ?? "?", size: avatarSize)
                Text(verbatim: note.author?.displayName ?? "Someone")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if let createdAt = note.createdAt {
                    Text(verbatim: Self.age(of: createdAt, now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                if let location {
                    Text(verbatim: location)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Spacer(minLength: 4)
                if let url = note.url {
                    Button { open(url) } label: {
                        Image(systemName: "arrow.up.forward")
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(isHovering ? 1 : 0)
                    .help("Open the comment in GitLab")
                }
            }
            if !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CommentBody(text: note.body, base: base)
                    .equatable()
                    .padding(.leading, avatarSize + 6)
            }
        }
        .onHover { isHovering = $0 }
    }

    /// "just now", "5m ago", "3h ago", "2d ago"
    nonisolated static func age(of date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : "\(Formatting.age(since: date, now: now)) ago"
    }
}

/// The comment's Markdown, cut at about four lines with "Show More", and parsed again only when its text changes (the
/// detail's clock redraws it every few seconds).
private struct CommentBody: View, Equatable {
    let text: String
    let base: URL?

    var body: some View {
        CollapsibleMarkdown(document: MarkdownDocument(parsing: text, base: base), startsExpanded: false, lines: 4)
    }
}
