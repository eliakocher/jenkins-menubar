import Foundation

/// What the easter eggs remember from one check to the next (`docs/easter-eggs.md`, rule 8): the red builds in a row per
/// job, the green streak, the spellcheck demo count, which once-a-day lines showed today and the year of the last alert.
///
/// Losing it is harmless: the eggs start over.
public struct EggMemory: Codable, Hashable, Sendable {
    /// the FAILURE or UNSTABLE builds alerted in a row per job; a job without any red build has no entry
    public var redRuns: [String: Int]
    /// the local day the green count below belongs to, like `2026-10-29`
    public var greenDay: String?
    /// the followed builds that finished SUCCESS since local midnight
    public var greensToday: Int
    /// whether a followed build finished FAILURE or UNSTABLE since local midnight
    public var redToday: Bool
    /// whether the butler wears a party hat: from the third green build of a day without a red one, until the next red
    public var partyHat: Bool
    /// how many times the search has shown the spellcheck demo note
    public var spellcheckDemos: Int
    /// the day each once-a-day line last showed, by the line's key
    public var shown: [String: String]
    /// the year of the last alert, for the first build of the year
    public var lastAlertYear: Int?

    public init(
        redRuns: [String: Int] = [:], greenDay: String? = nil, greensToday: Int = 0, redToday: Bool = false,
        partyHat: Bool = false, spellcheckDemos: Int = 0, shown: [String: String] = [:], lastAlertYear: Int? = nil
    ) {
        self.redRuns = redRuns
        self.greenDay = greenDay
        self.greensToday = greensToday
        self.redToday = redToday
        self.partyHat = partyHat
        self.spellcheckDemos = spellcheckDemos
        self.shown = shown
        self.lastAlertYear = lastAlertYear
    }

    private enum CodingKeys: String, CodingKey {
        case redRuns, greenDay, greensToday, redToday, partyHat, spellcheckDemos, shown, lastAlertYear
    }

    // Every key is optional, so a file from an older version, or a later one, still reads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            redRuns: try container.decodeIfPresent([String: Int].self, forKey: .redRuns) ?? [:],
            greenDay: try container.decodeIfPresent(String.self, forKey: .greenDay),
            greensToday: try container.decodeIfPresent(Int.self, forKey: .greensToday) ?? 0,
            redToday: try container.decodeIfPresent(Bool.self, forKey: .redToday) ?? false,
            partyHat: try container.decodeIfPresent(Bool.self, forKey: .partyHat) ?? false,
            spellcheckDemos: try container.decodeIfPresent(Int.self, forKey: .spellcheckDemos) ?? 0,
            shown: try container.decodeIfPresent([String: String].self, forKey: .shown) ?? [:],
            lastAlertYear: try container.decodeIfPresent(Int.self, forKey: .lastAlertYear))
    }

    /// Returns a local day as text, like `2026-10-29`.
    ///
    /// - Parameters:
    ///   - date: the time
    ///   - calendar: the calendar, whose time zone says where the day starts
    static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}

extension CacheFile where Value == EggMemory {
    /// what the easter eggs remember (EGG-01)
    public static var eggs: CacheFile { CacheFile("eggs") }
}

/// A hat the butler wears: a party hat during a green streak, a Santa hat all of December.
public enum ButlerHat: String, Codable, Hashable, Sendable, CaseIterable {
    case party
    case santa
}
