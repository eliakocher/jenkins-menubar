import Foundation
import Testing

@testable import MenubarCore

@Suite("NotificationPolicy")
struct NotificationPolicyTests {
    private static func build(_ job: String = "MR-1", kind: JobKind, project: ProjectID = .main) -> Build {
        Build(job: job, number: 3, kind: kind, phase: .running, startedAt: Date(timeIntervalSince1970: 0)).stamped(project)
    }

    @Test(
        "ALERT-09 only a job set to Never stays quiet; the table decides the rest",
        arguments: [
            (nil, true), (NotificationPolicy.JobSetting.always, true), (.never, false),
        ] as [(NotificationPolicy.JobSetting?, Bool)], [JobKind.mine, .watched])
    func decision(row: (setting: NotificationPolicy.JobSetting?, notifies: Bool), kind: JobKind) {
        var policy = NotificationPolicy()
        policy.set(row.setting, forJob: "MR-1")

        #expect(policy.shouldNotify(Self.build(kind: kind)) == row.notifies)
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

    @Test("ALERT-09 the policy survives a round trip through UserDefaults, and reads the old switches as nothing")
    func persistence() {
        let suite = TemporaryDefaults()
        let store = PreferencesStore(defaults: suite.defaults)
        #expect(store.notificationPolicy == NotificationPolicy())

        let policy = NotificationPolicy(jobs: ["MR-1": .never, "p-2/feature%252Ffoo": .always])
        store.notificationPolicy = policy
        #expect(PreferencesStore(defaults: suite.defaults).notificationPolicy == policy)

        // The default policy keeps no key; text that doesn't decode reads as the default; an unknown setting is dropped.
        store.notificationPolicy = NotificationPolicy()
        #expect(suite.defaults.object(forKey: PreferencesStore.notificationPolicyKey) == nil)
        suite.defaults.set("not json", forKey: PreferencesStore.notificationPolicyKey)
        #expect(store.notificationPolicy == NotificationPolicy())
        // The old My Builds and Watching switches are in files already written; the migration reads them, nothing else does.
        suite.defaults.set(#"{"watching":false,"jobs":{"MR-1":"sometimes","MR-2":"never"}}"#, forKey: PreferencesStore.notificationPolicyKey)
        #expect(store.notificationPolicy == NotificationPolicy(jobs: ["MR-2": .never]))
    }
}
