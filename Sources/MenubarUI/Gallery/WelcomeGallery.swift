#if DEBUG
import MenubarCore
import SwiftUI

/// The welcome flow's content as the gallery shows it: one page with fixed values; the buttons do nothing.
struct WelcomeGalleryView: View {
    let data: WelcomeData
    var input = WelcomeInput()

    var body: some View {
        WelcomeContent(data: data, input: .constant(input))
    }
}

extension GalleryCatalog {
    /// One entry per state of `docs/design/welcome.md`: the whole content with its bottom bar, 600 × 560 pt.
    static var welcomeEntries: [GalleryEntry] {
        let size = WelcomeContent.size
        return [
            // Page 1
            GalleryEntry(screen: "welcome", state: "welcome-imported", size: size) { fixtures in
                WelcomeGalleryView(data: fixtures.welcomePage(fixtures.welcomeFullImport))
            },
            GalleryEntry(screen: "welcome", state: "welcome-folder-not-found", size: size) { fixtures in
                WelcomeGalleryView(data: fixtures.welcomePage(fixtures.welcomeFolderNotFound))
            },
            // Not in the spec: WELCOME-09's line after a wrong folder.
            GalleryEntry(screen: "welcome", state: "welcome-wrong-folder", size: size) { fixtures in
                WelcomeGalleryView(data: fixtures.welcomePage(fixtures.welcomeFolderNotFound, wrongFolder: true))
            },
            GalleryEntry(screen: "welcome", state: "welcome-fresh", size: size) { fixtures in
                WelcomeGalleryView(data: fixtures.welcomePage(fixtures.welcomeFresh))
            },
            // Page 2
            GalleryEntry(screen: "welcome", state: "team-empty", size: size) { fixtures in
                WelcomeGalleryView(data: fixtures.welcomeTeam(saved: TeamValues(), draft: TeamValues()))
            },
            GalleryEntry(screen: "welcome", state: "team-imported", size: size) { fixtures in
                WelcomeGalleryView(
                    data: fixtures.welcomeTeam(saved: fixtures.team, draft: fixtures.team, importedFromOldTool: true),
                    input: WelcomeInput(team: fixtures.team))
            },
            GalleryEntry(screen: "welcome", state: "team-invalid", size: size) { fixtures in
                let draft = TeamValues(
                    jenkinsJobURL: "jenkins.example.com/job/project", gitLabURL: "https://gitlab.example.com",
                    gitLabProject: "group/subgroup/project")
                var saved = draft
                saved.jenkinsJobURL = ""
                // After Return: the issue shows, and the TEAM-03 row turned into a problem.
                return WelcomeGalleryView(
                    data: fixtures.welcomeTeam(
                        saved: saved, draft: draft,
                        issues: [.jenkinsJobURL: "Enter a URL that starts with https:// or http://"],
                        triedToMoveOn: true),
                    input: WelcomeInput(team: draft))
            },
            GalleryEntry(screen: "welcome", state: "team-import-error", size: size) { fixtures in
                WelcomeGalleryView(data: fixtures.welcomeTeam(
                    saved: TeamValues(), draft: TeamValues(), fileResult: .problem(TeamFileError.notATeamFile.message)))
            },
            // Page 3
            GalleryEntry(screen: "welcome", state: "accounts-empty", size: size) { fixtures in
                WelcomeGalleryView(data: fixtures.welcomeAccounts(sources: [.jenkins: .missing(nil), .gitlab: .missing(nil)]))
            },
            // Not in the spec: WELCOME-03's line for an API token typed without the user.
            GalleryEntry(screen: "welcome", state: "accounts-no-user", size: size) { fixtures in
                WelcomeGalleryView(
                    data: fixtures.welcomeAccounts(
                        sources: [.jenkins: .missing(nil), .gitlab: .missing(nil)],
                        errors: [.jenkins: WelcomeAccountRules.userMissing]),
                    input: WelcomeInput(jenkinsToken: "11a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7"))
            },
            GalleryEntry(screen: "welcome", state: "accounts-imported", size: size) { fixtures in
                WelcomeGalleryView(
                    data: fixtures.welcomeAccounts(
                        sources: [.jenkins: .keychain(importedFrom: .zshrc), .gitlab: .keychain(importedFrom: .oldKeychain)],
                        results: [.jenkins: .signedIn(as: fixtures.me), .gitlab: .signedIn(as: fixtures.me)]),
                    input: WelcomeInput(jenkinsUser: fixtures.me))
            },
            GalleryEntry(screen: "welcome", state: "accounts-problems", size: size) { fixtures in
                WelcomeGalleryView(
                    data: fixtures.welcomeAccounts(
                        sources: [.jenkins: .keychain(importedFrom: nil), .gitlab: .keychain(importedFrom: nil)],
                        results: [
                            .jenkins: AccountStatus(ok: false, message: Problem.rejectedToken(.jenkins).message),
                            .gitlab: AccountStatus(ok: false, message: Problem.unreachable(.gitLab).message),
                        ]),
                    input: WelcomeInput(jenkinsUser: fixtures.me))
            },
            // Page 4
            GalleryEntry(screen: "welcome", state: "notifications-ask", size: size) { _ in
                WelcomeGalleryView(data: WelcomeData(page: .notifications, notifications: .notAsked))
            },
            GalleryEntry(screen: "welcome", state: "notifications-off", size: size) { _ in
                WelcomeGalleryView(data: WelcomeData(page: .notifications, notifications: .off))
            },
            // Page 5
            GalleryEntry(screen: "welcome", state: "menu-bar-and-login", size: size) { _ in
                WelcomeGalleryView(data: WelcomeData(page: .menuBarAndLogin))
            },
            GalleryEntry(screen: "welcome", state: "login-approval", size: size) { _ in
                WelcomeGalleryView(data: WelcomeData(page: .menuBarAndLogin, login: WelcomeData.Login(status: .requiresApproval)))
            },
            // Page 6
            GalleryEntry(screen: "welcome", state: "done", size: size) { fixtures in
                WelcomeGalleryView(data: fixtures.welcomeDone(
                    report: fixtures.welcomeFresh, storedTokens: [.jenkins, .gitlab], notifications: .allowed))
            },
            GalleryEntry(screen: "welcome", state: "done-old-tool", size: size) { fixtures in
                WelcomeGalleryView(data: fixtures.welcomeDone(
                    report: fixtures.welcomeFullImport, storedTokens: [.jenkins, .gitlab], notifications: .notAsked))
            },
            // With a rejected GitLab token and a login item waiting for approval too (WELCOME-06, WELCOME-11).
            GalleryEntry(screen: "welcome", state: "done-missing", size: size) { fixtures in
                WelcomeGalleryView(data: fixtures.welcomeDone(
                    report: fixtures.welcomeFresh, storedTokens: [.gitlab],
                    accounts: [.gitlab: AccountStatus(ok: false, message: Problem.rejectedToken(.gitLab).message)],
                    notifications: .off, loginItem: .requiresApproval, showInMenuBar: false))
            },
        ]
    }
}
#endif
