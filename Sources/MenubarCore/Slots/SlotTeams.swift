import Foundation

/// The teams and their members, from the team value: `Alpha: user1, user2; Bravo: user3`, a team per `;` or line, the
/// members' GitLab usernames after the colon, separated by commas or spaces (SLOT-13). A team is a property of its
/// people, as in the team's slot planning web tool: GitLab has no person → team mapping.
public struct SlotTeams: Hashable, Sendable {
    public struct Team: Hashable, Sendable {
        public var name: String
        /// GitLab usernames, without `@`
        public var members: [String]
    }

    /// the teams in the value's order
    public var teams: [Team]

    /// Reads the team value; `nil` when it is empty, or a part has no name, no colon or no member.
    ///
    /// - Parameter text: the value
    public init?(_ text: String) {
        var teams: [Team] = []
        let parts = text.split { $0 == ";" || $0.isNewline }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        for part in parts {
            guard let colon = part.firstIndex(of: ":") else { return nil }
            let name = part[..<colon].trimmingCharacters(in: .whitespaces)
            let members = part[part.index(after: colon)...]
                .split { $0 == "," || $0.isWhitespace }
                .map { String($0.drop { $0 == "@" }) }
                .filter { !$0.isEmpty }
            guard !name.isEmpty, !members.isEmpty else { return nil }
            teams.append(Team(name: name, members: members))
        }
        self.teams = teams
    }

    /// the team names in the value's order
    public var names: [String] { teams.map(\.name) }

    /// Returns a team's members; empty for a team the value doesn't name. The name's case doesn't count.
    public func members(of team: String) -> [String] {
        teams.first { $0.name.caseInsensitiveCompare(team) == .orderedSame }?.members ?? []
    }

    /// every member of every team, each once, in the value's order
    public var everyone: [String] {
        var seen: Set<String> = []
        return teams.flatMap(\.members).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Returns whether a username is one of the members; the case doesn't count.
    static func contains(_ members: [String], _ username: String) -> Bool {
        members.contains { $0.caseInsensitiveCompare(username) == .orderedSame }
    }
}

/// The work days per week of the members who don't work 5, from the team value `user1: 4, user2: 3` (SLOT-13).
public struct SlotWorkDays: Hashable, Sendable {
    /// the days by username, lowercased
    public var byMember: [String: Int]

    /// every member's 5 days
    public init() {
        byMember = [:]
    }

    /// Reads the team value; empty is 5 for everyone, `nil` when a part isn't `username: days` with 1 to 7 days.
    ///
    /// - Parameter text: the value, parts separated by commas, semicolons or lines
    public init?(_ text: String) {
        var byMember: [String: Int] = [:]
        let parts = text.split { $0 == "," || $0 == ";" || $0.isNewline }.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for part in parts {
            guard let separator = part.lastIndex(where: { $0 == ":" || $0 == "=" }) else { return nil }
            let name = part[..<separator].trimmingCharacters(in: .whitespaces).drop { $0 == "@" }
            let days = part[part.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, days.allSatisfy({ $0.isASCII && $0.isNumber }), let count = Int(days), (1...7).contains(count)
            else { return nil }
            byMember[name.lowercased()] = count
        }
        self.byMember = byMember
    }

    /// Returns a member's work days per week; 5 when the value doesn't name them.
    public func days(of member: String) -> Int {
        byMember[member.lowercased()] ?? 5
    }
}

/// What a slot can take under a chip, for its load (SLOT-08, SLOT-13).
public enum SlotCapacity: Hashable, Sendable {
    /// a squad's points per slot, from the squad capacity value, the same for every slot
    case points(Int)
    /// people, by their GitLab usernames, with their work days per week
    case people([String], workDays: SlotWorkDays)

    /// Returns the capacity of a slot: the points, or the people's working days from the code freeze up to the release
    /// (the release day not counted), weekdays only, each person's share of a 5-day week. No holidays and no time off,
    /// like the team's slot planning web tool, which has no holidays either.
    ///
    /// - Parameters:
    ///   - dates: the slot's dates; `nil` for a slot without dates, which has no capacity in people
    ///   - calendar: the calendar whose days count
    /// - Returns: the capacity in points or person-days; `nil` when there is none
    public func value(dates: SlotDates?, calendar: Calendar = .current) -> Double? {
        switch self {
        case .points(let points):
            return points > 0 ? Double(points) : nil
        case .people(let members, let workDays):
            guard let dates, !members.isEmpty else { return nil }
            let weekdays = Double(Self.weekdays(from: dates.codeFreeze, to: dates.release, calendar: calendar))
            let total = members.reduce(0.0) { $0 + weekdays * Double(workDays.days(of: $1)) / 5 }
            return total > 0 ? total : nil
        }
    }

    /// Returns the days from Monday to Friday in `[start, end)`.
    static func weekdays(from start: Date, to end: Date, calendar: Calendar) -> Int {
        var day = calendar.startOfDay(for: start)
        let end = calendar.startOfDay(for: end)
        var count = 0
        while day < end {
            if !calendar.isDateInWeekend(day) { count += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return count
    }
}

/// How full a slot is under its capacity, the tool's colors: below 80 % fine, up to 100 % tight, above full (SLOT-13).
public enum SlotLoadLevel: Hashable, Sendable {
    case fine
    case tight
    case over

    /// Returns the level of a load, `0.74` for 74 %.
    public init(_ load: Double) {
        self = load < 0.8 ? .fine : load <= 1 ? .tight : .over
    }
}
