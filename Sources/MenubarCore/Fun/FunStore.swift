import Foundation

/// What the fun layer remembers across launches: the green streak and the counters, the pool of Haiku's fresh lines and
/// which lines were seen lately, the once-a-day marks, the daily tip, the surprises' schedule and the catches.
///
/// One small JSON file in Application Support; losing it is harmless, everything starts over. It is read from the check
/// (off the main thread) and from the main actor, so the state sits behind a lock and every change is saved at once.
///
/// - Lines are drawn, not repeated: a drawn line is hashed into ``Stored/seen`` and not drawn again for
///   ``repeatGap``; a built-in line that was seen stands in only when nothing unseen is left.
/// - Haiku's lines come in one batch a day (``FunBatch``); they sit in ``Stored/pool`` until drawn.
public final class FunStore: @unchecked Sendable {
    /// how long a drawn line isn't drawn again: two weeks
    public static let repeatGap: TimeInterval = 14 * 24 * 3600
    /// the most lines of one key kept from Haiku
    public static let poolLimit = 12
    /// the most batch calls to Haiku in a day: the daily one, and one top-up when the pool runs low
    public static let batchCap = 2

    /// everything that is kept
    public struct Stored: Codable, Equatable, Sendable {
        /// the green builds in a row, over every followed job; a red build ends it
        public var greenStreak = 0
        /// the longest streak so far
        public var bestStreak = 0
        /// the finished followed builds the app saw
        public var buildsSeen = 0
        /// how many of them were green
        public var greens = 0
        /// the first time the fun layer ran, for the app's anniversary
        public var firstUse: Date?
        /// Haiku's lines not drawn yet, by ``FunKey`` raw value
        public var pool: [String: [String]] = [:]
        /// the hashes of the lines drawn lately, with when
        public var seen: [String: Date] = [:]
        /// the local day of the last batch call, and how many calls that day
        public var batchDay: String?
        public var batchAsks = 0
        /// today's tip, drawn once a day
        public var tipDay: String?
        public var tipLine: String?
        /// the once-a-day marks: the key and the local day it showed
        public var marks: [String: String] = [:]
        /// the surprises of the day, and when the next one is due
        public var surpriseDay: String?
        public var surprisesToday = 0
        public var nextSurprise: Date?
        /// how many times the peeking butler was caught
        public var catches = 0
        /// the last anniversary celebrated, in years
        public var anniversaryYears = 0

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case greenStreak, bestStreak, buildsSeen, greens, firstUse, pool, seen, batchDay, batchAsks, tipDay, tipLine
            case marks, surpriseDay, surprisesToday, nextSurprise, catches, anniversaryYears
        }

        // Every key is optional: a file from another version still reads.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            greenStreak = try c.decodeIfPresent(Int.self, forKey: .greenStreak) ?? 0
            bestStreak = try c.decodeIfPresent(Int.self, forKey: .bestStreak) ?? 0
            buildsSeen = try c.decodeIfPresent(Int.self, forKey: .buildsSeen) ?? 0
            greens = try c.decodeIfPresent(Int.self, forKey: .greens) ?? 0
            firstUse = try c.decodeIfPresent(Date.self, forKey: .firstUse)
            pool = try c.decodeIfPresent([String: [String]].self, forKey: .pool) ?? [:]
            seen = try c.decodeIfPresent([String: Date].self, forKey: .seen) ?? [:]
            batchDay = try c.decodeIfPresent(String.self, forKey: .batchDay)
            batchAsks = try c.decodeIfPresent(Int.self, forKey: .batchAsks) ?? 0
            tipDay = try c.decodeIfPresent(String.self, forKey: .tipDay)
            tipLine = try c.decodeIfPresent(String.self, forKey: .tipLine)
            marks = try c.decodeIfPresent([String: String].self, forKey: .marks) ?? [:]
            surpriseDay = try c.decodeIfPresent(String.self, forKey: .surpriseDay)
            surprisesToday = try c.decodeIfPresent(Int.self, forKey: .surprisesToday) ?? 0
            nextSurprise = try c.decodeIfPresent(Date.self, forKey: .nextSurprise)
            catches = try c.decodeIfPresent(Int.self, forKey: .catches) ?? 0
            anniversaryYears = try c.decodeIfPresent(Int.self, forKey: .anniversaryYears) ?? 0
        }
    }

    private let lock = NSLock()
    private var stored: Stored
    private let file: URL?
    private let calendar: Calendar

    /// - Parameters:
    ///   - file: where the state is kept; `nil` keeps it in memory only, as the tests do
    ///   - calendar: the calendar whose days the marks and the caps count in
    public init(file: URL? = nil, calendar: Calendar = .current) {
        self.file = file
        self.calendar = calendar
        if let file, let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            stored = (try? decoder.decode(Stored.self, from: data)) ?? Stored()
        } else {
            stored = Stored()
        }
    }

    /// the state now
    public var snapshot: Stored {
        lock.withLock { stored }
    }

    /// Changes the state under the lock and saves it when it changed.
    @discardableResult
    func mutate<Result>(_ body: (inout Stored) -> Result) -> Result {
        lock.withLock {
            let before = stored
            let result = body(&stored)
            if stored != before {
                save()
            }
            return result
        }
    }

    private func save() {
        guard let file else {
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(stored) else {
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - The days

    /// Returns a local day as text, like `2026-11-03`.
    public func dayKey(_ date: Date) -> String {
        EggMemory.dayKey(date, calendar)
    }

    /// Notes that a day passes with a once-a-day mark: `true` the first time on a day, `false` after.
    ///
    /// - Parameters:
    ///   - key: the mark's name
    ///   - now: the time
    public func mark(_ key: String, now: Date) -> Bool {
        let day = dayKey(now)
        return mutate { stored in
            guard stored.marks[key] != day else {
                return false
            }
            stored.marks[key] = day
            return true
        }
    }

    // MARK: - The counters

    /// What a finished build did to the counters.
    public struct Noted: Equatable, Sendable {
        /// the green streak after the build
        public var streak: Int
        public var buildsSeen: Int
    }

    /// Counts a finished followed build: a green one adds to the streak, a red one ends it, an aborted one does neither.
    ///
    /// - Parameters:
    ///   - result: the build's result
    ///   - now: the time, which sets the first use when nothing is kept yet
    @discardableResult
    public func noteFinished(_ result: BuildResult, now: Date) -> Noted {
        mutate { stored in
            if stored.firstUse == nil {
                stored.firstUse = now
            }
            stored.buildsSeen += 1
            switch result {
            case .success:
                stored.greens += 1
                stored.greenStreak += 1
                stored.bestStreak = max(stored.bestStreak, stored.greenStreak)
            case .failure, .unstable:
                stored.greenStreak = 0
            default:
                break
            }
            return Noted(streak: stored.greenStreak, buildsSeen: stored.buildsSeen)
        }
    }

    /// Records the first use, once.
    public func noteUse(now: Date) {
        mutate { stored in
            if stored.firstUse == nil {
                stored.firstUse = now
            }
        }
    }

    // MARK: - The lines

    /// Returns the hash of a line, the same in every launch (Swift's own hashes change from one launch to the next).
    static func hash(_ line: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in line.utf8 {
            value = (value ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return String(value, radix: 16)
    }

    /// Draws a line of a key: one of Haiku's fresh lines when the pool has one, else a built-in one that wasn't drawn in the
    /// last two weeks, else the built-in one drawn longest ago. The drawn line is marked as seen.
    ///
    /// - Parameters:
    ///   - key: the kind of line
    ///   - now: the time
    ///   - seed: picks among equal choices, so a test can say which
    ///   - values: the tokens' values, like `["{d}": "1h12m"]`
    ///   - builtInFirst: draws a built-in line before Haiku's, for a key that mixes real tips with jokes
    /// - Returns: the line, with its tokens filled
    public func draw(
        _ key: FunKey, now: Date, seed: Int = 0, values: [String: String] = [:], builtInFirst: Bool = false
    ) -> String {
        let line = mutate { stored -> String in
            stored.seen = stored.seen.filter { now.timeIntervalSince($0.value) < Self.repeatGap }
            let builtIn = FunLines.lines(for: key)
            func fromPool() -> String? {
                var pool = stored.pool[key.rawValue] ?? []
                guard let index = pool.firstIndex(where: { stored.seen[Self.hash($0)] == nil }) else {
                    return nil
                }
                let line = pool.remove(at: index)
                stored.pool[key.rawValue] = pool.isEmpty ? nil : pool
                return line
            }
            func fromBuiltIn() -> String? {
                let unseen = builtIn.filter { stored.seen[Self.hash($0)] == nil }
                return unseen.isEmpty ? nil : unseen[abs(seed) % unseen.count]
            }
            let chosen: String
            if builtInFirst {
                chosen = fromBuiltIn() ?? fromPool() ?? Self.oldest(of: builtIn, in: stored.seen)
            } else {
                chosen = fromPool() ?? fromBuiltIn() ?? Self.oldest(of: builtIn, in: stored.seen)
            }
            stored.seen[Self.hash(chosen)] = now
            return chosen
        }
        return FunLines.fill(line, values)
    }

    private static func oldest(of lines: [String], in seen: [String: Date]) -> String {
        lines.min { (seen[hash($0)] ?? .distantPast) < (seen[hash($1)] ?? .distantPast) } ?? ""
    }

    /// how many of Haiku's lines wait for a key
    public func poolCount(_ key: FunKey) -> Int {
        lock.withLock { stored.pool[key.rawValue]?.count ?? 0 }
    }

    /// Returns the butler's tip of the day: drawn once a day, so it stays while the day lasts. Every other day it starts
    /// with a built-in tip, which are the real ones about the app, then with Haiku's.
    ///
    /// - Parameter now: the time
    public func tip(now: Date) -> String {
        let day = dayKey(now)
        if let line = lock.withLock({ stored.tipDay == day ? stored.tipLine : nil }) {
            return line
        }
        let ordinal = calendar.ordinality(of: .day, in: .year, for: now) ?? 1
        let line = draw(.tip, now: now, seed: ordinal, builtInFirst: ordinal % 2 == 0)
        mutate {
            $0.tipDay = day
            $0.tipLine = line
        }
        return line
    }

    // MARK: - Haiku's daily batch

    /// Returns whether a batch call is due: the first of a day, or one top-up while four or more keys ran dry; never more
    /// than ``batchCap`` a day.
    ///
    /// - Parameter now: the time
    public func needsBatch(now: Date) -> Bool {
        let day = dayKey(now)
        return lock.withLock {
            let asks = stored.batchDay == day ? stored.batchAsks : 0
            guard asks < Self.batchCap else {
                return false
            }
            if asks == 0 {
                return true
            }
            let dry = FunKey.allCases.filter { stored.pool[$0.rawValue]?.isEmpty ?? true }.count
            return dry >= 4
        }
    }

    /// Notes that a batch call goes out now: it counts whether Claude answers or not, so a failing call isn't repeated all day.
    ///
    /// - Parameter now: the time
    /// - Returns: `false` when today's calls are used up
    public func reserveBatch(now: Date) -> Bool {
        guard needsBatch(now: now) else {
            return false
        }
        let day = dayKey(now)
        mutate { stored in
            stored.batchAsks = (stored.batchDay == day ? stored.batchAsks : 0) + 1
            stored.batchDay = day
        }
        return true
    }

    /// Adds the lines of a batch to the pool: only the usable ones (``FunBatch/usable(_:for:)``), none that is in the pool
    /// or was seen lately, at most ``poolLimit`` a key.
    ///
    /// - Parameters:
    ///   - lines: Haiku's lines by key name; unknown keys are ignored
    ///   - now: the time
    /// - Returns: how many lines were added
    @discardableResult
    public func addBatch(_ lines: [String: [String]], now: Date) -> Int {
        mutate { stored in
            var added = 0
            for key in FunKey.allCases {
                for raw in lines[key.rawValue] ?? [] {
                    guard let line = FunBatch.usable(raw, for: key) else {
                        continue
                    }
                    var pool = stored.pool[key.rawValue] ?? []
                    let known = pool.contains(line) || stored.seen[Self.hash(line)] != nil
                    guard !known, pool.count < Self.poolLimit else {
                        continue
                    }
                    pool.append(line)
                    stored.pool[key.rawValue] = pool
                    added += 1
                }
            }
            return added
        }
    }

    // MARK: - The surprises

    /// Notes a surprise that was shown: counts it for the day and schedules the next.
    ///
    /// - Parameters:
    ///   - now: the time
    ///   - next: when the next one is due
    public func noteSurprise(now: Date, next: Date) {
        let day = dayKey(now)
        mutate { stored in
            stored.surprisesToday = (stored.surpriseDay == day ? stored.surprisesToday : 0) + 1
            stored.surpriseDay = day
            stored.nextSurprise = next
        }
    }

    /// how many surprises showed today
    public func surprisesToday(now: Date) -> Int {
        let day = dayKey(now)
        return lock.withLock { stored.surpriseDay == day ? stored.surprisesToday : 0 }
    }

    /// Schedules the next surprise without counting one.
    public func schedule(next: Date) {
        mutate { $0.nextSurprise = next }
    }

    // MARK: - The catches

    /// Notes a catch of the peeking butler.
    ///
    /// - Returns: how many catches there are now
    @discardableResult
    public func noteCatch() -> Int {
        mutate {
            $0.catches += 1
            return $0.catches
        }
    }

    /// Notes the anniversary celebrated.
    public func noteAnniversary(years: Int) {
        mutate { $0.anniversaryYears = years }
    }
}
