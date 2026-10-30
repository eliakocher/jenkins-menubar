import Foundation
import Testing

@testable import MenubarCore

@Suite("NotificationPolicy")
struct NotificationPolicyTests {
    private static func build(_ job: String = "MR-1", kind: JobKind, project: ProjectID = .main) -> Build {
        Build(job: job, number: 3, kind: kind, phase: .running, startedAt: Date(timeIntervalSince1970: 0)).stamped(project)
    }

    /// the job's setting, the group's switch and what the decision is
    typealias Row = (setting: NotificationPolicy.JobSetting?, groupIsOn: Bool, notifies: Bool)

    @Test(
        "ALERT-09 the job's setting beats the group's switch",
        arguments: [
            (nil, true, true), (nil, false, false),
            (NotificationPolicy.JobSetting.always, true, true), (.always, false, true),
            (.never, true, false), (.never, false, false),
        ] as [Row], NotificationPolicy.Group.allCases)
    func decision(row: Row, group: NotificationPolicy.Group) {
        var policy = NotificationPolicy()
        policy.set(group, isOn: row.groupIsOn)
        policy.set(row.setting, forJob: "MR-1")
        let build = Self.build(kind: group == .mine ? .mine : .watched)

        #expect(policy.shouldNotify(build) == row.notifies)
        // The other group's switch never matters.
        let other: NotificationPolicy.Group = group == .mine ? .watching : .mine
        policy.set(other, isOn: !policy.isOn(other))
        #expect(policy.shouldNotify(build) == row.notifies)
    }

    @Test("ALERT-09 notifies for everything by default")
    func defaults() {
        let policy = NotificationPolicy()
        #expect(policy.mine && policy.watching && policy.jobs.isEmpty)
        #expect(policy.shouldNotify(Self.build(kind: .mine)))
        #expect(policy.shouldNotify(Self.build(kind: .watched)))
    }

    @Test("ALERT-09 a job is keyed by its project and name, not by its build number")
    func keyedByJob() {
        var policy = NotificationPolicy()
        policy.set(.never, forJob: Self.build(kind: .mine).jobKey)
        var next = Self.build(kind: .mine)
        next.number = 99
        let other = ProjectID(rawValue: "p-2")!

        #expect(!policy.shouldNotify(next))
        #expect(policy.shouldNotify(Self.build("MR-2", kind: .mine)))
        // The same job name in another project is another job.
        #expect(policy.shouldNotify(Self.build(kind: .mine, project: other)))
    }

    @Test("ALERT-09 setting a job to nil makes it follow its group again")
    func clearsASetting() {
        var policy = NotificationPolicy(watching: false, jobs: ["MR-1": .always])
        #expect(policy.shouldNotify(Self.build(kind: .watched)))
        policy.set(nil, forJob: "MR-1")
        #expect(policy.jobs.isEmpty)
        #expect(!policy.shouldNotify(Self.build(kind: .watched)))
    }

    @Test("ALERT-09 the policy survives a round trip through UserDefaults")
    func persistence() {
        let suite = TemporaryDefaults()
        let store = PreferencesStore(defaults: suite.defaults)
        #expect(store.notificationPolicy == NotificationPolicy())

        let policy = NotificationPolicy(mine: true, watching: false, jobs: ["MR-1": .never, "p-2/feature%252Ffoo": .always])
        store.notificationPolicy = policy
        #expect(PreferencesStore(defaults: suite.defaults).notificationPolicy == policy)

        // The default policy keeps no key; text that doesn't decode reads as the default; an unknown setting is dropped.
        store.notificationPolicy = NotificationPolicy()
        #expect(suite.defaults.object(forKey: PreferencesStore.notificationPolicyKey) == nil)
        suite.defaults.set("not json", forKey: PreferencesStore.notificationPolicyKey)
        #expect(store.notificationPolicy == NotificationPolicy())
        suite.defaults.set(#"{"watching":false,"jobs":{"MR-1":"sometimes","MR-2":"never"}}"#, forKey: PreferencesStore.notificationPolicyKey)
        #expect(store.notificationPolicy == NotificationPolicy(watching: false, jobs: ["MR-2": .never]))
    }
}
