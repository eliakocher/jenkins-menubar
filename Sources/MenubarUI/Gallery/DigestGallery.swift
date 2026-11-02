#if DEBUG
import MenubarCore
import SwiftUI

/// The Digest section in the whole main window (AI-04), from made-up values: no model, no Claude.
struct DigestGalleryView: View {
    let fixtures: Fixtures
    var state: AIAnswerState
    var size = MainWindowGallerySize.standard
    var availability = ClaudeAvailability.found
    var isOffered = true
    /// the morning digest's time in minutes since midnight; `nil` while it is off
    var morningMinutes: Int?
    /// the search field's text
    var query = ""

    var body: some View {
        MainWindowGalleryView(
            model: MainWindowShellModel(
                fixtures.mainWindow().panel, section: .digest, digestSubtitle: DigestPage.subtitle(state: state),
                digestBusy: state.isBusy),
            section: .digest, searchText: query, size: size
        ) {
            DigestContent(
                availability: availability, isOffered: isOffered, state: state, morningMinutes: morningMinutes, searchText: query, write: { _ in },
                send: {}, dismiss: {}, openSettings: {})
        } detail: {
            EmptyView()
        }
    }

    /// the prompt of the digest, as sent
    static var prompt: ClaudePrompt {
        ClaudePrompt(
            useCase: .digest, instructions: "Write a short digest for a developer.",
            text: "My merge requests:\n- !87 Fix the login timeout for SSO users (pipeline passed, 1 open thread)\n")
    }

    /// a digest as Claude writes it: Markdown, a few lines per part
    static func answered(_ f: Fixtures) -> AIAnswerState {
        .answered(
            AIAnswer(
                text: """
                    ## Today

                    - **!87 Fix the login timeout for SSO users** is green; one open thread from Sam waits for your answer.
                    - **2 reviews** are waiting for you: !91 (draft, wait for it) and !95 (small, 12 lines).

                    ## Red builds

                    - `release/2026.48` failed in *Integration Tests*: the same test failed in the last two runs, so it is
                      probably flaky, not your change.

                    ## By slot

                    - **2026.45** (released Monday): nothing open.
                    - **2026.48** (freezes today): #1234 is in progress, #1288 has no merge request yet.
                    """,
                model: ClaudeModel.opus.rawValue, prompt: prompt, answeredAt: f.minutesAgo(25)))
    }
}

extension GalleryCatalog {
    /// The Digest section: the written digest, none yet, while it is written, a failure, and the Claude features off.
    static var digestEntries: [GalleryEntry] {
        let size = MainWindowGallerySize.standard
        return [
            GalleryEntry(screen: "digest", state: "answered", size: size) { f in
                DigestGalleryView(fixtures: f, state: DigestGalleryView.answered(f), morningMinutes: 8 * 60 + 30)
            },
            GalleryEntry(screen: "digest", state: "search", size: size) { f in
                DigestGalleryView(fixtures: f, state: DigestGalleryView.answered(f), morningMinutes: 8 * 60 + 30, query: "review")
            },
            GalleryEntry(screen: "digest", state: "search-none", size: size) { f in
                DigestGalleryView(fixtures: f, state: DigestGalleryView.answered(f), morningMinutes: 8 * 60 + 30, query: "deploy")
            },
            GalleryEntry(screen: "digest", state: "empty", size: size) { f in
                DigestGalleryView(fixtures: f, state: .idle)
            },
            GalleryEntry(screen: "digest", state: "writing", size: size) { f in
                DigestGalleryView(fixtures: f, state: .running(DigestGalleryView.prompt))
            },
            GalleryEntry(screen: "digest", state: "failed", size: size) { f in
                DigestGalleryView(
                    fixtures: f, state: .failed("Claude didn't answer within 2 minutes.", DigestGalleryView.prompt))
            },
            GalleryEntry(screen: "digest", state: "claude-off", size: size) { f in
                DigestGalleryView(fixtures: f, state: .idle, availability: .found, isOffered: false)
            },
            GalleryEntry(screen: "digest", state: "answered-narrow", size: MainWindowGallerySize.minimum) { f in
                DigestGalleryView(
                    fixtures: f, state: DigestGalleryView.answered(f), size: MainWindowGallerySize.minimum)
            },
        ]
    }
}
#endif
