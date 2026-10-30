import Foundation

/// A `key=value` file of jenkins-menubar, `config/settings` or `config/team.conf`, read the way the old tool read it:
/// a key's value is the rest of the last line that starts with `key=`, comments sit on lines of their own, and an
/// empty value counts as not set.
struct LegacyKeyValues: Sendable {
    private let values: [String: String]

    init(text: String) {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        self.values = values
    }

    /// the key's value; nil when no line sets it, or it is empty
    subscript(key: String) -> String? {
        values[key].flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// How jenkins-menubar's files map to MegaMonitor's values (IMP-01).
enum LegacyFormats {
    /// Returns the preferences with the values of an old `config/settings` applied. A missing or invalid value leaves
    /// the current one, which at first start is the default (SET-01); `PreferencesStore` turns a value outside the new
    /// options into the default when it saves.
    ///
    /// `gitlab_refresh_seconds` is dropped: it was how often GitLab was asked, and the new maximum age means how old
    /// GitLab data may be when it is shown (OD-02). `voice` is dropped too, with the spoken result (ALERT-04).
    ///
    /// - Parameters:
    ///   - settings: the old `config/settings`
    ///   - current: the preferences to apply them to
    /// - Returns: the preferences with the old values
    static func preferences(from settings: LegacyKeyValues, onto current: Preferences) -> Preferences {
        var preferences = current
        func apply<Value>(_ key: String, to path: WritableKeyPath<Preferences, Value>, _ map: (String) -> Value?) {
            if let value = settings[key].flatMap(map) {
                preferences[keyPath: path] = value
            }
        }
        apply("refresh_seconds", to: \.checkIntervalSeconds, number)
        apply("hide_successful_after_hours", to: \.hideSuccessfulAfter, hideAfter)
        apply("hide_failed_after_hours", to: \.hideFailedAfter, hideAfter)
        apply("hide_merged", to: \.hidesMergedBuilds, onOff)
        apply("alert", to: \.alertStyle) { ["dialog": .window, "banner": .banner][$0] }
        apply("stage_alerts", to: \.stageAlerts, onOff)
        apply("menubar_icons", to: \.iconStyle) { ["monochrome": .monochrome, "emoji": .color][$0] }
        apply("work_items_scope", to: \.workItems.scope, WorkItemFilters.Scope.init(rawValue:))
        apply("work_items_type", to: \.workItems.type, WorkItemFilters.TypeFilter.init(rawValue:))
        apply("work_items_state", to: \.workItems.state, WorkItemFilters.StateFilter.init(rawValue:))
        apply("work_items_sort", to: \.workItems.sort, WorkItemFilters.Sort.init(rawValue:))
        apply("work_items_limit", to: \.workItems.limit, number)
        apply("work_items_with_labels", to: \.workItems.withLabels, labels)
        apply("work_items_without_labels", to: \.workItems.withoutLabels, labels)
        apply("work_items_labels_match", to: \.workItems.labelsMatch, WorkItemFilters.LabelsMatch.init(rawValue:))
        return preferences
    }

    /// Returns the team values of an old `config/team.conf`, normalized as TEAM-01 saves them.
    ///
    /// - Parameter conf: the old `config/team.conf`
    /// - Returns: the team values; a value the file doesn't set is empty
    static func team(from conf: LegacyKeyValues) -> TeamValues {
        TeamValues(
            jenkinsJobURL: conf["jenkins_job_url"] ?? "",
            gitLabURL: conf["gitlab_url"] ?? "",
            gitLabProject: conf["gitlab_project"] ?? "",
            committedLabel: conf["committed_label"] ?? "",
            slotLabelPrefix: conf["slot_label_prefix"] ?? "",
            ignoredMergeRequestPrefix: conf["ignored_merge_request_prefix"] ?? ""
        ).normalized()
    }

    /// Returns the jobs of the old `watched` file: one per line, the job before any tab, each once, in the file's order.
    ///
    /// - Parameter text: the file
    /// - Returns: the jobs, like `MR-12` or `feature%252Ffoo`
    static func watchedJobs(from text: String) -> [String] {
        var jobs: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let job = String(line.prefix { $0 != "\t" })
            if !job.isEmpty && !jobs.contains(job) {
                jobs.append(job)
            }
        }
        return jobs
    }

    /// Returns the builds of the old `hidden` file: `job<TAB>number` lines, the last one of a job counting.
    ///
    /// - Parameter text: the file
    /// - Returns: the hidden build number per job
    static func hiddenBuilds(from text: String) -> [String: Int] {
        var hidden: [String: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, !fields[0].isEmpty, let number = number(String(fields[1])) else { continue }
            hidden[String(fields[0])] = number
        }
        return hidden
    }

    /// A number as the old tool's `number_setting` took it: digits only.
    private static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            return nil
        }
        return Int(text)
    }

    /// The old hide hours: a number of hours, `0` for never, or `immediately`.
    private static func hideAfter(_ text: String) -> Preferences.HideAfter? {
        if text == "immediately" {
            return .immediately
        }
        return number(text).map { $0 == 0 ? .never : .hours($0) }
    }

    private static func onOff(_ text: String) -> Bool? {
        ["on": true, "off": false][text]
    }

    /// A comma-separated label list; GitLab label names have no commas.
    private static func labels(_ text: String) -> [String] {
        text.split(separator: ",").map(String.init)
    }
}
