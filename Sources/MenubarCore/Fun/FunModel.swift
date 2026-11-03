import Foundation
import Observation

/// The fun layer that plays in the app's calm spots: the butler's tip and the timer lines in the pane's footer, the small
/// surprises (a peeking butler, a nod, a joke, a fun fact), the Inbox Zero celebration, the merge celebration and Haiku's
/// daily batch of fresh lines. The views read what shows now; the app feeds it.
///
/// Everything sits behind the Easter eggs switch and the fun level (``apply(_:)``), and none of it waits for anything: a line
/// comes from the local pool at once, and Haiku's batch fills the pool in the background.
///
/// The rules that keep it out of the way:
/// - a surprise comes about once every one to two hours (Party: half to one), at most 6 a day (Party: 12), only between
///   08:00 and 19:00, never within 90 seconds of an alert and never while the user types or drags (``isBusy``);
/// - a peeking butler waits up to 20 minutes for a surface that shows, then lets go.
@MainActor
@Observable
public final class FunModel {
    /// where the peeking butler comes out
    public enum PeekEdge: String, CaseIterable, Sendable {
        case left, right, bottom, top
    }

    /// A kind of surface that shows the peeking butler: the menu bar pane, or any window (main, Settings, About).
    public enum PeekSurface: String, CaseIterable, Sendable {
        case menuPane, window

        /// the edges he may come out of on this surface: the pane lets him lean in from its right side only, over the
        /// footer's free space (the area rows' counts and chevrons are there above, the symbols on the left)
        public var edges: [PeekEdge] {
            switch self {
            case .menuPane: [.right]
            case .window: PeekEdge.allCases
            }
        }

        /// where along the edge he comes out, as a fraction of its length, for a peek's id: the pane's footer rows are in the
        /// lower part; a window anywhere in the middle
        func along(id: Int) -> Double {
            switch self {
            case .menuPane: 0.64 + Double((id * 37) % 9) / 100
            case .window: 0.22 + Double((id * 37) % 56) / 100
            }
        }
    }

    /// The butler that peeks out now, or waits for a surface to show him.
    public struct Peek: Equatable, Sendable {
        public var id: Int
        public var edge: PeekEdge
        public var armedAt: Date
        /// the surface he is for; `nil` for the first surface that shows
        public var surface: PeekSurface?
        /// how long he waits for his surface, in seconds
        public var patience: TimeInterval

        public init(
            id: Int, edge: PeekEdge, armedAt: Date, surface: PeekSurface? = nil, patience: TimeInterval = 20 * 60
        ) {
            self.id = id
            self.edge = edge
            self.armedAt = armedAt
            self.surface = surface
            self.patience = patience
        }
    }

    /// where a peek is in its three steps
    public enum PeekPhase: Sendable {
        /// coming out of the edge
        case slidingIn
        /// fully out, for ``holdDuration``
        case out
        /// going back
        case slidingOut
    }

    /// The peek that plays, owned by the surface that took him: the playback lives here, not in the view, so a refresh of
    /// the view can't cut it short.
    public struct Playing: Equatable, Sendable {
        public var peek: Peek
        /// where along the edge he is, 0 to 1
        public var along: Double
        public var phase: PeekPhase
        /// the surface that took him
        public var owner: String
    }

    /// The catch on screen.
    public struct CaughtPlay: Equatable, Sendable {
        public var result: Catch
        public var edge: PeekEdge
        public var along: Double
        public var owner: String
        public var id: Int
    }

    /// What one catch of the butler brings.
    public struct Catch: Equatable, Sendable {
        /// the secret line
        public var line: String
        /// what the catch unlocked, on every fifth
        public var unlock: String?
        /// how many catches there are now
        public var total: Int

        public init(line: String, unlock: String? = nil, total: Int) {
            self.line = line
            self.unlock = unlock
            self.total = total
        }
    }

    /// The line of the pane's footer.
    public struct FooterLine: Equatable, Sendable {
        public enum Kind: Sendable { case tip, timer, surprise }
        public var text: String
        public var kind: Kind

        public init(text: String, kind: Kind) {
            self.text = text
            self.kind = kind
        }
    }

    /// The merge celebration of a merge request, which its Merge card shows.
    public struct MergeCelebration: Equatable, Sendable {
        public var line: String
        public var level: FunLevel
        public var id: Int
    }

    /// the owner name of the menu bar pane's peek, which its panel beside the pane draws
    public static let paneOwner = "menuPane"

    /// The fun level of the running app, for the panels that live outside the view tree (the Inbox's big panel) and can't
    /// read the model from the environment. Set by ``apply(_:)``.
    public static var currentLevel: FunLevel?

    // MARK: State

    /// the fun level while the easter eggs are on; `nil` with them off, and then nothing plays
    public private(set) var level: FunLevel?
    /// the butler that waits for a surface to show him
    public private(set) var peek: Peek?
    /// the butler that is out now, which the surface that took him draws
    public private(set) var playing: Playing?
    /// the catch that plays now: the surprised butler in the spot where he was
    public private(set) var caughtPlay: CaughtPlay?
    /// how many times the peeking butler was caught
    public private(set) var catches: Int
    /// the footer line a surprise set, until its time
    public private(set) var surpriseLine: (text: String, until: Date)?
    /// the merge celebrations by merge request reference
    public private(set) var merges: [String: MergeCelebration] = [:]
    /// counts the nods; the status icon's nod follows it
    public private(set) var nodCount = 0
    /// the surfaces that show now, with how many of each: the pane while it is open, the windows that are on screen
    public private(set) var shownSurfaces: [PeekSurface: Int] = [:]

    // MARK: Hooks the app sets

    /// my running builds, for a build's birthday
    @ObservationIgnored public var runningBuilds: @MainActor () -> [Build] = { [] }
    /// whether Reduce Motion is on; the app sets it
    @ObservationIgnored public var reduceMotion: @MainActor () -> Bool = { false }
    /// whether the user types or drags, which holds a surprise back; the UI sets it
    @ObservationIgnored public var isBusy: @MainActor () -> Bool = { false }
    /// asks Haiku for the day's batch of lines; `nil` while Claude is off
    @ObservationIgnored public var askBatch: @MainActor (Date) async -> [String: [String]]? = { _ in nil }
    /// makes the status icon's butler nod once
    @ObservationIgnored public var nod: @MainActor () -> Void = {}
    /// shows a sample alert of a moment: the line, the celebration, whether it is a green one; returns whether it showed
    @ObservationIgnored public var showSample: @MainActor (String, FunCelebration?, Bool) -> Bool = { _, _, _ in false }

    // MARK: Private

    @ObservationIgnored private let store: FunStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let random: @Sendable (Int) -> Int
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastAlert: Date?
    @ObservationIgnored private var peekCount = 0
    @ObservationIgnored private var timerLines: [String: String] = [:]
    @ObservationIgnored private var inboxLines: [String: String] = [:]
    @ObservationIgnored private var inboxZeroDay: String?
    @ObservationIgnored private var mergeCount = 0
    @ObservationIgnored private var playback: Task<Void, Never>?
    @ObservationIgnored private var outSince: Date?

    /// how long he takes to come out
    public static let slideDuration: Duration = .milliseconds(400)
    /// how long he is fully out, counted from the end of the slide-in
    public static let holdDuration: Duration = .milliseconds(2500)
    /// how long he takes to go back
    public static let leaveDuration: Duration = .milliseconds(220)
    /// he doesn't duck for the pointer while he has been out for less than this
    public static let duckGrace: TimeInterval = 1.5
    /// how long the catch stays: with an unlock a little longer
    public static let caughtDuration: Duration = .seconds(4)
    /// how long a footer line from a surprise stays
    public static let surpriseLineDuration: TimeInterval = 30 * 60
    /// how long an armed peek waits for a surface
    public static let peekPatience: TimeInterval = 20 * 60
    /// how long a peek that Surprise Me queued for the menu bar pane waits for the pane to open
    public static let paneQueuePatience: TimeInterval = 60
    /// how long after an alert nothing surprising happens
    public static let alertQuiet: TimeInterval = 90
    /// how often the loop looks
    public static let tickInterval: Duration = .seconds(5 * 60)

    /// - Parameters:
    ///   - store: what the fun layer keeps
    ///   - now: the time
    ///   - clock: sleeps between two looks
    ///   - calendar: the calendar
    ///   - random: a number from 0 up to the given limit, which tests set
    public init(
        store: FunStore, now: @escaping @Sendable () -> Date, clock: any Clock<Duration> = ContinuousClock(),
        calendar: Calendar = .current, random: @escaping @Sendable (Int) -> Int = { Int.random(in: 0..<max($0, 1)) }
    ) {
        self.store = store
        self.now = now
        self.clock = clock
        self.calendar = calendar
        self.random = random
        catches = store.snapshot.catches
    }

    // MARK: - Settings and the loop

    /// Follows the preferences: the level while the eggs are on.
    public func apply(_ preferences: Preferences) {
        let next: FunLevel? = preferences.easterEggs ? preferences.funLevel : nil
        guard next != level else {
            return
        }
        level = next
        Self.currentLevel = next
        if next?.showsMoments != true {
            peek = nil
            playing = nil
            caughtPlay = nil
            playback?.cancel()
            surpriseLine = nil
        }
    }

    /// Starts the loop that asks Haiku for the day's batch and lets a surprise come now and then.
    public func start() {
        guard loop == nil else {
            return
        }
        store.noteUse(now: now())
        loop = Task { [weak self] in
            // The first look waits a little, so the launch isn't busy with it.
            try? await self?.clock.sleep(for: .seconds(20))
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                await self.tick()
                do {
                    try await self.clock.sleep(for: Self.tickInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// Stops the loop.
    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One look: asks Haiku for the batch when one is due, and shows a surprise when one is due and the moment is calm.
    func tick() async {
        guard let level, level.showsMoments else {
            return
        }
        let date = now()
        if store.reserveBatch(now: date) {
            if let lines = await askBatch(date) {
                store.addBatch(lines, now: now())
            }
        }
        maybeSurprise(now: now(), level: level)
    }

    // MARK: - The surprises

    /// Notes that an alert shows now, which keeps the surprises away for a minute and a half.
    public func alertShown() {
        lastAlert = now()
    }

    /// whether the moment is calm: between 08:00 and 19:00, no alert lately, and the user isn't typing or dragging
    func isCalm(at date: Date) -> Bool {
        let hour = calendar.component(.hour, from: date)
        guard (8..<19).contains(hour) else {
            return false
        }
        if let lastAlert, date.timeIntervalSince(lastAlert) < Self.alertQuiet {
            return false
        }
        return !isBusy()
    }

    /// the time to the next surprise, in seconds: one to two hours, at Party half to one
    func interval(for level: FunLevel) -> TimeInterval {
        let base: TimeInterval = level.isParty ? 1800 : 3600
        return base + TimeInterval(random(Int(base) + 1))
    }

    func maybeSurprise(now date: Date, level: FunLevel) {
        let cap = level.isParty ? 12 : 6
        guard let due = store.snapshot.nextSurprise else {
            store.schedule(next: date.addingTimeInterval(interval(for: level)))
            return
        }
        guard date >= due else {
            return
        }
        guard store.surprisesToday(now: date) < cap else {
            // The day's surprises are used up: tomorrow morning, at the earliest.
            let tomorrow = calendar.startOfDay(for: date).addingTimeInterval(24 * 3600)
            store.schedule(next: tomorrow.addingTimeInterval(8 * 3600))
            return
        }
        guard isCalm(at: date) else {
            store.schedule(next: date.addingTimeInterval(5 * 60))
            return
        }
        fireSurprise(at: date)
        store.noteSurprise(now: date, next: date.addingTimeInterval(interval(for: level)))
    }

    /// the kinds of a random surprise, with their weights: the peek is the favorite
    enum Kind: CaseIterable {
        case peek, nod, joke, funFact

        var weight: Int {
            switch self {
            case .peek: 4
            case .nod: 2
            case .joke: 2
            case .funFact: 2
            }
        }
    }

    func randomKind() -> Kind {
        var roll = random(Kind.allCases.reduce(0) { $0 + $1.weight })
        for kind in Kind.allCases {
            if roll < kind.weight {
                return kind
            }
            roll -= kind.weight
        }
        return .peek
    }

    @discardableResult
    func fireSurprise(at date: Date, kind: Kind? = nil) -> Kind {
        let kind = kind ?? randomKind()
        switch kind {
        case .peek:
            // A surface that shows now gets him, so he is seen; with none showing he waits for the first one.
            let shown = PeekSurface.allCases.filter { (shownSurfaces[$0] ?? 0) > 0 }
            armPeek(at: date, surface: shown.isEmpty ? nil : shown[random(shown.count) % shown.count])
        case .nod:
            nodCount += 1
            nod()
        case .joke:
            surpriseLine = (store.draw(.joke, now: date, seed: random(1000)), date.addingTimeInterval(Self.surpriseLineDuration))
        case .funFact:
            surpriseLine = (funFact(at: date), date.addingTimeInterval(Self.surpriseLineDuration))
        }
        return kind
    }

    private func funFact(at date: Date) -> String {
        let stored = store.snapshot
        let days = stored.firstUse.map { max(1, calendar.dateComponents([.day], from: $0, to: date).day ?? 1) } ?? 1
        return store.draw(
            .funFact, now: date, seed: random(1000),
            values: ["{builds}": format(stored.buildsSeen), "{greens}": format(stored.greens), "{days}": format(days)])
    }

    private func format(_ number: Int) -> String {
        number.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    /// Triggers a random surprise now, whatever the caps and quiet hours say, so the user can see them (Settings → General →
    /// Surprise Me).
    ///
    /// - Returns: what happened, in a sentence for the button's caption
    @discardableResult
    public func surpriseMe() -> String {
        guard let level else {
            return "Turn the easter eggs on first."
        }
        let date = now()
        let choices: [() -> String] = [
            { self.sample(.redemption, "redemption", .confetti, level: level) },
            { self.sample(.streak, "streak", .confetti, level: level) },
            { self.sample(.fridayFail, "Friday failure", nil, level: level, success: false) },
            { self.sample(.longBuild, "long build", nil, level: level) },
            {
                self.armPeek(at: date, surface: .window)
                return "The butler will peek out of a window soon."
            },
            {
                if self.reduceMotion() {
                    return "Reduce Motion is on, so the butler stays put in the menu bar."
                }
                self.nodCount += 1
                self.nod()
                return "The butler hopped in the menu bar."
            },
            {
                self.surpriseLine = (self.funFact(at: date), date.addingTimeInterval(Self.surpriseLineDuration))
                return "A fun fact is in the pane's footer."
            },
        ] + (level.isParty ? [{ self.sample(.redemption, "New Year", .fireworks, level: level) }] : [])
        // About one in three is the peek in the menu bar pane, so it can be found: it plays the next time the pane opens.
        if random(3) == 0 {
            return queuePanePeek(at: date)
        }
        return choices[random(choices.count) % choices.count]()
    }

    /// Queues a peek for the menu bar pane: it plays the next time the pane opens within ``paneQueuePatience``.
    ///
    /// - Parameter date: the time
    /// - Returns: what happened, in a sentence for the button's caption
    @discardableResult
    public func queuePanePeek(at date: Date) -> String {
        armPeek(at: date, surface: .menuPane, patience: Self.paneQueuePatience)
        return "Open the menu bar pane to find him."
    }

    private func sample(_ key: FunKey, _ name: String, _ celebration: FunCelebration?, level: FunLevel, success: Bool = true) -> String {
        let date = now()
        var line = store.draw(key, now: date, seed: random(1000), values: ["{d}": "1h12m"])
        if key == .streak {
            line = "🔥 10 green in a row. " + line
        }
        guard showSample(line, level.animates ? celebration : nil, success) else {
            return "A sample alert needs a project first. The \(name) line: \(line)"
        }
        return "A \(name) alert is on its way."
    }

    // MARK: - The peek

    private func armPeek(at date: Date, surface: PeekSurface? = nil, patience: TimeInterval = FunModel.peekPatience) {
        peekCount += 1
        let edges = surface?.edges ?? PeekEdge.allCases
        peek = Peek(
            id: peekCount, edge: edges[random(edges.count) % edges.count], armedAt: date, surface: surface, patience: patience)
    }

    /// Notes that a surface shows or doesn't show any more, so a random peek can pick one that is on screen.
    ///
    /// - Parameters:
    ///   - surface: the kind of surface
    ///   - isShown: whether it appeared (`true`) or went away
    public func surface(_ surface: PeekSurface, isShown: Bool) {
        shownSurfaces[surface, default: 0] = max(0, (shownSurfaces[surface] ?? 0) + (isShown ? 1 : -1))
    }

    /// Takes the armed peek for a surface that shows now and plays him there: slide in, fully out for 2.5 s, slide out. The
    /// playback runs here on the model's clock, so a refresh of the surface's view can't cut it short.
    ///
    /// - Parameters:
    ///   - busy: whether the user types or drags
    ///   - edges: the edges the surface lets him come out of; a peek for another edge waits for another surface
    ///   - owner: the surface's own name, which tells its overlay that he is its to draw
    ///   - surface: the kind of surface this is; a peek made for the other kind waits for it
    /// - Returns: the peek; `nil` when none is armed, one plays already, it waited too long, or the moment isn't calm
    @discardableResult
    public func claimPeek(
        busy: Bool, edges: Set<PeekEdge> = Set(PeekEdge.allCases), owner: String = "surface", surface: PeekSurface? = nil
    ) -> Peek? {
        guard let level, level.showsMoments, let armed = peek, playing == nil, caughtPlay == nil, !busy,
            edges.contains(armed.edge), armed.surface == nil || armed.surface == surface
        else {
            return nil
        }
        let date = now()
        guard date.timeIntervalSince(armed.armedAt) < armed.patience else {
            peek = nil
            return nil
        }
        if let lastAlert, date.timeIntervalSince(lastAlert) < Self.alertQuiet {
            return nil
        }
        peek = nil
        let along = (armed.surface ?? .window).along(id: armed.id)
        playing = Playing(peek: armed, along: along, phase: .slidingIn, owner: owner)
        playback = Task { [weak self, clock] in
            try? await clock.sleep(for: Self.slideDuration)
            guard !Task.isCancelled, let self, self.playing != nil else { return }
            self.playing?.phase = .out
            self.outSince = self.now()
            try? await clock.sleep(for: Self.holdDuration)
            guard !Task.isCancelled else { return }
            await self.leave()
        }
        return armed
    }

    /// Takes him back: slides out, then he is gone.
    private func leave() async {
        guard playing != nil else { return }
        playing?.phase = .slidingOut
        try? await clock.sleep(for: Self.leaveDuration)
        if playing?.phase == .slidingOut {
            playing = nil
        }
    }

    /// The pointer rested on him: he ducks, unless he has been out for less than ``duckGrace``, so the pointer that is
    /// often near where he comes out can't send him back at once.
    ///
    /// - Returns: whether he ducks
    @discardableResult
    public func duck() -> Bool {
        guard playing?.phase == .out, let outSince, now().timeIntervalSince(outSince) >= Self.duckGrace else {
            return false
        }
        playback?.cancel()
        playback = Task { [weak self] in await self?.leave() }
        return true
    }

    /// the hats the catches unlocked, in order: the party hat at 5, the witch's at 10, Santa's at 15, the New Year's at 20
    public static let unlockedHats: [ButlerHat] = [.party, .witch, .santa, .newYear]

    /// the hat the peeking butler wears after so many catches; `nil` before the fifth
    public static func peekHat(catches: Int) -> ButlerHat? {
        let steps = catches / 5
        return steps == 0 ? nil : unlockedHats[min(steps, unlockedHats.count) - 1]
    }

    /// Notes a catch of the peeking butler.
    ///
    /// - Returns: his secret line, and on every fifth catch the hat he now wears
    public func catchButler() -> Catch {
        let total = store.noteCatch()
        catches = total
        let line = store.draw(.caught, now: now(), seed: total)
        var unlock: String?
        if total % 5 == 0, let hat = Self.peekHat(catches: total) {
            let name: String
            switch hat {
            case .party: name = "a party hat"
            case .witch: name = "a witch's hat"
            case .santa: name = "a Santa hat"
            case .newYear: name = "a New Year's hat"
            case .carnival: name = "a jester's cap"
            case .easter: name = "an Easter outfit"
            }
            unlock = "\(total) catches: he wears \(name) from now on."
        }
        let result = Catch(line: line, unlock: unlock, total: total)
        // The peek turns into the caught pose in the same spot, for a few seconds.
        if let playing {
            playback?.cancel()
            self.playing = nil
            caughtPlay = CaughtPlay(result: result, edge: playing.peek.edge, along: playing.along, owner: playing.owner, id: total)
            playback = Task { [weak self, clock] in
                try? await clock.sleep(for: unlock == nil ? Self.caughtDuration : Self.caughtDuration + .seconds(2))
                guard !Task.isCancelled else { return }
                self?.caughtPlay = nil
            }
        }
        return result
    }

    // MARK: - The footer

    /// Returns the line of the pane's footer: a surprise's line while it lasts, else the timer line that is on (lunch, the
    /// way home, Friday's warning, the yawn, a build's birthday, the anniversary), else the butler's tip of the day.
    ///
    /// - Parameter date: the time
    /// - Returns: the line; `nil` at Subtle and with the eggs off
    public func footerLine(at date: Date) -> FooterLine? {
        guard let level, level.showsMoments else {
            return nil
        }
        if let surpriseLine, surpriseLine.until > date {
            return FooterLine(text: surpriseLine.text, kind: .surprise)
        }
        if let active = FunTimers.active(now: date, calendar: calendar, running: runningBuilds(), firstUse: store.snapshot.firstUse) {
            let text: String
            if let known = timerLines[active.window] {
                text = known
            } else {
                text = store.draw(active.key, now: date, seed: random(1000), values: active.values)
                timerLines[active.window] = text
            }
            if active.key == .anniversary {
                store.noteAnniversary(years: FunTimers.anniversaryYears(now: date, calendar: calendar, firstUse: store.snapshot.firstUse) ?? 0)
            }
            return FooterLine(text: text, kind: .timer)
        }
        return FooterLine(text: store.tip(now: date), kind: .tip)
    }

    /// the tip of the day, for the empty states; `nil` at Subtle and with the eggs off
    public func tip(at date: Date) -> String? {
        guard let level, level.showsMoments else {
            return nil
        }
        return store.tip(now: date)
    }

    // MARK: - Inbox Zero and the merge

    /// Returns the line under "Inbox Zero": one a day, so the empty state doesn't change while it shows.
    public func inboxZeroLine(at date: Date) -> String? {
        guard let level, level.showsMoments else {
            return nil
        }
        let day = store.dayKey(date)
        if let line = inboxLines[day] {
            return line
        }
        let ordinal = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let line = store.draw(.inboxZero, now: date, seed: ordinal)
        inboxLines = [day: line]
        return line
    }

    /// Notes that the Inbox just became empty.
    ///
    /// - Returns: whether to celebrate with confetti: once a day
    public func inboxZeroReached(at date: Date) -> Bool {
        guard let level, level.animates else {
            return false
        }
        let day = store.dayKey(date)
        guard inboxZeroDay != day else {
            return false
        }
        inboxZeroDay = day
        return true
    }

    /// Notes a merge request merged from the app: its Merge card shows a line and confetti.
    ///
    /// - Parameter reference: the merge request's reference
    public func merged(reference: String) {
        guard let level, level.showsMoments else {
            return
        }
        mergeCount += 1
        merges[reference] = MergeCelebration(
            line: store.draw(.merged, now: now(), seed: mergeCount), level: level, id: mergeCount)
    }

    // MARK: - The About window

    /// the line of the About window's credits about the catches; `nil` before the first
    public var caughtLine: String? {
        catches > 0 ? "Butlers caught: \(catches)" : nil
    }
}
