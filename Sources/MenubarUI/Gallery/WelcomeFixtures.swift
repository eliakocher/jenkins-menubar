#if DEBUG
import Foundation
import MenubarCore

/// The welcome flow's fixtures: the import reports and the page data of `docs/design/welcome.md`'s states, with the
/// team values of `team.example.json` and the user `jdoe`.
extension Fixtures {
    /// A full import: both tokens, the settings, the team values, 2 watched builds and 1 hidden build.
    var welcomeFullImport: LegacyImportReport {
        LegacyImportReport(
            date: now, oldFolder: URL(filePath: "/Users/jdoe/src/jenkins-menubar", directoryHint: .isDirectory),
            foundBy: .swiftBarPlugin, oldToolFound: true,
            tokens: [
                TokenImport(account: .jenkins, outcome: .imported(.zshrc)),
                TokenImport(account: .gitlab, outcome: .imported(.oldKeychain)),
            ],
            importedSettings: true, importedTeam: true, watchedJobs: 2, hiddenBuilds: 1,
            notMoved: [.notificationSettings, .keychainAccess, .windowPositions, .labelMemoryAndCaches])
    }

    /// The GitLab token from the old keychain item; the old folder wasn't found.
    var welcomeFolderNotFound: LegacyImportReport {
        LegacyImportReport(
            date: now, oldToolFound: true,
            tokens: [
                TokenImport(account: .jenkins, outcome: .notFound(.missing)),
                TokenImport(account: .gitlab, outcome: .imported(.oldKeychain)),
            ],
            notMoved: [
                .notificationSettings, .keychainAccess, .windowPositions, .labelMemoryAndCaches, .oldFolder,
                .token(.jenkins, .notFound(.missing)),
            ])
    }

    /// No trace of the old tool.
    var welcomeFresh: LegacyImportReport {
        LegacyImportReport(
            date: now,
            tokens: [
                TokenImport(account: .jenkins, outcome: .notFound(.missing)),
                TokenImport(account: .gitlab, outcome: .notFound(.missing)),
            ])
    }

    /// Page 1 after an import; `wrongFolder` after Choose Folder… with a folder that isn't the old tool's.
    func welcomePage(_ report: LegacyImportReport, wrongFolder: Bool = false) -> WelcomeData {
        WelcomeData(page: .welcome, importSummary: WelcomeImportSummary.make(report), wrongFolder: wrongFolder)
    }

    /// Page 2 with its TEAM-03 row, issues and the file result; the row is a problem once people tried to move on.
    func welcomeTeam(
        saved: TeamValues, draft: TeamValues, issues: [TeamValues.Key: String] = [:], importedFromOldTool: Bool = false,
        fileResult: WelcomeLine? = nil, triedToMoveOn: Bool = false
    ) -> WelcomeData {
        let row = saved.missing.isEmpty ? [] : [Problem.teamValuesMissing.message]
        return WelcomeData(
            page: .team,
            team: WelcomeData.Team(
                notes: triedToMoveOn ? [] : row, problems: triedToMoveOn ? row : [], issues: issues,
                importedFromOldTool: importedFromOldTool, fileResult: fileResult,
                canContinue: WelcomeTeamRules.canContinue(draft: draft) { issues[$0] }))
    }

    /// Page 3 with the tokens' sources, the lines under them and the account check's results.
    func welcomeAccounts(
        sources: [TokenAccount: TokenSource], errors: [TokenAccount: String] = [:],
        results: [TokenAccount: AccountStatus] = [:], isChecking: Bool = false
    ) -> WelcomeData {
        let links = Dictionary(uniqueKeysWithValues: TokenAccount.allCases.compactMap { account in
            TokenLink.create(account, team: team).map { (account, $0) }
        })
        return WelcomeData(
            page: .accounts,
            accounts: WelcomeData.Accounts(
                sources: sources, links: links, errors: errors, isChecking: isChecking, results: results))
    }

    /// Page 6 for the state the flow reached.
    func welcomeDone(
        report: LegacyImportReport?, storedTokens: Set<TokenAccount>, accounts: [TokenAccount: AccountStatus] = [:],
        notifications: NotificationPermission?, loginItem: LoginItemStatus = .enabled, showInMenuBar: Bool = true
    ) -> WelcomeData {
        var preferences = Preferences()
        preferences.showInMenuBar = showInMenuBar
        return WelcomeData(
            page: .done, notifications: notifications, preferences: preferences,
            login: WelcomeData.Login(status: loginItem),
            summary: WelcomeSummary.make(
                report: report, storedTokens: storedTokens, accounts: accounts, notifications: notifications,
                loginItem: loginItem, preferences: preferences, teamComplete: true))
    }
}
#endif
