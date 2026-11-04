import Foundation

/// The settings of single jobs that beat the table of Settings → Notifications (ALERT-09): a job that is always treated
/// like one of my builds, and a job that never notifies at all.
///
/// Which builds alert, and how, is the table's four build rows (``InboxNotificationRules/delivery(for:)``); this is only
/// the exception per job. "Never" means nothing at all: no pop-up, no banner, no sound and no Inbox entry. The list, the
/// status icon's counts and the pane never look at it.
///
/// A job is keyed like ``BuildID/jobKey``, the project and the job's name, so a setting holds for every build the job
/// gets from now on, not for one build number. Hiding a build until the next one (HIDE-01) doesn't change an alert
/// either, since alerts go on while a build is hidden.
public struct NotificationPolicy: Codable, Hashable, Sendable {
    /// What a job's setting says; a job without one follows the table.
    public enum JobSetting: String, Codable, CaseIterable, Sendable {
        /// treated like one of my builds, whoever's it is
        case always
        /// nothing at all
        case never
    }

    /// the jobs with a setting of their own, by job key
    public var jobs: [String: JobSetting]

    public init(jobs: [String: JobSetting] = [:]) {
        self.jobs = jobs
    }

    // A value stored before the single table (Task 7.14) also holds `mine` and `watching`: they are read by
    // ``NotificationMigration`` and otherwise ignored. A setting that isn't one of the cases is dropped.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([String: String].self, forKey: .jobs) ?? [:]
        jobs = raw.compactMapValues(JobSetting.init(rawValue:))
    }

    /// Returns whether a build's alerts may show at all: `false` for a job set to never.
    ///
    /// - Parameter build: the build
    public func shouldNotify(_ build: Build) -> Bool {
        jobs[build.jobKey] != .never
    }

    /// Sets a job's setting.
    ///
    /// - Parameters:
    ///   - setting: the setting; `nil` makes the job follow the table again
    ///   - job: the job key
    public mutating func set(_ setting: JobSetting?, forJob job: String) {
        jobs[job] = setting
    }

    /// Returns the alerts that may show.
    ///
    /// - Parameter alerts: a check's alerts
    /// - Returns: the alerts of the builds that ``shouldNotify(_:)`` lets through, in order
    public func filter(_ alerts: [BuildAlert]) -> [BuildAlert] {
        alerts.filter { shouldNotify($0.build) }
    }

    private enum CodingKeys: String, CodingKey {
        case jobs
    }
}
