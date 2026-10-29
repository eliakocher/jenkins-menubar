import MenubarCore

/// The options of the Settings pop-ups and radio groups, in Title Style (`docs/design/settings.md`, Copy). The work
/// items' toolbar filter menu uses the same words for Show, Type and State (`docs/design/settings-gitlab.md`).
public enum SettingsOptionTitles {
    /// "30 Seconds", "1 Minute", "2 Minutes": the check interval and the GitLab maximum age
    public static func seconds(_ seconds: Int) -> String {
        if seconds >= 60, seconds % 60 == 0 {
            let minutes = seconds / 60
            return minutes == 1 ? "1 Minute" : "\(minutes) Minutes"
        }
        return seconds == 1 ? "1 Second" : "\(seconds) Seconds"
    }

    /// "Immediately", "1 Hour", "8 Hours", "1 Day", "3 Days", "1 Week", "2 Weeks", "Never" (HIDE-02)
    public static func hideAfter(_ value: Preferences.HideAfter) -> String {
        switch value {
        case .immediately: return "Immediately"
        case .never: return "Never"
        case .hours(let hours):
            if hours % 168 == 0 {
                return count(hours / 168, "Week")
            }
            if hours % 24 == 0 {
                return count(hours / 24, "Day")
            }
            return count(hours, "Hour")
        }
    }

    /// "Alert Window" or "Banner" (ALERT-03)
    public static func alertStyle(_ style: Preferences.AlertStyle) -> String {
        switch style {
        case .window: "Alert Window"
        case .banner: "Banner"
        }
    }

    /// "Monochrome" or "Color" (PIPE-05)
    public static func iconStyle(_ style: Preferences.IconStyle) -> String {
        switch style {
        case .monochrome: "Monochrome"
        case .color: "Color"
        }
    }

    /// "Assigned to Me" or "Created by Me" (WI-02)
    public static func scope(_ scope: WorkItemFilters.Scope) -> String {
        switch scope {
        case .assigned: "Assigned to Me"
        case .authored: "Created by Me"
        }
    }

    /// "All Types", "Issues", "Tasks", "Epics" or "Incidents" (WI-02)
    public static func type(_ type: WorkItemFilters.TypeFilter) -> String {
        switch type {
        case .all: "All Types"
        case .issue: "Issues"
        case .task: "Tasks"
        case .epic: "Epics"
        case .incident: "Incidents"
        }
    }

    /// "Open", "Closed" or "Open and Closed" (WI-02)
    public static func state(_ state: WorkItemFilters.StateFilter) -> String {
        switch state {
        case .opened: "Open"
        case .closed: "Closed"
        case .all: "Open and Closed"
        }
    }

    /// "Recently Updated", "Recently Created", "Oldest First", "Due Date", "Title", "Weight" or "Priority" (WI-02)
    public static func sort(_ sort: WorkItemFilters.Sort) -> String {
        switch sort {
        case .recentlyUpdated: "Recently Updated"
        case .recentlyCreated: "Recently Created"
        case .oldestFirst: "Oldest First"
        case .dueDate: "Due Date"
        case .title: "Title"
        case .weight: "Weight"
        case .priority: "Priority"
        }
    }

    /// "All of These" or "Any of These" (WI-03)
    public static func labelsMatch(_ match: WorkItemFilters.LabelsMatch) -> String {
        switch match {
        case .all: "All of These"
        case .any: "Any of These"
        }
    }

    /// "Must Have" or "Must Have None of These", the label lists' names (WI-03)
    public static func labelList(_ list: WorkItemFilters.LabelList) -> String {
        switch list {
        case .with: "Must Have"
        case .without: "Must Have None of These"
        }
    }

    private static func count(_ value: Int, _ unit: String) -> String {
        value == 1 ? "1 \(unit)" : "\(value) \(unit)s"
    }
}
