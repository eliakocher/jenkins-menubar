import Foundation
import Testing

@testable import MenubarCore

/// The daily coffee break in the Inbox (INBOX-12).
@Suite("Coffee break", .timeLimit(.minutes(1)))
@MainActor
struct CoffeeBreakTests {
    private nonisolated static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-11-02 is a Monday; `Self.date(2, 8, 50)` is that day at 08:50 UTC
    private nonisolated static func date(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 11) -> Date {
        utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// A launch of the app: an Inbox on a folder that outlives it, a clock that starts at a given time, and the
    /// coffee break over them.
    @MainActor
    private final class Launch {
        let clock = TestClock()
        let inbox: InboxStore
        let coffee: CoffeeBreak
        let origin: Date
        var lines: [String?]
        private(set) var asked = 0

        init(folder: TemporaryFolder, at origin: Date, lines: [String?] = [nil]) throws {
            self.origin = origin
            self.lines = lines
            let clock = clock
            let now: @Sendable () -> Date = {
                let offset = clock.now.offset.components
                return origin.addingTimeInterval(Double(offset.seconds))
            }
            let keychain = InMemoryKeychain(values: [TokenAccount.gitlab.rawValue: "glpat-test"])
            let team = TeamStore(folder: folder.file("support"), report: { _ in })
            try team.save(Project(id: .main, team: TeamValues(
                jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: "https://gitlab.example.com",
                gitLabProject: "acme/web/app")))
            let services = GitLabServices(
                transport: StubTransport(clock: clock), clock: clock, now: now, tokens: TokenStore(keychain: keychain), team: team,
                caches: CacheStore(folder: folder.file("caches"), report: { _ in }),
                log: ActivityLog(folder: folder.file("logs"), now: now))
            inbox = InboxStore(services: services, folder: folder.file("support"), calendar: CoffeeBreakTests.utc)
            var pending: Launch?
            coffee = CoffeeBreak(inbox: inbox, clock: clock, now: now, calendar: CoffeeBreakTests.utc, line: { _ in
                guard let launch = pending else { return nil }
                launch.asked += 1
                return launch.lines.isEmpty ? nil : launch.lines.removeFirst()
            })
            pending = self
        }

        /// the entries, newest first, as "headline: line"
        var entries: [String] {
            inbox.pending.map { "\($0.title): \($0.body)" }
        }

        /// Moves the clock on once the loop sleeps; `sleeps: false` while no loop runs, which would wait for ever.
        func advance(_ seconds: Int, sleeps: Bool = true) async {
            if sleeps {
                await clock.waitForSleepers()
            }
            clock.advance(by: .seconds(seconds))
            // The entry is added after the line came; let the loop run.
            for _ in 0..<200 { await Task.yield() }
        }
    }

    // MARK: - The time

    @Test("INBOX-12 the coffee break comes at its time on Monday to Friday, never at the weekend")
    func scheduleMath() {
        let minutes = InboxNotificationRules.defaultCoffeeMinutes
        #expect(minutes == 8 * 60 + 59)
        // before, at and after the time on a Monday; a Friday; a Saturday and a Sunday
        #expect(CoffeeBreak.next(after: Self.date(2, 8, 50), minutes: minutes, calendar: Self.utc) == Self.date(2, 8, 59))
        #expect(CoffeeBreak.next(after: Self.date(2, 8, 59), minutes: minutes, calendar: Self.utc) == Self.date(3, 8, 59))
        #expect(CoffeeBreak.next(after: Self.date(2, 12, 0), minutes: minutes, calendar: Self.utc) == Self.date(3, 8, 59))
        #expect(CoffeeBreak.next(after: Self.date(6, 9, 0), minutes: minutes, calendar: Self.utc) == Self.date(9, 8, 59))
        #expect(CoffeeBreak.next(after: Self.date(7, 8, 0), minutes: minutes, calendar: Self.utc) == Self.date(9, 8, 59))
        #expect(CoffeeBreak.next(after: Self.date(8, 8, 0), minutes: minutes, calendar: Self.utc) == Self.date(9, 8, 59))
        #expect(CoffeeBreak.occurrence(on: Self.date(7, 10, 0), minutes: minutes, calendar: Self.utc) == nil)
        #expect(CoffeeBreak.occurrence(on: Self.date(4, 10, 0), minutes: minutes, calendar: Self.utc) == Self.date(4, 8, 59))
    }

    // MARK: - The entry

    @Test("INBOX-12 at 08:59 the entry comes with Haiku's line, or a built-in one without; each day once, replacing yesterday's")
    func entryAtTheTime() async throws {
        let folder = try TemporaryFolder()
        let launch = try Launch(folder: folder, at: Self.date(2, 8, 50), lines: ["Coffee is a deployment you can drink.", nil])
        launch.coffee.apply(InboxNotificationRules())

        // Nothing before the time.
        await launch.advance(60)
        #expect(launch.entries.isEmpty)
        // Monday 08:59: Haiku's line.
        await launch.advance(9 * 60)
        #expect(launch.entries == ["☕ Coffee break: Coffee is a deployment you can drink."])
        #expect(launch.inbox.pending.first?.headline == "Time for a break")
        #expect(launch.inbox.pending.first?.kind == .coffeeBreak)
        #expect(launch.inbox.pending.first?.isLocalItem == true)

        // Tuesday 08:59: Claude gave nothing, so a built-in line; yesterday's entry is done.
        await launch.advance(24 * 3600)
        let tuesday = try #require(launch.inbox.pending.first)
        #expect(launch.inbox.pending.count == 1)
        #expect(CoffeeBreak.fallbackLines.contains(tuesday.body))
        #expect(launch.inbox.done.map(\.kind) == [.coffeeBreak])
        #expect(launch.asked == 2)
        launch.coffee.stop()
    }

    @Test("INBOX-12 nothing at the weekend, nothing when the Mac wakes after the window, and one entry a day across a relaunch")
    func skipsAndDedupes() async throws {
        let folder = try TemporaryFolder()
        // Friday 08:50 → 08:59 comes; a relaunch at 09:10 the same day adds nothing and asks Claude nothing.
        let friday = try Launch(folder: folder, at: Self.date(6, 8, 50), lines: ["Friday coffee."])
        friday.coffee.apply(InboxNotificationRules())
        await friday.advance(9 * 60)
        #expect(friday.entries == ["☕ Coffee break: Friday coffee."])
        friday.coffee.stop()

        let relaunch = try Launch(folder: folder, at: Self.date(6, 9, 10), lines: ["Again."])
        relaunch.coffee.apply(InboxNotificationRules())
        await relaunch.advance(0)
        #expect(relaunch.entries == ["☕ Coffee break: Friday coffee."])
        #expect(relaunch.asked == 0)
        relaunch.coffee.stop()

        // The weekend passes without an entry: Monday's comes at 08:59 (the Friday one clears then).
        let weekend = try Launch(folder: folder, at: Self.date(7, 20, 0), lines: ["Monday coffee."])
        weekend.coffee.apply(InboxNotificationRules())
        await weekend.advance(37 * 3600)
        #expect(weekend.entries.isEmpty == false)
        #expect(weekend.entries == ["☕ Coffee break: Monday coffee."])
        weekend.coffee.stop()

        // A Mac that wakes at 09:40, more than 30 minutes late, skips that day; at 09:20 it still comes.
        let late = try Launch(folder: folder, at: Self.date(3, 9, 40), lines: ["Too late."])
        late.coffee.apply(InboxNotificationRules())
        await late.advance(0)
        #expect(late.asked == 0)
        late.coffee.stop()
        let nearly = try Launch(folder: folder, at: Self.date(3, 9, 20), lines: ["Just in time."])
        nearly.coffee.apply(InboxNotificationRules())
        await nearly.advance(0)
        #expect(nearly.entries == ["☕ Coffee break: Just in time."])
        nearly.coffee.stop()
    }

    @Test("INBOX-12 off, it adds nothing; a new time starts the wait again")
    func switchAndTime() async throws {
        let folder = try TemporaryFolder()
        let launch = try Launch(folder: folder, at: Self.date(2, 8, 50), lines: ["Later coffee."])
        var rules = InboxNotificationRules(coffeeBreak: false)
        launch.coffee.apply(rules)
        await launch.advance(3600, sleeps: false)
        #expect(launch.entries.isEmpty)

        // On again, at 10:30: the loop has the new time. (The clock is at 09:50.)
        rules = InboxNotificationRules(coffeeBreak: true, coffeeMinutes: 10 * 60 + 30)
        launch.coffee.apply(rules)
        await launch.advance(40 * 60)
        #expect(launch.entries == ["☕ Coffee break: Later coffee."])
        launch.coffee.stop()
    }

    @Test("INBOX-12 the coffee break is on at 08:59 unless turned off, and the time is kept in the routing")
    func rulesKeepIt() throws {
        #expect(InboxNotificationRules().coffeeBreak)
        #expect(InboxNotificationRules().coffeeMinutes == 539)
        let suite = TemporaryDefaults()
        let store = PreferencesStore(defaults: suite.defaults)
        var preferences = store.load()
        preferences.inboxNotifications.coffeeBreak = false
        preferences.inboxNotifications.coffeeMinutes = 9 * 60
        store.save(preferences)
        let loaded = PreferencesStore(defaults: suite.defaults).load().inboxNotifications
        #expect(!loaded.coffeeBreak && loaded.coffeeMinutes == 540)
        // A file saved before it existed reads as the default; a time out of range is cut to the day.
        let old = try JSONDecoder().decode(InboxNotificationRules.self, from: Data(#"{"overrides":{}}"#.utf8))
        #expect(old == InboxNotificationRules())
        let wild = try JSONDecoder().decode(InboxNotificationRules.self, from: Data(#"{"coffeeMinutes":99999}"#.utf8))
        #expect(wild.coffeeMinutes == 1439)
    }

    // MARK: - Haiku

    @Test("INBOX-12 the line comes from Haiku with no tools, no setup and a few cents of budget, and holds nothing of mine")
    func haikuCall() async throws {
        let fake = ScriptedClaude([.text("\n\"Coffee first, merge later.\"\nA second line.")])
        let store = AIStore(defaults: TemporaryDefaults().defaults, runner: fake, resolver: fake.resolver())
        store.update(AISettings(isEnabled: true))

        let line = await store.coffeeLine(on: Self.date(2, 8, 59), calendar: Self.utc)

        #expect(line == "Coffee first, merge later.")
        let call = try #require(await fake.calls.first)
        #expect(call.arguments.starts(with: ["-p", "--output-format", "json", "--model", "claude-haiku-5-5", "--tools", "", "--safe-mode"]))
        #expect(call.arguments.contains("0.05"))
        #expect(!call.arguments.contains("--allowedTools") && !call.arguments.contains("--add-dir"))
        #expect(call.input?.contains("Today is Monday") == true)
        #expect(call.input?.contains("group") != true)
    }

    @Test("INBOX-12 with the Claude features off, claude missing or the run failing, there is no line and claude isn't asked for nothing")
    func noLine() async throws {
        let fake = ScriptedClaude([.text("never")])
        let off = AIStore(defaults: TemporaryDefaults().defaults, runner: fake, resolver: fake.resolver())
        #expect(await off.coffeeLine(on: Self.date(2, 8, 59), calendar: Self.utc) == nil)
        #expect(await fake.calls.isEmpty)

        let failing = ScriptedClaude([.failure])
        let on = AIStore(defaults: TemporaryDefaults().defaults, runner: failing, resolver: failing.resolver())
        on.update(AISettings(isEnabled: true))
        #expect(await on.coffeeLine(on: Self.date(2, 8, 59), calendar: Self.utc) == nil)
        #expect(await failing.calls.count == 1)

        // Claude's answer without a line is none.
        #expect(ClaudePrompt.coffeeLine(from: "  \n ") == nil)
        #expect(ClaudePrompt.coffeeLine(from: String(repeating: "x", count: 200))?.count == 140)
        // The built-in lines: fifteen, one a day, no company name.
        #expect(CoffeeBreak.fallbackLines.count == 15)
        #expect(Set(CoffeeBreak.fallbackLines).count == 15)
    }
}
