import Foundation

/// Which builds may alert: a switch for My Builds, one for Watching, and a setting per job that beats both (ALERT-09).
///
/// It only mutes the glass alert and the banners. The list, the status icon's counts and the pane never look at it.
/// The global preferences stay where they were: the announcer still skips a stage banner while Stage Alerts is off, so
/// "Always Notify" never turns on what Settings turned off.
///
/// A job is keyed like ``BuildID/jobKey``, the project and the job's name, so a setting holds for every build the job
/// gets from now on, not for one build number. Hiding a build until the next one (HIDE-01) doesn't change an alert
/// either, since alerts go on while a build is hidden.
public struct NotificationPolicy: Codable, Hashable, Sendable {
    /// What a job's setting says; a job without one follows its group.
    public enum JobSetting: String, Codable, CaseIterable, Sendable {
        case always
        case never
    }

    /// The two groups of followed builds.
    public enum Group: String, Codable, CaseIterable, Sendable {
        case mine
        case watching

        /// Returns the group of a build.
        ///
        /// - Parameter build: the build
        /// - Returns: My Builds for a build of mine, Watching for a watched one
        public init(_ build: Build) {
            self = build.kind == .mine ? .mine : .watching
        }
    }

    /// whether the builds of my jobs alert
    public var mine: Bool
    /// whether the builds of the watched jobs alert
    public var watching: Bool
    /// the jobs with a setting of their own, by job key
    public var jobs: [String: JobSetting]

    public init(mine: Bool = true, watching: Bool = true, jobs: [String: JobSetting] = [:]) {
        self.mine = mine
        self.watching = watching
        self.jobs = jobs
    }

    // A value stored before a field existed decodes with that field's default, and a setting that isn't one of the
    // cases is dropped.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mine = try container.decodeIfPresent(Bool.self, forKey: .mine) ?? true
        watching = try container.decodeIfPresent(Bool.self, forKey: .watching) ?? true
        let raw = try container.decodeIfPresent([String: String].self, forKey: .jobs) ?? [:]
        jobs = raw.compactMapValues(JobSetting.init(rawValue:))
    }

    /// Returns whether a group's builds alert.
    ///
    /// - Parameter group: the group
    /// - Returns: the group's switch
    public func isOn(_ group: Group) -> Bool {
        switch group {
        case .mine: mine
        case .watching: watching
        }
    }

    /// Returns whether a build's alerts show: the job's setting, or else its group's switch.
    ///
    /// - Parameter build: the build
    /// - Returns: `false` when the glass alert and the banners stay quiet for it
    public func shouldNotify(_ build: Build) -> Bool {
        shouldNotify(job: build.jobKey, in: Group(build))
    }

    /// Returns whether a job's alerts show: the job's setting, or else its group's switch.
    ///
    /// - Parameters:
    ///   - job: the job key
    ///   - group: the job's group
    /// - Returns: `false` when the alerts stay quiet for it
    public func shouldNotify(job: String, in group: Group) -> Bool {
        switch jobs[job] {
        case .always?: true
        case .never?: false
        case nil: isOn(group)
        }
    }

    /// Sets a group's switch.
    ///
    /// - Parameters:
    ///   - group: the group
    ///   - isOn: whether its builds alert
    public mutating func set(_ group: Group, isOn: Bool) {
        switch group {
        case .mine: mine = isOn
        case .watching: watching = isOn
        }
    }

    /// Sets a job's setting.
    ///
    /// - Parameters:
    ///   - setting: the setting; `nil` makes the job follow its group again
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
        case mine, watching, jobs
    }
}
