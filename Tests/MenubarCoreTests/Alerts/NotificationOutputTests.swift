import Foundation
import Testing

@testable import MenubarCore

/// The rule table of Settings → Notifications: what each event does for each choice, builds and the other events.
@Suite("NotificationOutput")
struct NotificationOutputTests {
    private static let jobURL = URL(string: "https://jenkins.example.com/job/project")!

    private static func alert(_ result: BuildResult, kind: JobKind = .mine, job: String = "MR-1") throws -> BuildAlert {
        let build = Build(
            job: job, number: 7, title: "Fix the login", kind: kind, phase: .finished(result: result, duration: 600),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let content = try #require(
            AlertContent.finished(build, failedStages: [], links: AlertContent.links(for: build, jobURL: jobURL)))
        return BuildAlert(kind: .finished, build: build, content: content)
    }

    // MARK: ALERT-12

    @Test(
        "ALERT-12 a choice is a pop-up, a banner, an Inbox entry or nothing; every choice but Off is an Inbox entry, and a build also plays its sound",
        arguments: [
            (InboxDelivery.popUp, true, NotificationOutput(popUp: true, sound: true, inboxEntry: true)),
            (.popUp, false, NotificationOutput(popUp: true, inboxEntry: true)),
            (.banner, true, NotificationOutput(banner: true, sound: true, inboxEntry: true)),
            (.banner, false, NotificationOutput(banner: true, inboxEntry: true)),
            (.inbox, true, NotificationOutput(inboxEntry: true)),
            (.inbox, false, NotificationOutput(inboxEntry: true)),
            (.off, true, .nothing),
            (.off, false, .nothing),
        ])
    func choices(choice: InboxDelivery, isBuild: Bool, expected: NotificationOutput) {
        #expect(NotificationOutput(choice, isBuild: isBuild) == expected)
    }

    @Test("ALERT-12 the defaults: my builds pop up, the builds I watch are banners, GitLab's pipeline failed is Off, everything else is an Inbox entry")
    func defaultRows() {
        let rules = InboxNotificationRules()

        #expect(rules.output(for: .buildFailed) == NotificationOutput(popUp: true, sound: true, inboxEntry: true))
        #expect(rules.output(for: .buildSucceeded) == NotificationOutput(popUp: true, sound: true, inboxEntry: true))
        #expect(rules.output(for: .watchedBuildFailed) == NotificationOutput(banner: true, sound: true, inboxEntry: true))
        #expect(rules.output(for: .watchedBuildSucceeded) == NotificationOutput(banner: true, sound: true, inboxEntry: true))
        for kind in InboxNotificationRules.deliveryKinds where !kind.isFinishedBuild {
            #expect(rules.output(for: kind) == (kind == .pipelineFailed ? .nothing : NotificationOutput(inboxEntry: true)))
        }
        // The Red Dot: everything counts but the successful builds.
        for kind in InboxNotificationRules.settingsKinds {
            #expect(rules.sends(kind, to: .badge) == (kind != .buildSucceeded && kind != .watchedBuildSucceeded))
        }
    }

    // MARK: ALERT-12, finished builds

    @Test(
        "ALERT-12 a finished build follows the row of its owner and result: failed and unstable are one row, aborted and other results have none",
        arguments: [
            (AlertContent.Ownership.mine, AlertContent.ResultKind.failure, InboxEventKind.buildFailed),
            (.mine, .unstable, .buildFailed),
            (.mine, .success, .buildSucceeded),
            (.watched, .failure, .watchedBuildFailed),
            (.watched, .unstable, .watchedBuildFailed),
            (.watched, .success, .watchedBuildSucceeded),
        ])
    func buildRows(ownership: AlertContent.Ownership, result: AlertContent.ResultKind, kind: InboxEventKind) {
        #expect(InboxNotificationRules.buildKind(ownership: ownership, result: result) == kind)
    }

    @Test("ALERT-12 an aborted build and any other result alert nothing", arguments: [AlertContent.Ownership.mine, .watched])
    func noRow(ownership: AlertContent.Ownership) {
        #expect(InboxNotificationRules.buildKind(ownership: ownership, result: .aborted) == nil)
        #expect(InboxNotificationRules.buildKind(ownership: ownership, result: .other) == nil)
    }

    @Test(
        "ALERT-09 a job's own setting beats the table: Never is nothing at all, Always is one of my builds",
        arguments: [
            (nil, JobKind.watched, BuildResult.failure, NotificationOutput(banner: true, sound: true, inboxEntry: true)),
            (.always, .watched, .failure, NotificationOutput(popUp: true, sound: true, inboxEntry: true)),
            (.always, .watched, .aborted, .nothing),
            (.never, .mine, .failure, .nothing),
            (.never, .watched, .success, .nothing),
            (nil, .mine, .aborted, .nothing),
        ] as [(NotificationPolicy.JobSetting?, JobKind, BuildResult, NotificationOutput)])
    func jobSettings(
        setting: NotificationPolicy.JobSetting?, kind: JobKind, result: BuildResult, expected: NotificationOutput
    ) throws {
        let output = InboxNotificationRules().output(for: try Self.alert(result, kind: kind), jobSetting: setting)
        #expect(output == expected)
    }

    @Test("ALERT-12 every row can be set to any choice, and a choice kept for a row changes only that row")
    func rowsAreIndependent() throws {
        var rules = InboxNotificationRules()
        rules.set(.off, for: .buildSucceeded)
        rules.set(.inbox, for: .buildFailed)

        #expect(rules.output(for: try Self.alert(.success), jobSetting: nil) == .nothing)
        #expect(rules.output(for: try Self.alert(.failure), jobSetting: nil) == NotificationOutput(inboxEntry: true))
        // The watched rows didn't move.
        #expect(rules.output(for: try Self.alert(.failure, kind: .watched), jobSetting: nil).banner)
    }

    // MARK: ALERT-13

    @Test("ALERT-13 the summary says in plain words what the current choices do, in three sentences")
    func summaryText() {
        let defaults = NotificationSummary.text(for: InboxNotificationRules())
        #expect(
            defaults
                == "When your Jenkins build fails: a pop-up with a sound, and it waits in the Inbox until you mark it done. When it succeeds: a pop-up with a sound, and it waits in the Inbox. Jenkins builds you only watch: a banner when they finish; both wait in the Inbox."
        )

        var rules = InboxNotificationRules()
        rules.set(.banner, for: .buildFailed)
        rules.set(.inbox, for: .buildSucceeded)
        rules.set(.off, for: .watchedBuildFailed)
        rules.set(.popUp, for: .watchedBuildSucceeded)
        #expect(
            NotificationSummary.text(for: rules)
                == "When your Jenkins build fails: a banner with a sound, and it waits in the Inbox until you mark it done. When it succeeds: no pop-up, no sound; it waits in the Inbox. Jenkins builds you only watch: nothing when they fail, a pop-up when they succeed; it waits in the Inbox."
        )

        for kind in InboxNotificationRules.buildKinds {
            rules.set(.off, for: kind)
        }
        #expect(
            NotificationSummary.text(for: rules)
                == "When your Jenkins build fails: nothing. When it succeeds: nothing. Jenkins builds you only watch: nothing.")
        // Three sentences at most, whatever the choices.
        for choice in InboxDelivery.allCases {
            for kind in InboxNotificationRules.buildKinds {
                rules.set(choice, for: kind)
            }
            #expect(NotificationSummary.text(for: rules).filter { $0 == "." }.count == 3)
        }
    }
}
