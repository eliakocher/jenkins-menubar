import Foundation

/// What the first launch of a version tells the Inbox (the user, 2026-11-03: "after the update in the inbox we have a
/// 'what's new' section and we can see everything new").
public struct WhatsNewEntry: Hashable, Sendable {
    /// the version that was launched, like "1.0.4"
    public var version: String
    /// the version the update came from, which the entry's view starts after; nil when it isn't known
    public var from: String?
    /// the sections the entry's view shows, the newest first: every version since the last one seen
    public var sections: [ChangelogSection]

    public init(version: String, from: String?, sections: [ChangelogSection]) {
        self.version = version
        self.from = from
        self.sections = sections
    }
}

/// The rule of the "What's New" entry: which versions to show at a launch, and what to remember.
public enum WhatsNew {
    /// What a launch decides.
    public struct Decision: Hashable, Sendable {
        /// the entry to add; nil when there is nothing new to tell
        public var entry: WhatsNewEntry?
        /// the version to keep as seen; nil keeps what was kept
        public var seen: String?

        public init(entry: WhatsNewEntry?, seen: String?) {
            self.entry = entry
            self.seen = seen
        }
    }

    /// Decides at a launch.
    ///
    /// - A fresh install (no last seen version and the welcome flow never finished) shows nothing and remembers the
    ///   version: only updates tell what's new.
    /// - An install from before the last seen version was kept (no last seen version, the welcome flow finished) shows
    ///   the launched version's own section.
    /// - An update shows every section after the last seen version up to the launched one, so a skipped version isn't lost.
    /// - The same version again, or an older one (a downgrade), shows nothing, and the newest version seen stays.
    /// - A launched version the changelog has no section for, or a changelog that isn't there, shows nothing.
    ///
    /// - Parameters:
    ///   - current: `CFBundleShortVersionString`; nil or not a version shows nothing and remembers nothing
    ///   - lastSeen: the version kept at an earlier launch
    ///   - isFreshInstall: whether the welcome flow was never finished
    ///   - changelog: the bundled changelog's sections
    /// - Returns: the entry to add and the version to keep
    public static func decide(current: String?, lastSeen: String?, isFreshInstall: Bool, changelog: [ChangelogSection]) -> Decision {
        guard let current, let now = VersionNumber(current) else {
            return Decision(entry: nil, seen: nil)
        }
        let before = lastSeen.flatMap(VersionNumber.init)
        if let before, now <= before {
            return Decision(entry: nil, seen: nil)
        }
        if before == nil, isFreshInstall {
            return Decision(entry: nil, seen: current)
        }
        var from = before == nil ? nil : lastSeen
        if before == nil {
            // The version before this one in the changelog, so that only this version's own section shows.
            from = changelog.first { VersionNumber($0.version).map { $0 < now } ?? false }?.version
        }
        let sections = Changelog.sections(changelog, from: from, to: current)
        guard !sections.isEmpty else {
            return Decision(entry: nil, seen: current)
        }
        return Decision(entry: WhatsNewEntry(version: current, from: from, sections: sections), seen: current)
    }

    /// the first change of the newest section, as the entry's line under its title: no Markdown marks
    ///
    /// - Parameter sections: the sections the entry shows, the newest first
    public static func excerpt(of sections: [ChangelogSection]) -> String? {
        highlights(of: sections, limit: 1).first
    }

    /// the first changes of the newest section, for the hero card of the Inbox: no Markdown marks, each cut at
    /// ``InboxEvent/excerptLength``. A bullet that only introduces a list ("Pipelines:") is left out.
    ///
    /// - Parameters:
    ///   - sections: the sections the entry shows, the newest first
    ///   - limit: how many to return at most
    /// - Returns: the changes' texts, in the file's order
    public static func highlights(of sections: [ChangelogSection], limit: Int) -> [String] {
        guard let body = sections.first?.body else {
            return []
        }
        var found: [String] = []
        for line in body.split(separator: "\n") where found.count < limit {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else {
                continue
            }
            let text = trimmed.dropFirst(2)
                .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasSuffix(":") else {
                continue
            }
            found.append(text.count > InboxEvent.excerptLength ? String(text.prefix(InboxEvent.excerptLength - 1)) + "…" : text)
        }
        return found
    }
}

extension InboxEvent {
    /// the start of the "What's new" entries' ids
    public static let whatsNewIDPrefix = "whatsnew|"

    /// Returns the entry of an update, one per version.
    ///
    /// - Parameters:
    ///   - entry: what the launch decided
    ///   - date: when the update was launched
    /// - Returns: the local event, which opens the "What's New" view for the versions since the last seen one
    public static func whatsNew(_ entry: WhatsNewEntry, at date: Date) -> InboxEvent {
        InboxEvent(
            id: whatsNewIDPrefix + entry.version, kind: .whatsNew, source: .local, title: "What's new in \(entry.version)",
            targetURL: AppRoute.whatsNew(from: entry.from, to: entry.version).url, occurredAt: date,
            headlineText: "\(AppIdentity.displayName) was updated", excerpt: WhatsNew.excerpt(of: entry.sections))
    }
}

extension AppModel {
    /// Adds the "What's New" entry at the first launch of a new version (the update's own doing, not a poll), and keeps the
    /// version as seen. Nothing is added when the changelog isn't in the bundle.
    ///
    /// - Parameters:
    ///   - info: the bundle's Info.plist entries
    ///   - changelog: the bundled changelog's sections
    func announceWhatsNew(info: [String: Any]?, changelog: [ChangelogSection]) {
        let store = preferencesStore
        let decision = WhatsNew.decide(
            current: info?["CFBundleShortVersionString"] as? String, lastSeen: store.lastSeenVersion,
            isFreshInstall: !store.welcomeCompleted, changelog: changelog)
        if let seen = decision.seen {
            store.lastSeenVersion = seen
        }
        if let entry = decision.entry {
            inbox.addLocal(.whatsNew(entry, at: dependencies.now()))
        }
    }
}
