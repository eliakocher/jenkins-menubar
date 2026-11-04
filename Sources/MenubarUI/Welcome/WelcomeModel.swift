import Foundation
import MenubarCore

/// The welcome flow's pages, in their order: seven, and six while `claude` isn't installed, which skips the Claude step (Task 6.4, `docs/design/welcome.md`).
public enum WelcomePage: Int, CaseIterable, Hashable, Sendable {
    case welcome = 1
    case team
    case accounts
    case notifications
    case claude
    case menuBarAndLogin
    case done

    /// the window's title, and page 1's heading
    public static let windowTitle = "Welcome to MegaMonitor"

    /// the page's heading; page 6 has two, which ``WelcomeSummary`` chooses
    var heading: String {
        switch self {
        case .welcome: Self.windowTitle
        case .team: "Team"
        case .accounts: "Accounts"
        case .notifications: "Notifications"
        case .claude: "Claude in MegaMonitor"
        case .menuBarAndLogin: "Menu Bar and Login"
        case .done: "You're Ready"
        }
    }

    /// the SF Symbol of the step's header icon: the matching Settings pane's, a wave for the first step
    var symbol: String {
        switch self {
        case .welcome: "hand.wave.fill"
        case .team: SettingsPane.projects.symbol
        case .accounts: SettingsPane.accounts.symbol
        case .notifications: SettingsPane.notifications.symbol
        case .claude: SettingsPane.claude.symbol
        case .menuBarAndLogin: SettingsPane.general.symbol
        case .done: "checkmark.seal.fill"
        }
    }

    /// Returns the one line under the heading on what the step is for; page 6 says where to find the app instead
    /// (``WelcomeSummary``).
    var intro: String? {
        switch self {
        case .welcome: "Follow your builds, merge requests and work items from the menu bar."
        case .team: "The Jenkins job and GitLab project your team works on."
        case .accounts: "Sign in to Jenkins and GitLab. Tokens stay in your keychain."
        case .notifications: "Your builds pop up when they finish, the ones you watch show as banners. Change each in Settings."
        case .claude: "Explains failed builds and writes your digest, with your own local Claude Code."
        case .menuBarAndLogin: "Checks and alerts run in the background, so the menu bar suits MegaMonitor best."
        case .done: nil
        }
    }

    /// "Get Started" on page 1, "Continue" on pages 2 to 5, "Done" on page 6
    var buttonTitle: String {
        switch self {
        case .welcome: "Get Started"
        case .done: "Done"
        default: "Continue"
        }
    }

    /// Returns the pages the flow shows: all of them, or without the Claude step while `claude` isn't installed.
    ///
    /// - Parameter offersClaude: whether `claude` was found
    /// - Returns: the pages in order
    static func sequence(offersClaude: Bool) -> [WelcomePage] {
        allCases.filter { offersClaude || $0 != .claude }
    }

    /// Returns "Step 2 of 6".
    ///
    /// - Parameter offersClaude: whether `claude` was found, which adds the Claude step
    func stepText(offersClaude: Bool) -> String {
        let pages = Self.sequence(offersClaude: offersClaude)
        let number = (pages.firstIndex(of: self) ?? 0) + 1
        return "Step \(String(number)) of \(String(pages.count))"
    }

    /// Returns the page after this one, skipping the Claude step without `claude`.
    func next(offersClaude: Bool) -> WelcomePage? {
        let pages = Self.sequence(offersClaude: offersClaude)
        return pages.firstIndex(of: self).flatMap { pages.indices.contains($0 + 1) ? pages[$0 + 1] : nil }
    }

    /// Returns the page before this one, skipping the Claude step without `claude`.
    func previous(offersClaude: Bool) -> WelcomePage? {
        let pages = Self.sequence(offersClaude: offersClaude)
        return pages.firstIndex(of: self).flatMap { $0 > 0 ? pages[$0 - 1] : nil }
    }

    /// Returns whether the page shows Back: never on page 1, and not on Notifications while macOS never asked, where
    /// the page's one button asks ("Include only one button", HIG Privacy).
    ///
    /// - Parameter notifications: what macOS answered; nil while it isn't read yet
    /// - Returns: `true` when Back shows
    func showsBack(notifications: NotificationPermission?) -> Bool {
        switch self {
        case .welcome: false
        case .notifications: !Self.asksForNotifications(notifications)
        default: true
        }
    }

    /// whether Continue on page 4 asks macOS: it never asked, or its answer isn't read yet
    static func asksForNotifications(_ notifications: NotificationPermission?) -> Bool {
        notifications == nil || notifications == .notAsked
    }
}

/// One status line: ok, a note, or a problem, as Settings' ``StatusLine`` draws it.
struct WelcomeLine: Hashable, Sendable, Identifiable {
    var kind: StatusKind
    var text: String
    /// what the line's "Open System Settings…" opens; nil without the button
    var opens: SystemSettingsPage?
    var id: String { text }

    /// A page of System Settings that a line links to.
    enum SystemSettingsPage: Hashable, Sendable {
        /// Notifications, at the app
        case notifications
        /// General → Login Items
        case loginItems
    }

    static func ok(_ text: String) -> WelcomeLine { WelcomeLine(kind: .ok, text: text) }
    static func note(_ text: String, opens: SystemSettingsPage? = nil) -> WelcomeLine {
        WelcomeLine(kind: .note, text: text, opens: opens)
    }
    static func problem(_ text: String) -> WelcomeLine { WelcomeLine(kind: .problem, text: text) }
}

/// What page 1 shows of the import from jenkins-menubar (IMP-01).
struct WelcomeImportSummary: Hashable, Sendable {
    /// "The Jenkins token, from ~/.zshrc", "The settings", "2 watched builds" …; empty when nothing was imported
    var imported: [String]
    /// the old tool left traces but its folder wasn't found: the note and "Choose Folder…" show
    var folderMissing: Bool

    /// the note for a missing folder, ``NotMoved/oldFolder``'s message
    static let folderMissingText = NotMoved.oldFolder.message
    /// the line under the note after Choose Folder… with a folder that isn't the old tool's
    static let wrongFolderText =
        "That folder has no config/settings or config/team.conf: choose the jenkins-menubar folder"
    /// the line without the old tool
    static let freshText = "Setup takes a minute: the team's job and project, your tokens, and notifications"

    /// whether neither was found: page 1 shows ``freshText``
    var isFresh: Bool {
        imported.isEmpty && !folderMissing
    }

    /// Returns what page 1 shows of an import.
    ///
    /// - Parameter report: the import's report, from the last run; nil when none ran
    /// - Returns: the lines
    static func make(_ report: LegacyImportReport?) -> WelcomeImportSummary {
        guard let report else {
            return WelcomeImportSummary(imported: [], folderMissing: false)
        }
        var lines: [String] = []
        for token in report.tokens {
            if case .imported(let source) = token.outcome {
                lines.append("The \(token.account.displayName) token, from \(sourceName(source))")
            }
        }
        if report.importedSettings {
            lines.append("The settings")
        }
        if report.importedTeam {
            lines.append("The team values")
        }
        if report.watchedJobs > 0 {
            lines.append(report.watchedJobs == 1 ? "1 watched build" : "\(String(report.watchedJobs)) watched builds")
        }
        if report.hiddenBuilds > 0 {
            lines.append(report.hiddenBuilds == 1 ? "1 hidden build" : "\(String(report.hiddenBuilds)) hidden builds")
        }
        return WelcomeImportSummary(imported: lines, folderMissing: report.notMoved.contains(.oldFolder))
    }

    /// where an imported token came from, as page 1 says it
    private static func sourceName(_ source: LegacyToken.Source) -> String {
        switch source {
        case .oldKeychain: "jenkins-menubar's keychain item"
        case .environment: "the environment"
        case .zshrc: "~/.zshrc"
        case .zshrcComputed, .missing: source.displayName
        }
    }
}

/// What page 6 shows: where to find the app, what is still missing, and what didn't move from jenkins-menubar
/// (IMP-03).
struct WelcomeSummary: Hashable, Sendable {
    /// "You're Ready", or "Almost Ready" while a token is missing or rejected
    var heading: String
    /// where the builds show: the menu bar, or the window while the item is hidden
    var whereToFind: String
    /// a note per missing token, a problem per rejected one, and notes for notifications that are off and for a login
    /// item that waits for approval
    var stillMissing: [WelcomeLine]
    /// what the import didn't move, without what was fixed since; empty without an import
    var didNotMove: [String]
    /// the easter egg line under the page, with the eggs on (EGG-22)
    var eggLine: String? = nil

    static let noJenkinsToken = "No Jenkins token: builds can't be checked"
    static let noGitLabToken = "No GitLab token: merge requests and work items don't show"

    /// Returns page 6 for the state the flow reached.
    ///
    /// - Parameters:
    ///   - report: the import's report; nil when none ran
    ///   - storedTokens: the tokens in the keychain now
    ///   - accounts: what the account check found, empty while it runs
    ///   - notifications: what macOS answered; nil while it isn't read yet
    ///   - loginItem: the login item's status
    ///   - preferences: the preferences, for the menu bar item and the notification line
    ///   - teamComplete: whether the three required team values are saved
    /// - Returns: the summary
    static func make(
        report: LegacyImportReport?, storedTokens: Set<TokenAccount>, accounts: [TokenAccount: AccountStatus] = [:],
        notifications: NotificationPermission?, loginItem: LoginItemStatus = .enabled, preferences: Preferences,
        teamComplete: Bool
    ) -> WelcomeSummary {
        var stillMissing: [WelcomeLine] = []
        for account in TokenAccount.allCases {
            if !storedTokens.contains(account) {
                stillMissing.append(.note(account == .jenkins ? noJenkinsToken : noGitLabToken))
            } else if let status = accounts[account], rejects(status) {
                // "You're Ready" must be true: a stored token the server refuses checks nothing either.
                stillMissing.append(.problem(status.message))
            }
        }
        let tokensReady = stillMissing.isEmpty
        if notifications == .off {
            stillMissing.append(.note(WelcomeNotificationText.off(preferences), opens: .notifications))
        }
        if loginItem.needsApproval, let message = loginItem.message {
            stillMissing.append(.note(message, opens: .loginItems))
        }
        // What was fixed since the import doesn't show: a token now stored, the folder chosen (a new report without
        // the item), team values entered. The notification settings show once: while macOS has answered, Still Missing
        // says what is off, or nothing is.
        let didNotMove = (report?.notMoved ?? []).filter { item in
            switch item {
            case .token(let account, _): !storedTokens.contains(account)
            case .notificationSettings: notifications == nil || notifications == .notAsked
            case .teamValues: !teamComplete
            default: true
            }
        }
        return WelcomeSummary(
            heading: tokensReady ? WelcomePage.done.heading : "Almost Ready",
            whereToFind: preferences.showInMenuBar
                ? "Click the MegaMonitor icon in the menu bar to see your builds."
                : "Open MegaMonitor again to see your builds in its window.",
            stillMissing: stillMissing,
            didNotMove: didNotMove.map(\.message),
            eggLine: preferences.easterEggs ? EggRules.welcomeLine : nil)
    }

    /// Returns whether the account check refused a token itself: rejected, or GitLab's without its scope. An
    /// unreachable server says nothing about the token.
    ///
    /// - Parameter status: what the check found for one server
    /// - Returns: `true` when the token can't be used
    static func rejects(_ status: AccountStatus) -> Bool {
        let refusals = [Problem.rejectedToken(.jenkins), .rejectedToken(.gitLab), .missingScope].map(\.message)
        return !status.ok && refusals.contains(status.message)
    }
}

/// The Claude step's rules and words (Task 7.14).
enum WelcomeClaudeRules {
    /// the line on the last page while `claude` isn't installed
    static let installText = "Install Claude Code to use Claude features"
    /// where Claude Code is got
    static let installURL = URL(string: "https://claude.com/product/claude-code")!
    /// the models in the picker: Sonnet, the default, first
    static let models: [ClaudeModel] = [.sonnet, .opus, .haiku]

    /// Returns a time of day as a date today, for a time picker.
    ///
    /// - Parameter minutes: minutes after midnight
    static func date(minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60 % 24, minute: minutes % 60, second: 0, of: .now) ?? .now
    }

    /// Returns the minutes after midnight of a picker's date.
    static func minutes(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

/// The notification lines of pages 4 and 6 (APP-04), in the words of Settings → General.
enum WelcomeNotificationText {
    static let allowed = "Notifications are allowed"

    /// Returns what doesn't show while notifications are off: "Notifications are off for MegaMonitor: banners don't
    /// show", as `NotificationNotice` says it.
    ///
    /// - Parameter preferences: the table of Settings → Notifications
    /// - Returns: the line
    static func off(_ preferences: Preferences) -> String {
        NotificationNotice.of(.off, preferences: preferences)?.text ?? "Notifications are off for MegaMonitor"
    }
}

/// The rules of the Team page (TEAM-03).
enum WelcomeTeamRules {
    /// Returns whether Continue is enabled: the three required values are there and can be saved, as typed. Continue
    /// saves them first (`saveTeamNow()`), so the button is ready as soon as the fields are, without waiting for the
    /// pause of TEAM-01.
    ///
    /// - Parameters:
    ///   - draft: the values the fields show
    ///   - issue: what is wrong with a value as typed, `SettingsStore.teamIssue(for:)`
    /// - Returns: `true` when Continue is enabled
    static func canContinue(draft: TeamValues, issue: (TeamValues.Key) -> String?) -> Bool {
        draft.normalized().missing.isEmpty && TeamValues.Key.allCases.allSatisfy { !$0.isRequired || issue($0) == nil }
    }
}

/// The rules of the Accounts page (ACC-02 to ACC-06).
enum WelcomeAccountRules {
    /// the line under the Jenkins fields while an API token is typed without the user
    static let userMissing = "Enter your Jenkins user to save the API token"

    /// Returns whether a typed Jenkins API token waits for its user: the line shows, and Continue keeps the page, since
    /// Save needs both (`SettingsStore.canSaveJenkinsToken`).
    ///
    /// - Parameters:
    ///   - user: the User field
    ///   - token: the New API token field
    /// - Returns: `true` while the token can't be saved for want of the user
    static func needsJenkinsUser(user: String, token: String) -> Bool {
        user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
