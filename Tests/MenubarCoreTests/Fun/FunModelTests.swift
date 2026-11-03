import Foundation
import Testing

@testable import MenubarCore

/// FUN-08 to FUN-12: the footer, the timer lines, the surprises' caps and quiet times, the peek, the catches and Haiku's
/// daily batch. Claude is a fake runner, never a real `claude`.
@Suite("FunModel")
@MainActor
struct FunModelTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-11-02 is a Monday; the 6th a Friday; the 7th a Saturday
    private static func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func model(
        at date: Date, level: FunLevel? = .normal, store: FunStore? = nil, random: @escaping @Sendable (Int) -> Int = { _ in 0 }
    ) -> (FunModel, Clock, FunStore) {
        let clock = Clock(date)
        let store = store ?? FunStore(calendar: Self.calendar)
        let model = FunModel(store: store, now: { clock.now }, calendar: Self.calendar, random: random)
        model.apply(Preferences(easterEggs: level != nil, funLevel: level ?? .normal))
        return (model, clock, store)
    }

    private func build(started: Date, number: Int = 7, running: Bool = true) -> Build {
        Build(job: "MR-3", number: number, title: "t", kind: .mine, phase: .running, startedAt: started)
    }

    @Test("FUN-08 the footer shows the butler's tip at Normal and Party, none at Subtle or with the eggs off; one tip a day")
    func footerTip() {
        let (normal, _, _) = model(at: Self.date(4, 10))
        let tip = normal.footerLine(at: Self.date(4, 10))
        #expect(tip?.kind == .tip && !(tip?.text.isEmpty ?? true))
        #expect(normal.footerLine(at: Self.date(4, 15)) == tip)
        #expect(normal.footerLine(at: Self.date(5, 10)) != tip)
        #expect(model(at: Self.date(4, 10), level: .party).0.footerLine(at: Self.date(4, 10)) != nil)
        #expect(model(at: Self.date(4, 10), level: .subtle).0.footerLine(at: Self.date(4, 10)) == nil)
        #expect(model(at: Self.date(4, 10), level: nil).0.footerLine(at: Self.date(4, 10)) == nil)
        #expect(model(at: Self.date(4, 10), level: nil).0.tip(at: Self.date(4, 10)) == nil)
    }

    @Test("FUN-09 the timer lines: lunch, the way home, Friday's warning, the yawn, a build's birthday")
    func timers() {
        func key(_ date: Date, running: [Build] = [], firstUse: Date? = nil) -> FunKey? {
            FunTimers.active(now: date, calendar: Self.calendar, running: running, firstUse: firstUse)?.key
        }
        #expect(key(Self.date(4, 11, 59)) == nil && key(Self.date(4, 12)) == .lunch && key(Self.date(4, 12, 59)) == .lunch)
        #expect(key(Self.date(4, 13)) == nil && key(Self.date(7, 12, 30)) == nil)
        #expect(key(Self.date(4, 17, 29)) == nil && key(Self.date(4, 17, 30)) == .goHome && key(Self.date(4, 19)) == nil)
        // Friday: the warning from 16:00, the way home from 17:30; none at the weekend.
        #expect(key(Self.date(6, 15, 59)) == nil && key(Self.date(6, 16)) == .noDeploys && key(Self.date(6, 17, 29)) == .noDeploys)
        #expect(key(Self.date(6, 17, 30)) == .goHome && key(Self.date(7, 17, 45)) == nil)
        // The yawn, across midnight as one window.
        #expect(key(Self.date(4, 21, 59)) == nil && key(Self.date(4, 22)) == .midnightOil && key(Self.date(5, 3, 59)) == .midnightOil)
        #expect(
            FunTimers.active(now: Self.date(4, 23), calendar: Self.calendar, running: [], firstUse: nil)?.window
                == FunTimers.active(now: Self.date(5, 2), calendar: Self.calendar, running: [], firstUse: nil)?.window)
        // A build's birthday: the first ten minutes after a full hour.
        let now = Self.date(4, 10)
        #expect(key(now, running: [build(started: now.addingTimeInterval(-3600 - 120))]) == .birthday)
        #expect(key(now, running: [build(started: now.addingTimeInterval(-3600 - 11 * 60))]) == nil)
        #expect(key(now, running: [build(started: now.addingTimeInterval(-3000))]) == nil)
        let hours = FunTimers.active(now: now, calendar: Self.calendar, running: [build(started: now.addingTimeInterval(-3 * 3600 - 60))], firstUse: nil)
        #expect(hours?.values["{h}"] == "3 hours")
        // The anniversary: the first use's day, a year or more later.
        let first = Self.date(4, 9, year: 2025)
        #expect(key(Self.date(4, 12, year: 2026), firstUse: first) == .anniversary)
        #expect(key(Self.date(4, 12, year: 2025), firstUse: first) == .lunch)
        #expect(FunTimers.isFireworksDay(now: Self.date(1, 10, month: 1, year: 2027), calendar: Self.calendar, firstUse: nil))
        #expect(!FunTimers.isFireworksDay(now: Self.date(2, 10, month: 1, year: 2027), calendar: Self.calendar, firstUse: nil))
    }

    @Test("FUN-09 a timer line is drawn once per window, so the footer doesn't change while it shows")
    func timerLineStays() {
        let (model, _, store) = model(at: Self.date(4, 12, 5))
        let first = model.footerLine(at: Self.date(4, 12, 5))
        #expect(first?.kind == .timer)
        #expect(model.footerLine(at: Self.date(4, 12, 40)) == first)
        #expect(FunLines.lunch.contains(first?.text ?? ""))
        #expect(store.snapshot.seen.count == 1)
    }

    @Test("FUN-10 a surprise comes in a calm spot only: 08:00 to 19:00, not just after an alert, never while the user types")
    func quietTimes() {
        let (model, clock, store) = model(at: Self.date(4, 10))
        model.maybeSurprise(now: clock.now, level: .normal)
        let due = store.snapshot.nextSurprise
        #expect(due != nil && due! >= clock.now.addingTimeInterval(3600) && due! <= clock.now.addingTimeInterval(7200))
        // Not before it is due.
        model.maybeSurprise(now: due!.addingTimeInterval(-1), level: .normal)
        #expect(store.surprisesToday(now: clock.now) == 0)

        // Just after an alert: postponed by five minutes.
        clock.now = due!
        model.alertShown()
        model.maybeSurprise(now: clock.now, level: .normal)
        #expect(store.surprisesToday(now: clock.now) == 0 && store.snapshot.nextSurprise == due!.addingTimeInterval(300))
        // While typing: postponed too.
        clock.now = due!.addingTimeInterval(300)
        model.isBusy = { true }
        model.maybeSurprise(now: clock.now, level: .normal)
        #expect(store.surprisesToday(now: clock.now) == 0)
        model.isBusy = { false }
        // Outside the calm hours: no.
        for hour in [7, 19, 22] {
            let (late, lateClock, lateStore) = self.model(at: Self.date(4, hour))
            lateStore.schedule(next: lateClock.now.addingTimeInterval(-60))
            late.maybeSurprise(now: lateClock.now, level: .normal)
            #expect(lateStore.surprisesToday(now: lateClock.now) == 0, "at \(hour):00")
        }
        // Calm again: it comes, and the next is one to two hours away.
        clock.now = due!.addingTimeInterval(600)
        model.maybeSurprise(now: clock.now, level: .normal)
        #expect(store.surprisesToday(now: clock.now) == 1)
        #expect(store.snapshot.nextSurprise! >= clock.now.addingTimeInterval(3600))
    }

    @Test("FUN-10 at most six surprises a day, twelve at Party, then tomorrow morning")
    func surpriseCap() {
        for (level, cap) in [(FunLevel.normal, 6), (.party, 12)] {
            let (model, clock, store) = model(at: Self.date(4, 8), level: level)
            for _ in 0..<(cap + 3) {
                store.schedule(next: clock.now.addingTimeInterval(-1))
                model.maybeSurprise(now: clock.now, level: level)
            }
            #expect(store.surprisesToday(now: clock.now) == cap)
            #expect(store.snapshot.nextSurprise == Self.date(5, 8))
        }
    }

    @Test("FUN-10 the kinds of surprise follow the weights, and each kind does its part")
    func kinds() {
        var picked: [FunModel.Kind: Int] = [:]
        for roll in 0..<10 {
            let (model, _, _) = model(at: Self.date(4, 10), random: { _ in roll })
            picked[model.randomKind(), default: 0] += 1
        }
        #expect(picked == [.peek: 4, .nod: 2, .joke: 2, .funFact: 2])

        let (model, clock, store) = model(at: Self.date(4, 10))
        var nods = 0
        model.nod = { nods += 1 }
        model.fireSurprise(at: clock.now, kind: .nod)
        #expect(nods == 1 && model.nodCount == 1)
        model.fireSurprise(at: clock.now, kind: .joke)
        #expect(FunLines.jokes.contains(model.footerLine(at: clock.now)?.text ?? "") && model.footerLine(at: clock.now)?.kind == .surprise)
        // The surprise's line goes after half an hour, and the tip is back.
        #expect(model.footerLine(at: clock.now.addingTimeInterval(31 * 60))?.kind != .surprise)
        model.fireSurprise(at: clock.now, kind: .funFact)
        #expect(model.footerLine(at: clock.now)?.text.contains("{") == false)
        #expect(store.snapshot.seen.count >= 2)
    }

    @Test("FUN-11 a peek waits for a surface, not for long, never while busy or just after an alert; a catch counts")
    func peek() {
        let (model, clock, _) = model(at: Self.date(4, 10), random: { $0 > 1 ? 1 : 0 })
        #expect(model.claimPeek(busy: false) == nil)
        model.fireSurprise(at: clock.now, kind: .peek)
        #expect(model.peek != nil)
        #expect(model.claimPeek(busy: true) == nil && model.peek != nil)
        // A surface that doesn't let him out of this edge leaves him armed for another.
        let edge = model.peek!.edge
        #expect(model.claimPeek(busy: false, edges: Set(FunModel.PeekEdge.allCases).subtracting([edge])) == nil && model.peek != nil)
        model.alertShown()
        #expect(model.claimPeek(busy: false) == nil)
        clock.now = clock.now.addingTimeInterval(100)
        let claimed = model.claimPeek(busy: false)
        #expect(claimed != nil && model.peek == nil)
        #expect(model.claimPeek(busy: false) == nil)
        // An armed peek lets go after twenty minutes.
        let (later, laterClock, _) = self.model(at: Self.date(4, 10))
        later.fireSurprise(at: laterClock.now, kind: .peek)
        laterClock.now = laterClock.now.addingTimeInterval(21 * 60)
        #expect(later.claimPeek(busy: false) == nil && later.peek == nil)
        // At Subtle nothing is claimed.
        later.fireSurprise(at: laterClock.now, kind: .peek)
        later.apply(Preferences(easterEggs: true, funLevel: .subtle))
        #expect(later.claimPeek(busy: false) == nil)
    }

    @Test("FUN-11 every fifth catch unlocks a hat for the peeking butler; the About window counts the catches")
    func catches() {
        let (model, _, store) = model(at: Self.date(4, 10))
        #expect(model.caughtLine == nil)
        var unlocks: [String?] = []
        for _ in 0..<10 {
            let result = model.catchButler()
            #expect(!result.line.isEmpty)
            unlocks.append(result.unlock)
        }
        #expect(unlocks.compactMap { $0 }.count == 2 && unlocks[4] != nil && unlocks[9] != nil)
        #expect(model.caughtLine == "Butlers caught: 10" && store.snapshot.catches == 10)
        #expect(FunModel.peekHat(catches: 4) == nil && FunModel.peekHat(catches: 5) == .party)
        #expect(FunModel.peekHat(catches: 10) == .witch && FunModel.peekHat(catches: 99) == .newYear)
    }

    @Test("FUN-12 Inbox Zero has one line a day and confetti once a day; a merge brings its line to its card")
    func inboxZeroAndMerge() {
        let (model, clock, _) = model(at: Self.date(4, 10))
        let line = model.inboxZeroLine(at: clock.now)
        #expect(FunLines.inboxZero.contains(line ?? ""))
        #expect(model.inboxZeroLine(at: clock.now.addingTimeInterval(3600)) == line)
        #expect(model.inboxZeroReached(at: clock.now))
        #expect(!model.inboxZeroReached(at: clock.now.addingTimeInterval(60)))
        #expect(model.inboxZeroReached(at: Self.date(5, 10)))
        model.merged(reference: "group/project!12")
        let merge = model.merges["group/project!12"]
        #expect(FunLines.merged.contains(merge?.line ?? "") && merge?.level == .normal)
        #expect(model.merges["group/project!13"] == nil)
        // Subtle has neither.
        let (quiet, _, _) = self.model(at: Self.date(4, 10), level: .subtle)
        quiet.merged(reference: "group/project!12")
        #expect(quiet.merges.isEmpty && quiet.inboxZeroLine(at: clock.now) == nil && !quiet.inboxZeroReached(at: clock.now))
    }

    @Test("FUN-13 Surprise Me works with the eggs on, shows a sample, and says so with the eggs off")
    func surpriseMe() {
        let (off, _, _) = model(at: Self.date(4, 10), level: nil)
        #expect(off.surpriseMe() == "Turn the easter eggs on first.")
        var shown: [(String, FunCelebration?, Bool)] = []
        for roll in 0..<8 {
            let (model, _, _) = self.model(at: Self.date(4, 10), level: .party, random: { _ in roll })
            model.showSample = { line, celebration, success in
                shown.append((line, celebration, success))
                return true
            }
            #expect(!model.surpriseMe().isEmpty)
        }
        #expect(shown.count == 4 + 0 || shown.count >= 4)
        #expect(shown.contains { $0.1 == .confetti } && shown.contains { $0.1 == .fireworks } && shown.contains { !$0.2 })
        // Without a project the sample can't show; the line is still told.
        let (noTeam, _, _) = model(at: Self.date(4, 10), random: { _ in 1 })
        #expect(noTeam.surpriseMe().hasPrefix("A sample alert needs a project first."))
    }

    @Test("FUN-11 Surprise Me queues a pane peek about one time in three; it plays when the pane opens, within 60 s")
    func queuedPanePeek() {
        // random(3) == 0 is the pane peek
        let (model, clock, _) = model(at: Self.date(4, 10), random: { _ in 0 })
        #expect(model.surpriseMe() == "Open the menu bar pane to find him.")
        #expect(model.peek?.surface == .menuPane && model.peek?.patience == 60)
        // a window doesn't take it, the pane does, from a side
        #expect(model.claimPeek(busy: false, surface: .window) == nil && model.peek != nil)
        #expect(model.claimPeek(busy: false, edges: [.left, .right], owner: "pane", surface: .menuPane) != nil)
        #expect(model.playing?.owner == "pane" && model.playing?.peek.edge == .right)
        #expect((model.playing?.along ?? 0) >= 0.64 && (model.playing?.along ?? 1) <= 0.72)
        // other rolls don't queue for the pane
        let (other, _, _) = self.model(at: Self.date(4, 10), random: { _ in 4 })
        _ = other.surpriseMe()
        #expect(other.peek?.surface != .menuPane)
        // after 60 s it lets go
        let (late, lateClock, _) = self.model(at: Self.date(4, 10))
        late.queuePanePeek(at: lateClock.now)
        lateClock.now = lateClock.now.addingTimeInterval(59)
        #expect(late.claimPeek(busy: false, surface: .menuPane) != nil)
        let (expired, expiredClock, _) = self.model(at: Self.date(4, 10))
        expired.queuePanePeek(at: expiredClock.now)
        expiredClock.now = expiredClock.now.addingTimeInterval(61)
        #expect(expired.claimPeek(busy: false, surface: .menuPane) == nil && expired.peek == nil)
        _ = clock
    }

    @Test("FUN-11 a peek is claimed a moment after its surface shows, not on a long retry; again while busy; not while hidden")
    func claimWhenShown() async {
        let wall = Clock(Self.date(4, 10))
        let test = TestClock()
        let fun = FunModel(
            store: FunStore(calendar: Self.calendar), now: { wall.now }, clock: test, calendar: Self.calendar, random: { _ in 0 })
        fun.apply(Preferences(easterEggs: true, funLevel: .normal))
        fun.queuePanePeek(at: wall.now)
        var shown = false
        var busy = true
        func claim() -> Task<Void, Never> {
            Task { @MainActor in
                await fun.claimPeekWhenShown(
                    isShown: { shown }, busy: { busy }, edges: [.right], owner: FunModel.paneOwner, surface: .menuPane)
            }
        }
        // not shown yet (the pane's first task runs before its appearing): nothing waits, nothing is claimed
        await claim().value
        #expect(fun.peek != nil && fun.playing == nil && test.sleeperCount == 0)
        // shown: he waits only the settle time, then comes; a user who is busy keeps him waiting a second at a time
        shown = true
        let task = claim()
        await test.waitForSleepers()
        test.advance(by: FunModel.peekSettle - .milliseconds(1))
        await Task.yield()
        #expect(fun.playing == nil)
        test.advance(by: .milliseconds(1))
        await test.waitForSleepers()
        #expect(fun.playing == nil && FunModel.peekRetry <= .seconds(1))
        busy = false
        test.advance(by: FunModel.peekRetry)
        await task.value
        #expect(fun.playing?.owner == FunModel.paneOwner && fun.peek == nil)
    }

    @Test("FUN-11 a window's peek waits while its window isn't key and the app active, comes a moment after; the pane needs no focus")
    func windowPeekNeedsFocus() async {
        #expect(FunModel.PeekSurface.window.showsButler(isShown: true, isFocused: false) == false)
        #expect(FunModel.PeekSurface.window.showsButler(isShown: true, isFocused: true))
        #expect(FunModel.PeekSurface.menuPane.showsButler(isShown: true, isFocused: false))
        #expect(FunModel.PeekSurface.menuPane.showsButler(isShown: false, isFocused: true) == false)
        let wall = Clock(Self.date(4, 10))
        let test = TestClock()
        let fun = FunModel(
            store: FunStore(calendar: Self.calendar), now: { wall.now }, clock: test, calendar: Self.calendar, random: { _ in 0 })
        fun.apply(Preferences(easterEggs: true, funLevel: .normal))
        fun.fireSurprise(at: wall.now, kind: .peek)
        // the overlay's rule: the window shows, but isn't focused: nothing waits, nothing plays
        var focused = false
        func claim() -> Task<Void, Never> {
            Task { @MainActor in
                let shown = FunModel.PeekSurface.window.showsButler(isShown: true, isFocused: focused)
                await fun.claimPeekWhenShown(isShown: { shown }, busy: { false }, owner: "window", surface: .window)
            }
        }
        await claim().value
        #expect(fun.peek != nil && fun.playing == nil && test.sleeperCount == 0)
        // focus returns: the settle time, then he comes
        focused = true
        let task = claim()
        await test.waitForSleepers()
        test.advance(by: FunModel.peekSettle - .milliseconds(1))
        await Task.yield()
        #expect(fun.playing == nil)
        test.advance(by: .milliseconds(1))
        await task.value
        #expect(fun.playing?.owner == "window")
        // focus goes while he is out: he leaves at once, whatever the duck grace; another surface's peek stays
        fun.retreat(owner: "other")
        #expect(fun.playing?.phase != .slidingOut)
        let catches = fun.catches
        fun.retreat(owner: "window")
        await test.waitForSleepers()
        #expect(fun.playing?.phase == .slidingOut && fun.catches == catches)
        test.advance(by: FunModel.leaveDuration)
        await Task.yield()
        for _ in 0..<5 where fun.playing != nil { await Task.yield() }
        #expect(fun.playing == nil)
    }

    @Test("FUN-11 a random peek picks a surface that shows now, the pane's only from the right; none showing, he waits for any")
    func peekPicksVisibleSurface() {
        let (model, clock, _) = model(at: Self.date(4, 10))
        model.fireSurprise(at: clock.now, kind: .peek)
        #expect(model.peek?.surface == nil)
        model.surface(.menuPane, isShown: true)
        model.fireSurprise(at: clock.now, kind: .peek)
        #expect(model.peek?.surface == .menuPane && model.peek?.edge == .right)
        model.surface(.menuPane, isShown: false)
        model.surface(.window, isShown: true)
        model.fireSurprise(at: clock.now, kind: .peek)
        #expect(model.peek?.surface == .window)
        model.surface(.window, isShown: false)
        model.surface(.window, isShown: false)
        #expect(model.shownSurfaces[.window] == 0)
    }

    @Test("FUN-10 the menu bar hop lasts 1.2 s with a clear up and down, twice; nothing moves under Reduce Motion")
    func hop() {
        let steps = HopSequence.steps(reduceMotion: false)
        #expect(steps.map(\.frame) == [.hopUp, .hopDown, .hopUp, .hopDown])
        #expect(steps.reduce(Duration.zero) { $0 + $1.duration } == HopSequence.duration && HopSequence.duration == .milliseconds(1200))
        #expect(HopSequence.steps(reduceMotion: true).isEmpty)
        let (model, _, _) = self.model(at: Self.date(4, 10))
        model.reduceMotion = { true }
        #expect(model.surpriseMe().isEmpty == false)
    }

    // MARK: Haiku's daily batch

    private static let answer: [String: [String]] = [
        "redemption": ["The butler found sunshine behind the red clouds."],
        "tip": ["Rest your eyes between two builds, they are not compiling."],
        "caught": ["Fine, you win. The butler tips an imaginary hat."],
    ]

    @Test("FUN-06 the tick asks Haiku once a day for the batch, twice at most, and adds the lines to the pool")
    func tickAsksOnce() async {
        let (model, clock, store) = model(at: Self.date(4, 10))
        var calls = 0
        model.askBatch = { _ in
            calls += 1
            return Self.answer
        }
        await model.tick()
        #expect(calls == 1 && store.poolCount(.redemption) == 1 && store.poolCount(.caught) == 1)
        // Four kinds are dry, so one top-up is allowed; then no more today.
        await model.tick()
        await model.tick()
        #expect(calls == 2)
        clock.now = Self.date(5, 10)
        await model.tick()
        #expect(calls == 3)
        // Haiku's line comes out first.
        #expect(store.draw(.redemption, now: clock.now, seed: 0) == "The butler found sunshine behind the red clouds.")
    }

    @Test("FUN-06 with Claude off the batch gives nothing and the built-in lines carry on; at Subtle no call goes out")
    func tickWithoutClaude() async {
        let (model, _, store) = model(at: Self.date(4, 10))
        var calls = 0
        model.askBatch = { _ in
            calls += 1
            return nil
        }
        await model.tick()
        #expect(calls == 1 && store.poolCount(.redemption) == 0)
        #expect(FunLines.redemption.contains(store.draw(.redemption, now: Self.date(4, 10), seed: 2)))
        let (subtle, _, _) = self.model(at: Self.date(4, 10), level: .subtle)
        var subtleCalls = 0
        subtle.askBatch = { _ in
            subtleCalls += 1
            return Self.answer
        }
        await subtle.tick()
        #expect(subtleCalls == 0)
        let (off, _, _) = self.model(at: Self.date(4, 10), level: nil)
        off.askBatch = { _ in
            subtleCalls += 1
            return Self.answer
        }
        await off.tick()
        #expect(subtleCalls == 0)
    }

    // MARK: The peek's playback

    /// a model on a test clock, so the playback's seconds are the test's
    private func playbackModel() -> (FunModel, TestClock, @Sendable () -> Date) {
        let clock = TestClock()
        let start = Self.date(4, 10)
        let now: @Sendable () -> Date = {
            let parts = clock.now.offset.components
            return start.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        }
        let model = FunModel(store: FunStore(calendar: Self.calendar), now: now, clock: clock, calendar: Self.calendar, random: { _ in 0 })
        model.apply(Preferences(easterEggs: true, funLevel: .party))
        return (model, clock, now)
    }

    @Test("FUN-11 once taken, he is fully out for 2.5 s after the slide-in, whatever the view does; then he slides out")
    func visibleDuration() async {
        let (model, clock, _) = playbackModel()
        model.fireSurprise(at: Self.date(4, 10), kind: .peek)
        #expect(model.claimPeek(busy: false, owner: "pane") != nil)
        #expect(model.playing?.phase == .slidingIn && model.playing?.owner == "pane" && model.peek == nil)
        // A second surface can't take another while he plays.
        model.fireSurprise(at: Self.date(4, 10), kind: .peek)
        #expect(model.claimPeek(busy: false, owner: "window") == nil)

        await clock.waitForSleepers()
        clock.advance(by: FunModel.slideDuration)
        while model.playing?.phase != .out { await Task.yield() }
        await clock.waitForSleepers()
        // 2.499 s out: still out. The view's refreshes don't matter: nothing in the view ends it.
        clock.advance(by: .milliseconds(2499))
        await Task.yield()
        #expect(model.playing?.phase == .out)
        clock.advance(by: .milliseconds(1))
        while model.playing?.phase != .slidingOut { await Task.yield() }
        await clock.waitForSleepers()
        clock.advance(by: FunModel.leaveDuration)
        while model.playing != nil { await Task.yield() }
        #expect(model.playing == nil)
    }

    @Test("FUN-11 the pointer can't send him back in his first 1.5 s out; after that it can")
    func duckGrace() async {
        let (model, clock, _) = playbackModel()
        model.fireSurprise(at: Self.date(4, 10), kind: .peek)
        model.claimPeek(busy: false, owner: "pane")
        #expect(!model.duck())
        await clock.waitForSleepers()
        clock.advance(by: FunModel.slideDuration)
        while model.playing?.phase != .out { await Task.yield() }
        await clock.waitForSleepers()
        clock.advance(by: .milliseconds(1400))
        await Task.yield()
        #expect(!model.duck() && model.playing?.phase == .out)
        clock.advance(by: .milliseconds(100))
        await Task.yield()
        #expect(model.duck())
        while model.playing?.phase != .slidingOut { await Task.yield() }
        await clock.waitForSleepers()
        clock.advance(by: FunModel.leaveDuration)
        while model.playing != nil { await Task.yield() }
    }

    @Test("FUN-11 a catch turns the peek into the caught pose in the same spot, which stays a few seconds")
    func caughtInPlace() async {
        let (model, clock, _) = playbackModel()
        model.fireSurprise(at: Self.date(4, 10), kind: .peek)
        model.claimPeek(busy: false, owner: "pane")
        let playing = model.playing!
        let result = model.catchButler()
        #expect(model.playing == nil)
        #expect(model.caughtPlay?.edge == playing.peek.edge && model.caughtPlay?.along == playing.along)
        #expect(model.caughtPlay?.owner == "pane" && model.caughtPlay?.result == result)
        await clock.waitForSleepers()
        clock.advance(by: .milliseconds(3999))
        await Task.yield()
        #expect(model.caughtPlay != nil)
        clock.advance(by: .milliseconds(1))
        while model.caughtPlay != nil { await Task.yield() }
        #expect(model.caughtPlay == nil)
    }

    @Test("SET-01 fresh settings have the Party fun level, saved ones keep theirs")
    func partyDefault() throws {
        #expect(Preferences().funLevel == .party)
        let saved = Preferences(funLevel: .subtle)
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(saved))
        #expect(decoded.funLevel == .subtle)
        #expect(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).funLevel == .party)
    }
}
