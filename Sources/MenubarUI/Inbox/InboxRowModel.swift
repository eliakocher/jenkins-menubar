import Foundation
import MenubarCore

/// One Inbox row as the list and the menu bar flyout draw it (INBOX-02): the words of its two lines, the reference chip,
/// who did it and when. Pure, so the tests and the gallery get the same words as the window.
struct InboxRowModel: Hashable, Identifiable, Sendable {
    let entry: InboxEntry
    /// line 1: what happened and to what, "Mentioned you in Fix the login redirect"
    let title: String
    /// the target's number as the app-wide chip: blue "#123" for a work item, green "!123" for a merge request; `nil`
    /// for a target without a reference
    let reference: Reference?
    /// who did it, as the name line 2 shows; `nil` when nobody did, like a failed pipeline
    let author: Author?
    /// how long ago it happened, "5m"
    let age: String
    /// whether someone mentioned me: the row wears the "@" mark
    let isMention: Bool
    /// the row's symbol and its color
    let symbol: String
    let tint: Tint
    /// "Until tomorrow 09:00" for a snoozed row; `nil` for the others
    let snoozeText: String?
    /// the first line of GitLab's to-do text, like the comment that mentions me; `nil` without one
    let excerpt: String?
    /// what line 2 says for a thing of this app instead of an author: the build's number and title, the item's title; `nil`
    /// for none
    let subtitle: String?
    /// when one of my to-dos is due, "Due today", "Due tomorrow", "Due 12 Nov"; `nil` for a row without a date
    let dueText: String?
    /// whether the date of one of my pending to-dos has passed: the text turns red
    let isOverdue: Bool

    var id: String { entry.id }

    /// A target's number and what it is.
    struct Reference: Hashable, Sendable {
        var kind: ReferenceKind
        /// "#123", "!45", "&6"
        var text: String
    }

    struct Author: Hashable, Sendable {
        var name: String
        var username: String
    }

    /// The colors the symbols wear; the views map them to the app's colors.
    enum Tint: Hashable, Sendable {
        case accent
        case blue
        case green
        case orange
        case red
        case purple
        case secondary
        /// a failed build's symbol, in its state's color
        case build(BuildState)
    }

    /// Returns the row of an entry.
    ///
    /// - Parameters:
    ///   - entry: the entry
    ///   - now: the time the ages count from
    ///   - calendar: the user's calendar, for the wake time of a snoozed row
    init(_ entry: InboxEntry, now: Date, calendar: Calendar = .current) {
        self.entry = entry
        title = Self.title(of: entry)
        reference = Self.reference(of: entry)
        author = entry.actor.map { Author(name: $0.name.isEmpty ? $0.username : $0.name, username: $0.username) }
        age = GitLabText.age(since: entry.date, now: now)
        isMention = entry.kind == .mentioned
        (symbol, tint) = Self.symbol(of: entry)
        snoozeText = entry.snoozedUntil.map { Self.wakeText($0, now: now, calendar: calendar) }
        excerpt = Self.excerpt(of: entry)
        subtitle = Self.subtitle(of: entry)
        let due = entry.dueDate.map { Self.dueText($0, now: now, calendar: calendar) }
        dueText = due?.text
        isOverdue = due?.isOverdue == true && entry.myTodo?.doneAt == nil
    }

    /// Returns line 1: what the row is about, in sentence case, then the target's title.
    ///
    /// - Parameter entry: the entry
    /// - Returns: "Review requested: Add a retry to the export job"
    static func title(of entry: InboxEntry) -> String {
        // A thing of this app says it all in its own words: "Claude answered: Why did it fail?".
        if case .event(let event) = entry.source, event.source == .local {
            return event.headline
        }
        // My own to-do is just what I wrote.
        if entry.isMine {
            return entry.title
        }
        let lead = lead(of: entry)
        return entry.title.isEmpty ? lead : "\(lead): \(entry.title)"
    }

    /// What happened, without the author, who is on line 2.
    static func lead(of entry: InboxEntry) -> String {
        if let todo = entry.todo {
            switch todo.action {
            case .mentioned: return "Mentioned you"
            case .directlyAddressed: return "Addressed you"
            case .assigned: return "Assigned to you"
            case .reviewRequested: return "Review requested"
            case .approvalRequired, .addedApprover: return "Approval requested"
            case .reviewSubmitted: return "Review submitted"
            case .buildFailed: return "Pipeline failed"
            case .unmergeable: return "Can't be merged"
            case .mergeTrainRemoved: return "Removed from the merge train"
            case .marked: return "To-do"
            case .memberAccessRequested: return "Access requested"
            default:
                let words = todo.action.phrase
                return words.prefix(1).uppercased() + words.dropFirst()
            }
        }
        switch entry.kind {
        case .mentioned: return "Mentioned you"
        case .assigned: return "Assigned to you"
        case .reviewRequested: return "Review requested"
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .reviewed: return "Reviewed"
        case .merged: return "Merged"
        case .pipelineFailed: return "Pipeline failed"
        default: return entry.headline
        }
    }

    /// Returns the chip of the entry's reference: its sign and number, `!12` for a merge request, `#7` for a work item.
    static func reference(of entry: InboxEntry) -> Reference? {
        // A build is named "!12501 #5": the merge request's chip, the build's number after it on line 2.
        if entry.kind == .buildFailed, let label = entry.reference {
            let merge = label.split(separator: " ").first { $0.hasPrefix("!") }
            return merge.map { Reference(kind: .mergeRequest, text: String($0)) }
        }
        guard let reference = entry.reference,
            let sign = reference.lastIndex(where: { $0 == "!" || $0 == "#" || $0 == "&" })
        else {
            return nil
        }
        let text = String(reference[sign...])
        guard text.count > 1 else {
            return nil
        }
        return Reference(kind: text.hasPrefix("!") ? .mergeRequest : .workItem, text: text)
    }

    /// Returns the symbol of an entry and its color: its kind's, and for a failed build its state's.
    static func symbol(of entry: InboxEntry) -> (String, Tint) {
        if entry.kind == .buildFailed {
            let unstable = (entry.todo == nil) && entry.headline.contains("unstable")
            let state: BuildState = unstable ? .unstable : .failed
            return (state.symbol, .build(state))
        }
        return symbol(of: entry.kind)
    }

    /// Returns the symbol of a kind and its color.
    static func symbol(of kind: InboxEventKind) -> (String, Tint) {
        switch kind {
        case .mentioned: ("at", .accent)
        case .reviewRequested: ("eye.circle.fill", .orange)
        case .assigned: ("person.crop.circle.fill", .blue)
        case .approved: ("checkmark.circle.fill", .green)
        case .changesRequested: ("arrow.uturn.backward.circle.fill", .orange)
        case .reviewed: ("text.bubble.fill", .blue)
        case .merged: ("arrow.triangle.merge", .purple)
        case .pipelineFailed: ("xmark.circle.fill", .red)
        case .otherTodo: ("checklist", .secondary)
        case .claudeAnswered: ("sparkles", .purple)
        case .digestReady: (MainWindowSection.digest.systemImage, .purple)
        case .coffeeBreak: ("cup.and.saucer.fill", .orange)
        case .whatsNew: ("gift.fill", .blue)
        case .myTodo: ("circle", .accent)
        default: ("circle.fill", .secondary)
        }
    }

    /// Returns line 2's words for a thing of this app: a failed build's number and title, the item a Claude answer is about.
    static func subtitle(of entry: InboxEntry) -> String? {
        guard case .event(let event) = entry.source, event.source == .local, event.kind != .digestReady else {
            return nil
        }
        var parts: [String] = []
        if event.kind == .buildFailed, let number = event.reference?.split(separator: " ").first(where: { $0.hasPrefix("#") }) {
            parts.append(String(number))
        }
        if !event.title.isEmpty, event.title != event.reference {
            parts.append(event.title)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Returns the first non-empty line of GitLab's to-do text, cut at 200 characters; `nil` when it only repeats the
    /// title or is empty.
    static func excerpt(of entry: InboxEntry) -> String? {
        let body: String
        if case .event(let event) = entry.source {
            body = event.excerpt ?? ""
        } else {
            body = entry.body
        }
        let line = body.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line, line != entry.title else {
            return nil
        }
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }

    /// Returns when a to-do is due, as people say it, and whether the day has passed.
    ///
    /// - Parameters:
    ///   - date: the due date
    ///   - now: the time of the look
    ///   - calendar: the user's calendar
    static func dueText(_ date: Date, now: Date, calendar: Calendar = .current) -> (text: String, isOverdue: Bool) {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let style = Date.FormatStyle(
            locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone)
        switch days {
        case ..<0:
            return ("Overdue since \(date.formatted(style.day().month(.abbreviated)))", true)
        case 0:
            // A time earlier today has passed too.
            return ("Due today", date < now && calendar.component(.hour, from: date) + calendar.component(.minute, from: date) > 0)
        case 1:
            return ("Due tomorrow", false)
        case 2..<7:
            return ("Due \(date.formatted(style.weekday(.abbreviated)))", false)
        default:
            return ("Due \(date.formatted(style.day().month(.abbreviated)))", false)
        }
    }

    /// Returns when a snoozed row wakes, as people say it: "Until 14:30" today, "Until tomorrow 09:00", "Until Mon 09:00"
    /// within a week, "Until 12 Nov 09:00" beyond.
    ///
    /// - Parameters:
    ///   - date: the wake time
    ///   - now: the time of the look
    ///   - calendar: the user's calendar
    static func wakeText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let style = Date.FormatStyle(
            locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(style.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) {
            return "Until \(time)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Until tomorrow \(time)"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days > 1, days < 7 {
            let weekday = date.formatted(style.weekday(.abbreviated))
            return "Until \(weekday) \(time)"
        }
        let day = date.formatted(style.day().month(.abbreviated))
        return "Until \(day) \(time)"
    }

    /// Returns whether the row's words contain the search text, ignoring case.
    ///
    /// - Parameter query: the search text, trimmed; empty matches every row
    func matches(_ query: String) -> Bool {
        query.isEmpty
            || [title, reference?.text, author?.name, author?.username, entry.projectPath, entry.reference, excerpt, subtitle, dueText]
                .contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }

    /// the tooltip of the row: the whole title, the author and the excerpt
    var help: String {
        [title, subtitle, author.map { "by \($0.name)" }, excerpt].compactMap { $0 }.joined(separator: "\n")
    }
}
