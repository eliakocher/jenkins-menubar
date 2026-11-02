import Foundation
import MenubarCore
import SwiftUI
import Testing

@testable import MenubarUI

@Suite("Main window")
@MainActor
struct MainWindowTests {
    @Test(
        "WIN-02 showing a section marks it visible",
        arguments: [
            (MainWindowSection.pipelines, Set<Surface>()),
            (.mergeRequests, [.mergeRequests]),
            (.workItems, [.workItems]),
            (.activity, []),
        ] as [(MainWindowSection, Set<Surface>)])
    func showingMarksVisible(section: MainWindowSection, surfaces: Set<Surface>) {
        // Covered or minimized, the window still shows its selected section.
        #expect(MainWindowSurfaces.shown(section: section, isOnScreen: false) == surfaces)

        let router = WindowRouter { _ in }
        #expect(router.surfaces(surfaces, shownBy: MainWindowSurfaces.host) == surfaces)
        // Closing the window leaves what the panel shows.
        _ = router.surfaces(PanelView.surfaces, shownBy: PanelView.host)
        #expect(router.surfaces([], shownBy: MainWindowSurfaces.host) == PanelView.surfaces)
    }

    @Test(
        "WIN-04 reload loads only the shown section, and the selected row's detail only with a selection",
        arguments: [
            (MainWindowSection.pipelines, false, [MainWindowReload.Step.builds]),
            (.mergeRequests, false, [.mergeRequestList]),
            (.mergeRequests, true, [.mergeRequestList, .mergeRequestDetails]),
            (.workItems, false, [.workItemList]),
            (.workItems, true, [.workItemList, .workItemDetails]),
            (.slots, false, [.slots]),
            (.slots, true, [.slots, .slotItemDetails]),
            (.workspaces, true, [.workspaces]),
            (.digest, false, []),
            (.activity, true, []),
        ] as [(MainWindowSection, Bool, [MainWindowReload.Step])])
    func reloadsTheShownSection(section: MainWindowSection, selected: Bool, steps: [MainWindowReload.Step]) {
        let selection = selected
            ? MainWindowSelection(
                pipelines: "job", mergeRequests: URL(string: "https://gitlab.example/mr/1"), workItems: "item", slots: "item")
            : MainWindowSelection()
        #expect(MainWindowReload.steps(for: section, selection: selection) == steps)
    }

    @Test(
        "WIN-04 Reload is disabled in Activity and in Digest, whose page has its own Write Again; every other section has it",
        arguments: [
            (MainWindowSection.activity, false, false),
            // A stray ⌘R must not send the person's data to Claude.
            (.digest, false, false),
            (.pipelines, false, true),
            (.workspaces, false, true),
            // An opened item reloads in every section.
            (.activity, true, true),
            (.digest, true, true),
        ] as [(MainWindowSection, Bool, Bool)])
    func reloadAvailability(section: MainWindowSection, opened: Bool, expected: Bool) {
        #expect(MainWindowReload.isAvailable(in: section, opened: opened) == expected)
    }

    @Test(
        "AI-04 the search marks the digest's words in its text and says how many, or that there are none",
        arguments: [
            ("", 0, nil),
            ("   ", 0, nil),
            ("login", 1, "1 match"),
            ("LOGIN", 1, "1 match"),
            ("review", 2, "2 matches"),
            ("flaky test", 3, "3 matches"),
            ("zzz", 0, "No matches for “zzz”"),
        ] as [(String, Int, String?)])
    func searchesTheDigest(query: String, matches: Int, note: String?) {
        let digest = MarkdownDocument(
            parsing: """
                ## Today

                - **!87 Fix the login timeout** is green.
                - 1 review waits; the other review is a draft.

                | Build | Result |
                | --- | --- |
                | `release` | flaky |

                > a flaky test again
                """, base: nil)
        let found = digest.highlighting(query)
        #expect(found.matches == matches)
        #expect(DigestPage.searchNote(query: query, matches: found.matches) == note)
        // The blocks stay as they were; only the text is marked.
        #expect(found.document.blocks.count == digest.blocks.count)

        // Only the matching words are marked, whatever their case, and the text itself stays.
        guard query == "login" else { return }
        let paragraph = MarkdownDocument(parsing: "The Login timeout, a login and a LOGIN.", base: nil)
        guard case .paragraph(let text)? = paragraph.highlighting(query).document.blocks.first else {
            Issue.record("a paragraph")
            return
        }
        let marked = text.runs.filter { $0.swiftUI.backgroundColor != nil }.map { String(text[$0.range].characters) }
        #expect(marked == ["Login", "login", "LOGIN"])
        #expect(String(text.characters) == "The Login timeout, a login and a LOGIN.")
        // Without a search nothing is marked.
        guard case .paragraph(let plain)? = paragraph.highlighting("  ").document.blocks.first else {
            Issue.record("a paragraph")
            return
        }
        #expect(plain.runs.allSatisfy { $0.swiftUI.backgroundColor == nil })
    }

    @Test("WIN-01 Digest is listed last, only while the Claude features are on, and stays listed while it is shown")
    func listsDigestWithClaude() {
        let all = MainWindowSection.allCases
        #expect(all.last == .digest)
        #expect(MainWindowSection.sidebarSections(claudeIsOffered: true, shown: .pipelines) == all)
        #expect(!MainWindowSection.sidebarSections(claudeIsOffered: false, shown: .slots).contains(.digest))
        #expect(MainWindowSection.sidebarSections(claudeIsOffered: false, shown: .slots) == all.filter { $0 != .digest })
        // A link or a restart can land on Digest while `claude` is still looked for: the selection keeps its row.
        #expect(MainWindowSection.sidebarSections(claudeIsOffered: false, shown: .digest) == all)
    }

    @Test(
        "AI-04 the digest is written only while Claude is on and nothing runs or waits for Send",
        arguments: [
            (AIAnswerState.idle, true, true),
            (.answered(AIAnswer(text: "t", model: "m", prompt: DigestPageTests.prompt, answeredAt: Date())), true, true),
            (.failed("no", nil), true, true),
            (.preparing, true, false),
            (.running(DigestPageTests.prompt), true, false),
            (.review(DigestPageTests.prompt), true, false),
            (.idle, false, false),
        ] as [(AIAnswerState, Bool, Bool)])
    func writesTheDigest(state: AIAnswerState, isOffered: Bool, expected: Bool) {
        #expect(DigestPage.canWrite(state: state, isOffered: isOffered) == expected)
    }

    @Test("OD-02 the panel and the window on screen keep MRs and work items loading; the scheduler gets the union")
    func keepsGitLabLoading() {
        // The panel's summary rows and the sidebar's badges show GitLab counts.
        #expect(PanelView.surfaces == [.mergeRequests, .workItems])
        for section in MainWindowSection.allCases {
            #expect(MainWindowSurfaces.shown(section: section, isOnScreen: true) == [.mergeRequests, .workItems])
        }

        let router = WindowRouter { _ in }
        #expect(router.surfaces(PanelView.surfaces, shownBy: PanelView.host) == [.mergeRequests, .workItems])
        // Another host's surfaces stay while the panel closes.
        #expect(router.surfaces([.workItems], shownBy: "window") == [.mergeRequests, .workItems])
        #expect(router.surfaces([], shownBy: PanelView.host) == [.workItems])
        #expect(router.surfaces([], shownBy: "window") == [])
    }

    @Test("WIN-05 restores the section and the selection")
    func restoresSectionAndSelection() throws {
        let suite = "menubar-monitor-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mergeRequest = try #require(URL(string: "https://gitlab.example.com/group/project/-/merge_requests/14"))

        let first = WindowRouter(defaults: defaults) { _ in }
        #expect(first.section == .pipelines)
        first.selection.pipelines = "MR-12"
        first.showInMergeRequests(mergeRequest)
        first.selection.workItems = "group/project#31"
        first.selection.slots = "group/project#44"
        first.selection.activity = ["1-0"]

        let second = WindowRouter(defaults: defaults) { _ in }
        #expect(second.section == .mergeRequests)
        #expect(second.selection == MainWindowSelection(
            pipelines: "MR-12", mergeRequests: mergeRequest, workItems: "group/project#31", activity: ["1-0"],
            slots: "group/project#44"))

        // Activity's is kept only while one entry is selected; a cleared selection is gone after a restart too.
        second.selection.activity = ["1-0", "2-0"]
        second.selection.pipelines = nil
        second.open(.activity)
        let third = WindowRouter(defaults: defaults) { _ in }
        #expect(third.section == .activity)
        #expect(third.selection.activity.isEmpty)
        #expect(third.selection.pipelines == nil)
        #expect(third.selection.workItems == "group/project#31")
    }
}

/// shared values of the digest's tests
private enum DigestPageTests {
    static let prompt = ClaudePrompt(useCase: .digest, instructions: "i", text: "t")
}
