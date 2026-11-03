import Foundation
import Testing

@testable import MenubarCore

/// How the Inbox's events announce themselves beyond the Inbox, and the order of its groups (Task 7.03, INBOX-14,
/// INBOX-15).
@Suite("Inbox delivery", .timeLimit(.minutes(1)))
@MainActor
struct InboxDeliveryTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    /// Monday 2026-11-02 09:00 UTC
    private nonisolated static let start = Date(timeIntervalSince1970: 1_793_610_000)
    private nonisolated static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// An app model on fakes, with the fake effects that record what was shown.
    @MainActor
    private struct Setup {
        let folder: TemporaryFolder
        let defaults = TemporaryDefaults()
        let effects: FakeEffects
        let model: AppModel

        init(notificationsAllowed: Bool = true, rules: InboxNotificationRules = InboxNotificationRules()) throws {
            folder = try TemporaryFolder()
            effects = FakeEffects(notificationsAllowed: notificationsAllowed)
            try TeamStore(folder: FileLocations(root: folder.url).applicationSupport, report: { _ in })
                .save(Project(id: .main, team: TeamValues(
                    jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: InboxDeliveryTests.gitLab.absoluteString,
                    gitLabProject: "acme/web/app")))
            model = AppModel(
                dependencies: .fake(
                    root: folder.url, defaults: defaults.defaults, now: { InboxDeliveryTests.start }, effects: effects,
                    processRunner: ScriptedClaude([.failure])))
            model.inbox.rules = rules
        }
    }

    private static func coffee(_ day: Int = 2) -> InboxEvent {
        .coffeeBreak(line: "Pour a cup.", at: start.addingTimeInterval(Double(day) * 86400), calendar: utc)
    }

    private static func review(_ id: String) -> InboxEvent {
        InboxEvent(
            id: id, kind: .reviewRequested, source: .mergeRequests, title: "Add a retry", reference: "acme/web/app!12",
            targetURL: gitLab.appending(path: "acme/web/app/-/merge_requests/12"), projectPath: "acme/web/app",
            actor: MergeRequest.Person(username: "akim", name: "Alex Kim"), occurredAt: start)
    }

    // MARK: - INBOX-14

    @Test("INBOX-14 every kind is Inbox Only until the user picks; a pick is kept per kind and the default removes it")
    func inboxOnlyByDefault() {
        var rules = InboxNotificationRules()
        for kind in InboxEventKind.allCases {
            #expect(rules.delivery(for: kind) == .inboxOnly)
        }
        #expect(InboxNotificationRules.deliveryKinds.count == 13)
        #expect(!InboxNotificationRules.deliveryKinds.contains(.myTodo))
        // A failed build is announced by the build alerts, once (ALERT-10).
        #expect(!InboxNotificationRules.deliveryKinds.contains(.buildFailed))

        rules.set(.bigPanel, for: .coffeeBreak)
        rules.set(.desktopNotification, for: .reviewRequested)
        #expect(rules.delivery(for: .coffeeBreak) == .bigPanel)
        #expect(rules.delivery(for: .reviewRequested) == .desktopNotification)
        #expect(rules.delivery(for: .mentioned) == .inboxOnly)
        #expect(rules.usesDesktopNotifications)
        // The Inbox and Badge toggles are a separate thing.
        #expect(rules.routes(for: .coffeeBreak) == [.inbox, .badge])

        rules.set(.inboxOnly, for: .reviewRequested)
        #expect(rules.deliveries == ["coffeeBreak": .bigPanel])
        #expect(!rules.usesDesktopNotifications)
        // My own to-dos never announce themselves.
        rules.set(.bigPanel, for: .myTodo)
        #expect(rules.delivery(for: .myTodo) == .inboxOnly)
    }

    @Test("INBOX-14 rules saved before delivery decode as Inbox Only, an unknown choice is ignored, and the choices round trip")
    func deliveryIsCodable() throws {
        let old = #"{"overrides":{"mentioned":3},"onlyMyProjects":true,"coffeeBreak":false,"coffeeMinutes":600}"#
        let decoded = try JSONDecoder().decode(InboxNotificationRules.self, from: Data(old.utf8))
        for kind in InboxEventKind.allCases {
            #expect(decoded.delivery(for: kind) == .inboxOnly)
        }
        #expect(decoded.groupOrder == InboxGroup.allCases)
        #expect(decoded.onlyMyProjects && !decoded.coffeeBreak && decoded.coffeeMinutes == 600)

        let odd = #"{"deliveries":{"coffeeBreak":"bigPanel","assigned":"carrierPigeon","unknownKind":"bigPanel","merged":"inboxOnly"}}"#
        let tolerant = try JSONDecoder().decode(InboxNotificationRules.self, from: Data(odd.utf8))
        #expect(tolerant.delivery(for: .coffeeBreak) == .bigPanel)
        #expect(tolerant.delivery(for: .assigned) == .inboxOnly)
        #expect(tolerant.deliveries["assigned"] == nil && tolerant.deliveries["merged"] == nil)

        var rules = InboxNotificationRules()
        rules.set(.desktopNotification, for: .mentioned)
        rules.setGroupOrder([.other, .builds, .claude, .coffee, .myToDos, .mentions, .reviewRequests, .assigned])
        let copy = try JSONDecoder().decode(InboxNotificationRules.self, from: JSONEncoder().encode(rules))
        #expect(copy == rules)
        #expect(copy.delivery(for: .mentioned) == .desktopNotification)

        // Kept in the preferences, which the backup carries as one JSON text.
        let suite = TemporaryDefaults()
        let store = PreferencesStore(defaults: suite.defaults)
        var preferences = store.load()
        preferences.inboxNotifications = rules
        store.save(preferences)
        #expect(PreferencesStore(defaults: suite.defaults).load().inboxNotifications == rules)
    }

    @Test("INBOX-14 each event comes routed with its kind's delivery, and a panel with the Inbox off still announces")
    func eventsCarryTheirDelivery() throws {
        var rules = InboxNotificationRules()
        rules.set(.bigPanel, for: .coffeeBreak)
        rules.set(.desktopNotification, for: .reviewRequested)
        rules.set([], for: .claudeAnswered)
        rules.set(.bigPanel, for: .claudeAnswered)
        let setup = try Setup(rules: rules)
        let store = setup.model.inbox
        var seen: [RoutedInboxEvent] = []
        store.onEvents = { seen += $0 }

        store.addLocal(Self.coffee())
        store.addLocal(Self.review("review|1"))
        store.addLocal(
            .claudeAnswered(
                subjectKey: "a", useCase: "Why Did It Fail?", failed: false, title: "Fix", reference: nil, excerpt: nil, url: nil,
                at: Self.start))
        store.addLocal(.digestReady(summary: nil, url: AppRoute.open(.digest).url, at: Self.start, calendar: Self.utc))
        // Inbox Only and no route: nothing to announce, nothing kept.
        var quiet = rules
        quiet.set([], for: .digestReady)
        store.rules = quiet
        store.addLocal(Self.review("review|quiet-digest"))
        store.addLocal(.buildFailed(
            jobKey: "main|MR-1", number: 1, label: "!1 #1", isUnstable: false, title: nil, url: Self.gitLab, at: Self.start))

        let byKind = Dictionary(uniqueKeysWithValues: seen.map { ($0.event.kind, $0.delivery) })
        #expect(byKind[.coffeeBreak] == .bigPanel)
        #expect(byKind[.reviewRequested] == .desktopNotification)
        #expect(byKind[.claudeAnswered] == .bigPanel)
        #expect(byKind[.digestReady] == .inboxOnly)
        #expect(byKind[.buildFailed] == .inboxOnly)
        // The Claude answer has no route, but its panel shows; it is not an Inbox entry.
        #expect(seen.first { $0.event.kind == .claudeAnswered }?.routes.isEmpty == true)
        #expect(store.pending.contains { $0.kind == .claudeAnswered } == false)
        #expect(store.pending.contains { $0.kind == .coffeeBreak })
    }

    @Test("INBOX-14 the app shows a panel or a banner as chosen, once per event, and a banner macOS refuses stays in the Inbox")
    func appDelivers() async throws {
        var rules = InboxNotificationRules()
        rules.set(.bigPanel, for: .coffeeBreak)
        rules.set(.desktopNotification, for: .reviewRequested)
        let setup = try Setup(rules: rules)
        let store = setup.model.inbox

        store.addLocal(Self.coffee())
        store.addLocal(Self.coffee())
        store.addLocal(Self.review("review|1"))
        store.addLocal(Self.review("review|1"))
        store.addLocal(.digestReady(summary: nil, url: AppRoute.open(.digest).url, at: Self.start, calendar: Self.utc))
        for _ in 0..<200 {
            await Task.yield()
        }

        #expect(await setup.effects.inboxPanels.map(\.kind) == [.coffeeBreak])
        #expect(await setup.effects.inboxBanners.map(\.kind) == [.reviewRequested])
        #expect(store.pending.count == 3)

        // macOS refuses: no banner shows, and the entry is in the Inbox all the same.
        let refused = try Setup(notificationsAllowed: false, rules: rules)
        refused.model.inbox.addLocal(Self.review("review|2"))
        for _ in 0..<200 {
            await Task.yield()
        }
        #expect(await refused.effects.inboxBanners.isEmpty)
        #expect(refused.model.inbox.pending.map(\.kind) == [.reviewRequested])
    }

    @Test("INBOX-14 the panel's Done and Snooze act on the entry the event has: a local entry sleeps on this Mac and wakes")
    func panelButtonsActOnTheEntry() async throws {
        let setup = try Setup()
        let store = setup.model.inbox
        let event = Self.review("review|panel")
        store.addLocal(event)
        let entry = try #require(store.entry(for: event))
        #expect(entry.id == event.id)

        await store.snooze(entry, .oneHour)
        #expect(store.pending.isEmpty)
        #expect(store.snoozed.map(\.kind) == [.reviewRequested])
        #expect(store.badgeCount == 0)
        #expect(store.entry(for: event) != nil)

        let sleeping = try #require(store.snoozed.first)
        await store.unsnooze(sleeping)
        #expect(store.pending.map(\.kind) == [.reviewRequested])

        await store.markDone(try #require(store.entry(for: event)))
        #expect(store.done.map(\.kind) == [.reviewRequested])
        // An event that isn't in the Inbox has no entry to act on.
        #expect(store.entry(for: Self.review("review|nowhere")) == nil)

        // The coffee break takes Done, and no Snooze (the user, 2026-11-03: "coffee is mandatory").
        let coffee = Self.coffee()
        store.addLocal(coffee)
        let cup = try #require(store.entry(for: coffee))
        #expect(cup.group == .coffee)
        await store.snooze(cup, .oneHour)
        #expect(store.snoozed.isEmpty && store.pending.map(\.kind) == [.coffeeBreak])
        await store.markDone(cup)
        #expect(store.done.map(\.kind).contains(.coffeeBreak))
    }

    // MARK: - ALERT-10

    private static func failedBuild(_ result: BuildResult = .failure) throws -> BuildAlert {
        let build = Build(
            job: "MR-1", number: 7, title: "Fix the login", gitLabURL: nil, kind: .mine,
            phase: .finished(result: result, duration: 1800), startedAt: start,
            testCounts: TestCounts(failed: result == .failure ? 2 : 0, total: 40))
        let content = try #require(
            AlertContent.finished(
                build, failedStages: [],
                links: AlertContent.links(for: build, jobURL: URL(string: "https://jenkins.example.com/job/project")!)))
        return BuildAlert(kind: .finished, build: build, content: content)
    }

    /// A failed build as the app handles it: the build alerts announce it, the Inbox keeps it.
    private func failedBuildEverywhere(
        style: Preferences.AlertStyle, rules: InboxNotificationRules, setup: Setup
    ) async throws {
        let alert = try Self.failedBuild()
        setup.model.inbox.rules = rules
        await AlertAnnouncer(effects: setup.effects, log: setup.model.log)
            .announce([alert], preferences: Preferences(alertStyle: style))
        setup.model.addToInbox(finished: [alert])
        for _ in 0..<200 {
            await Task.yield()
        }
    }

    @Test(
        "ALERT-10 a failed build gives exactly one pop-up per alert style, the Inbox adds none, and it is an Inbox entry",
        arguments: [
            (Preferences.AlertStyle.window, 1, 0), (.banner, 0, 1), (.inboxOnly, 0, 0),
        ])
    func oneFailedBuildOnePopUp(style: Preferences.AlertStyle, windows: Int, banners: Int) async throws {
        // Whatever the old Inbox delivery says, it adds nothing: a saved choice is dropped, and `set` ignores the kind.
        var rules = try JSONDecoder().decode(
            InboxNotificationRules.self, from: Data(#"{"deliveries":{"buildFailed":"desktopNotification"}}"#.utf8))
        rules.set(.bigPanel, for: .buildFailed)
        let setup = try Setup(rules: rules)

        try await failedBuildEverywhere(style: style, rules: rules, setup: setup)

        #expect(await setup.effects.alertWindows.count == windows)
        #expect(await setup.effects.banners.count == banners)
        #expect(await setup.effects.sounds.count == windows + banners)
        #expect(await setup.effects.inboxPanels.isEmpty)
        #expect(await setup.effects.inboxBanners.isEmpty)
        // It is still history in the Inbox, quietly.
        #expect(setup.model.inbox.pending.map(\.kind) == [.buildFailed])
    }

    @Test("ALERT-10 migration: the build alert style the user had wins, and a failed build's saved Inbox delivery is dropped")
    func migrationKeepsTheAlertStyle() throws {
        // The user of 2026-11-03: alertStyle window (the big panel), and buildFailed set to a desktop notification.
        let suite = TemporaryDefaults()
        suite.defaults.set("window", forKey: "alertStyle")
        suite.defaults.set(
            #"{"deliveries":{"buildFailed":"desktopNotification","coffeeBreak":"bigPanel"}}"#,
            forKey: PreferencesStore.inboxNotificationsKey)

        let loaded = PreferencesStore(defaults: suite.defaults).load()

        #expect(loaded.alertStyle == .window)
        #expect(InboxDelivery(loaded.alertStyle) == .bigPanel)
        #expect(loaded.inboxNotifications.deliveries == ["coffeeBreak": .bigPanel])
        #expect(loaded.inboxNotifications.delivery(for: .buildFailed) == .inboxOnly)

        // The choices and the styles map one to one, so the one row shows what the build alerts do.
        for delivery in InboxDelivery.allCases {
            #expect(InboxDelivery(Preferences.AlertStyle(delivery)) == delivery)
        }
        for style in Preferences.AlertStyle.allCases {
            #expect(Preferences.AlertStyle(InboxDelivery(style)) == style)
        }
        // A saved Inbox Only style survives a restart.
        suite.defaults.set("inboxOnly", forKey: "alertStyle")
        #expect(PreferencesStore(defaults: suite.defaults).load().alertStyle == .inboxOnly)
    }

    @Test("ALERT-10 nothing else is delivered twice: the digest, a Claude answer and the coffee break each show once")
    func otherKindsShowOnce() async throws {
        var rules = InboxNotificationRules()
        rules.set(.bigPanel, for: .digestReady)
        rules.set(.desktopNotification, for: .claudeAnswered)
        rules.set(.bigPanel, for: .coffeeBreak)
        let setup = try Setup(rules: rules)
        let model = setup.model

        // The digest lands twice in a day (a manual run and the morning one), a Claude answer lands twice.
        for _ in 0..<2 {
            model.addToInbox(AILanding(subject: .digest, useCase: .digest, answer: nil, text: "A quiet day", failure: nil, at: Self.start))
            model.addToInbox(
                AILanding(
                    subject: .mergeRequest("acme/web/app!12"), useCase: .summarizeThreads, answer: nil, text: "Two open points",
                    failure: nil, at: Self.start))
        }
        model.inbox.addLocal(Self.coffee())
        model.inbox.addLocal(Self.coffee())
        for _ in 0..<200 {
            await Task.yield()
        }

        #expect(await setup.effects.inboxPanels.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.coffeeBreak, .digestReady])
        #expect(await setup.effects.inboxBanners.map(\.kind) == [.claudeAnswered])
        // None of them goes through the build alerts.
        #expect(await setup.effects.alertWindows.isEmpty)
        #expect(await setup.effects.banners.isEmpty)
    }

    // MARK: - INBOX-15

    @Test("INBOX-15 the default group order puts my to-dos and the coffee first, builds and other last")
    func defaultOrder() {
        #expect(InboxGroup.allCases == [.myToDos, .whatsNew, .coffee, .claude, .mentions, .reviewRequests, .assigned, .builds, .other])
        #expect(InboxNotificationRules().groupOrder == InboxGroup.allCases)
        #expect(InboxEventKind.coffeeBreak.group == .coffee)
        #expect(InboxEventKind.whatsNew.group == .whatsNew)
        #expect(InboxEventKind.buildFailed.group == .builds)
        #expect(InboxEventKind.pipelineFailed.group == .builds)
        #expect(InboxEventKind.myTodo.group == .myToDos)
        #expect(InboxEventKind.otherTodo.group == .other)
    }

    @Test("INBOX-15 a saved group order survives updates: unknown names go, new groups land after their predecessor")
    func orderIsRobust() {
        // A group the saved order doesn't know takes its default place after the one before it.
        let saved = ["other", "claude", "mentions", "reviewRequests", "assigned", "myToDos"]
        #expect(
            InboxGroupOrder.merged(stored: saved)
                == [.other, .claude, .mentions, .reviewRequests, .assigned, .builds, .myToDos, .whatsNew, .coffee])
        // Unknown names and repeats are dropped.
        #expect(
            InboxGroupOrder.merged(stored: ["retired", "other", "other", "builds"])
                == [.myToDos, .whatsNew, .coffee, .claude, .mentions, .reviewRequests, .assigned, .other, .builds])
        #expect(InboxGroupOrder.merged(stored: []) == InboxGroup.allCases)
        // The default order is kept as nothing, so a later group lands in its place.
        #expect(InboxGroupOrder.stored(InboxGroup.allCases).isEmpty)
        var rules = InboxNotificationRules()
        rules.setGroupOrder(InboxGroup.allCases.reversed())
        #expect(rules.groupOrder == InboxGroup.allCases.reversed())
        rules.setGroupOrder(InboxGroup.allCases)
        #expect(rules.groupOrderNames.isEmpty)
        // A drag, with SwiftUI's offsets: the last group to the top, the first to the end.
        #expect(InboxGroupOrder.moving(InboxGroup.allCases, from: [8], to: 0).first == .other)
        #expect(InboxGroupOrder.moving(InboxGroup.allCases, from: [0], to: 9).last == .myToDos)
        #expect(InboxGroupOrder.moving([.mentions, .assigned, .other], from: [0], to: 2) == [.assigned, .mentions, .other])
    }

    @Test("INBOX-15 the Inbox lists its groups in the user's order, and the coffee and builds have their own")
    func inboxFollowsTheOrder() throws {
        let setup = try Setup()
        let store = setup.model.inbox
        store.addLocal(Self.coffee())
        store.addLocal(.buildFailed(
            jobKey: "main|MR-1", number: 1, label: "!1 #1", isUnstable: false, title: "Fix", url: Self.gitLab, at: Self.start))
        store.addLocal(
            .claudeAnswered(
                subjectKey: "a", useCase: "Why Did It Fail?", failed: false, title: "Fix", reference: nil, excerpt: nil, url: nil,
                at: Self.start))
        store.addMyTodo("Water the plants")

        #expect(store.sections.map(\.group) == [.myToDos, .coffee, .claude, .builds])
        var rules = InboxNotificationRules()
        rules.setGroupOrder([.builds, .claude, .coffee, .other, .assigned, .reviewRequests, .mentions, .myToDos])
        store.rules = rules
        #expect(store.sections.map(\.group) == [.builds, .claude, .coffee, .myToDos])
        #expect(store.sections(InboxFilter(group: .coffee)).map(\.group) == [.coffee])
    }
}
