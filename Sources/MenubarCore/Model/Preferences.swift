import Foundation

/// The personal preferences, edited in Settings and kept in UserDefaults (SET-01).
///
/// Each value has its options; ``PreferencesStore`` reads a stored value outside them as the default.
public struct Preferences: Codable, Hashable, Sendable {
    /// how often Jenkins is checked, one of ``checkIntervalOptions``
    public var checkIntervalSeconds: Int
    /// when successful builds hide, one of ``hideSuccessfulOptions`` (HIDE-02)
    public var hideSuccessfulAfter: HideAfter
    /// when builds with any other result hide, one of ``hideFailedOptions`` (HIDE-02)
    public var hideFailedAfter: HideAfter
    /// whether the builds of merged MRs hide (HIDE-03)
    public var hidesMergedBuilds: Bool
    /// how a finished build is announced (ALERT-03)
    public var alertStyle: AlertStyle
    /// whether a banner shows as soon as a stage fails (ALERT-05)
    public var stageAlerts: Bool
    /// how the status icon draws the counts (PIPE-05)
    public var iconStyle: IconStyle
    /// how old GitLab data may be when it is shown, one of ``gitLabMaxAgeOptions`` (OD-02)
    public var gitLabMaxAgeSeconds: Int
    /// which work items load (WI-02, WI-03)
    public var workItems: WorkItemFilters
    /// whether the status icon is in the menu bar; with it off, the checks and alerts go on (APP-01)
    public var showInMenuBar: Bool
    /// whether Watch a Build… fills in a link from the clipboard by itself, with macOS's prompt (WATCH-01)
    public var fillInCopiedLink: Bool
    /// the shortcut that opens the main window from anywhere; none until the user records one (APP-08)
    public var globalShortcut: HotkeyShortcut?
    /// whether the easter eggs show; off, the app behaves as FEATURES.md describes (EGG-01)
    public var easterEggs: Bool
    /// whether a banner warns before a slot's code freeze while committed work items have no merged MR; off by default
    /// and never with a sound (SLOT-04)
    public var slotAlerts: Bool

    public init(
        checkIntervalSeconds: Int = 60,
        hideSuccessfulAfter: HideAfter = .hours(24),
        hideFailedAfter: HideAfter = .hours(168),
        hidesMergedBuilds: Bool = true,
        alertStyle: AlertStyle = .window,
        stageAlerts: Bool = true,
        iconStyle: IconStyle = .monochrome,
        gitLabMaxAgeSeconds: Int = 30,
        workItems: WorkItemFilters = WorkItemFilters(),
        showInMenuBar: Bool = true,
        fillInCopiedLink: Bool = false,
        globalShortcut: HotkeyShortcut? = nil,
        easterEggs: Bool = true,
        slotAlerts: Bool = false
    ) {
        self.checkIntervalSeconds = checkIntervalSeconds
        self.hideSuccessfulAfter = hideSuccessfulAfter
        self.hideFailedAfter = hideFailedAfter
        self.hidesMergedBuilds = hidesMergedBuilds
        self.alertStyle = alertStyle
        self.stageAlerts = stageAlerts
        self.iconStyle = iconStyle
        self.gitLabMaxAgeSeconds = gitLabMaxAgeSeconds
        self.workItems = workItems
        self.showInMenuBar = showInMenuBar
        self.fillInCopiedLink = fillInCopiedLink
        self.globalShortcut = globalShortcut
        self.easterEggs = easterEggs
        self.slotAlerts = slotAlerts
    }

    private enum CodingKeys: String, CodingKey {
        case checkIntervalSeconds, hideSuccessfulAfter, hideFailedAfter, hidesMergedBuilds, alertStyle
        case stageAlerts, iconStyle, gitLabMaxAgeSeconds, workItems, showInMenuBar, fillInCopiedLink
        case globalShortcut, easterEggs, slotAlerts
    }

    // A value encoded before a field existed decodes with that field's default. One encoded with the dropped
    // `speaksResult` (ALERT-04) decodes too: its key is ignored.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences()
        func value<Value: Decodable>(_ key: CodingKeys, _ fallback: Value) throws -> Value {
            try container.decodeIfPresent(Value.self, forKey: key) ?? fallback
        }
        self.init(
            checkIntervalSeconds: try value(.checkIntervalSeconds, defaults.checkIntervalSeconds),
            hideSuccessfulAfter: try value(.hideSuccessfulAfter, defaults.hideSuccessfulAfter),
            hideFailedAfter: try value(.hideFailedAfter, defaults.hideFailedAfter),
            hidesMergedBuilds: try value(.hidesMergedBuilds, defaults.hidesMergedBuilds),
            alertStyle: try value(.alertStyle, defaults.alertStyle),
            stageAlerts: try value(.stageAlerts, defaults.stageAlerts),
            iconStyle: try value(.iconStyle, defaults.iconStyle),
            gitLabMaxAgeSeconds: try value(.gitLabMaxAgeSeconds, defaults.gitLabMaxAgeSeconds),
            workItems: try value(.workItems, defaults.workItems),
            showInMenuBar: try value(.showInMenuBar, defaults.showInMenuBar),
            fillInCopiedLink: try value(.fillInCopiedLink, defaults.fillInCopiedLink),
            globalShortcut: try? container.decodeIfPresent(HotkeyShortcut.self, forKey: .globalShortcut),
            easterEggs: try value(.easterEggs, defaults.easterEggs),
            slotAlerts: try value(.slotAlerts, defaults.slotAlerts))
    }

    /// 30 s, 1 min (default), 2, 5 or 10 min
    public static let checkIntervalOptions = [30, 60, 120, 300, 600]
    /// immediately, 1 h, 8 h, 1 day (default), 3 days, 1 week, never
    public static let hideSuccessfulOptions: [HideAfter] = [
        .immediately, .hours(1), .hours(8), .hours(24), .hours(72), .hours(168), .never,
    ]
    /// immediately, 1 day, 3 days, 1 week (default), 2 weeks, never
    public static let hideFailedOptions: [HideAfter] = [.immediately, .hours(24), .hours(72), .hours(168), .hours(336), .never]
    /// 15 s, 30 s (default), 1, 2 or 5 min
    public static let gitLabMaxAgeOptions = [15, 30, 60, 120, 300]

    /// When finished builds hide by themselves (HIDE-02). Stored as `immediately`, `never` or the number of hours.
    public enum HideAfter: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        case immediately
        /// once more than this many hours have passed since the build finished
        case hours(Int)
        case never

        public init?(rawValue: String) {
            switch rawValue {
            case "immediately": self = .immediately
            case "never": self = .never
            default:
                guard let hours = Int(rawValue), hours > 0, String(hours) == rawValue else { return nil }
                self = .hours(hours)
            }
        }

        public var rawValue: String {
            switch self {
            case .immediately: "immediately"
            case .hours(let hours): String(hours)
            case .never: "never"
            }
        }

        public var description: String { rawValue }

        /// Returns whether a build that finished this long ago is hidden by now.
        ///
        /// - Parameter seconds: the time since the build finished
        /// - Returns: `true` when it hides
        public func hides(finishedFor seconds: TimeInterval) -> Bool {
            switch self {
            case .immediately: true
            case .hours(let hours): seconds > TimeInterval(hours) * 3600
            case .never: false
            }
        }
    }

    /// The alert window (default) or a banner, never both (ALERT-03).
    public enum AlertStyle: String, Codable, Hashable, Sendable, CaseIterable {
        case window
        case banner
    }

    /// The status icon's symbols: monochrome (default) or colored (PIPE-05).
    public enum IconStyle: String, Codable, Hashable, Sendable, CaseIterable {
        case monochrome
        case color
    }
}

/// The filters of the work items: scope, type, state, sort and limit (WI-02), and the labels (WI-03).
///
/// The raw values are the GitLab GraphQL values the WorkItems query takes.
public struct WorkItemFilters: Codable, Hashable, Sendable {
    public var scope: Scope
    public var type: TypeFilter
    public var state: StateFilter
    public var sort: Sort
    /// how many not-committed work items show at most, one of ``limitOptions``
    public var limit: Int
    /// the labels a work item must have, all or any of them (``labelsMatch``); plain text, never interpreted
    public var withLabels: [String]
    /// the labels a work item must not have; plain text, never interpreted
    public var withoutLabels: [String]
    public var labelsMatch: LabelsMatch

    public init(
        scope: Scope = .assigned,
        type: TypeFilter = .all,
        state: StateFilter = .opened,
        sort: Sort = .recentlyUpdated,
        limit: Int = 20,
        withLabels: [String] = [],
        withoutLabels: [String] = [],
        labelsMatch: LabelsMatch = .all
    ) {
        self.scope = scope
        self.type = type
        self.state = state
        self.sort = sort
        self.limit = limit
        self.withLabels = withLabels
        self.withoutLabels = withoutLabels
        self.labelsMatch = labelsMatch
    }

    /// 10, 20 (default), 30, 50 or 100
    public static let limitOptions = [10, 20, 30, 50, 100]

    /// Assigned to me (default) or created by me.
    public enum Scope: String, Codable, Hashable, Sendable, CaseIterable {
        case assigned
        case authored
    }

    /// All types (default), or one of GitLab's `IssueType` values.
    public enum TypeFilter: String, Codable, Hashable, Sendable, CaseIterable {
        case all
        case issue = "ISSUE"
        case task = "TASK"
        case epic = "EPIC"
        case incident = "INCIDENT"
    }

    /// GitLab's `IssuableState`: open (default), closed, or both.
    public enum StateFilter: String, Codable, Hashable, Sendable, CaseIterable {
        case opened
        case closed
        case all
    }

    /// GitLab's `IssueSort` values that Settings offers, recently updated first (default).
    public enum Sort: String, Codable, Hashable, Sendable, CaseIterable {
        case recentlyUpdated = "UPDATED_DESC"
        case recentlyCreated = "CREATED_DESC"
        case oldestFirst = "CREATED_ASC"
        case dueDate = "DUE_DATE_ASC"
        case title = "TITLE_ASC"
        case weight = "WEIGHT_DESC"
        case priority = "PRIORITY_ASC"
    }

    /// Whether a work item needs all of the must-have labels (default) or any one of them.
    public enum LabelsMatch: String, Codable, Hashable, Sendable, CaseIterable {
        case all
        case any
    }
}
