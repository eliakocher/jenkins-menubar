#if DEBUG
import MenubarCore
import SwiftUI

/// Rendered Markdown in every place it shows (WIN-02, AI-01): a long answer of Claude's, a merge request's description
/// with a table and code, and a comment thread, wide and narrow. Made up throughout.
enum MarkdownGallery {
    static let base = URL(string: "https://gitlab.example.com/group/subgroup/project/-/merge_requests/14")

    /// an answer of Claude's to "Why did it fail?": every element Claude writes
    static let claudeAnswer = claudeAnswerStart + "\n\n" + claudeAnswerEnd

    /// the answer up to the fix
    static let claudeAnswerStart = """
        ## What failed

        The build broke in **Integration Tests**: `LoginFlowIT.testSsoTimeout` timed out after *30 s* waiting for the \
        session cookie. It failed in the last **two** runs on `release/2026.48`, and passed on `main`, so this is \
        probably your change, not a flaky test.

        ### Why

        1. The new `SessionStore` refreshes the token on the main queue.
        2. Under load the refresh waits for the UI lock, which the test holds:
           - the test opens the login sheet,
           - the sheet waits for the token,
           - and the token waits for the sheet.
        3. After 30 s the test gives up.

        > The same deadlock shows in the log at 10:14:02, right before the timeout.

        ```swift
        // SessionStore.swift, line 88
        @MainActor
        func refresh() async throws -> Token {
            let token = try await client.token(for: account, timeout: .seconds(30))
            cache["session"] = token // 3 retries before this
            return token
        }
        ```
        """

    /// the answer from the fix on: a diff, a shell command, a table, a callout and a rule
    static let claudeAnswerEnd = """
        ### The fix

        Move the refresh off the main actor and keep only the cache write on it:

        ```diff
        -@MainActor
         func refresh() async throws -> Token {
        -    let token = try await client.token(for: account, timeout: .seconds(30))
        +    let token = try await client.token(for: account, timeout: .seconds(5))
        +    await MainActor.run { cache["session"] = token }
             return token
         }
        ```

        Then run the one test again:

        ```bash
        # from the repository's root
        ./gradlew :web:integrationTest --tests "LoginFlowIT" -Pretries=0 > "$HOME/it.log"
        ```

        | Run | Branch | Result | Duration |
        |----:|:-------|:------:|---------:|
        | 412 | release/2026.48 | Failed | 31 min |
        | 411 | release/2026.48 | Failed | 30 min |
        | 409 | main | Passed | 24 min |

        > [!TIP]
        > The test log has the whole stack: [console](https://jenkins.example.com/job/project/412/console).

        ---

        If it still fails, ask about the `TokenClient` timeouts; see also !87 and #1234.
        """

    /// a merge request's description from a made-up template, with references, mentions, a wide table and code
    static let description = """
        ## Summary

        Moves the badge colors into **one token file** (`ColorTokens`) and reads the light and dark variants from the \
        same entry. Closes #31, follows up on !12; cc @slee and @akim. Also see group/other-project!7.

        ### Changes

        - New `ColorTokens.badge(_:scheme:)`, used by every badge
        - The panel and the main window read the tokens
          1. the list rows first
          2. then the detail headers
             - including the *pinned* items
        - ~~The old `BadgeColors` constants~~ stay as aliases for one release

        ### Checklist

        - [x] Light and dark come from the same token
        - [x] Snapshot tests updated
        - [ ] Release notes
        - [ ] Design review by @cnovak

        ### Measurements

        | State | Light | Dark | Contrast (light) | Contrast (dark) | Where it shows | Notes |
        |:------|:-----:|:----:|-----------------:|----------------:|:---------------|:------|
        | Success | `#108548` | `#52B87A` | 4.9 | 5.2 | List, detail, panel, notifications | unchanged |
        | Failed | `#DD2B0E` | `#EC5941` | 4.6 | 4.8 | List, detail, panel | darker in light mode |
        | Running | `#1F75CB` | `#428FDC` | 4.5 | 5.0 | List and panel only | new |

        ### How to test

        ```
        make tokens && ./test.sh BadgeTests
        open build/gallery/index.html
        ```

        > [!WARNING]
        > The settings window still reads the old constants; keep them until #28 is done.

        ![screenshot](/uploads/7d21e0/badges-dark.png)

        <!-- template hint: describe the change -->
        Design: [color tokens](https://design.example.com/color-tokens)
        """

    /// a review thread and a plain comment with Markdown in them
    static func threads(_ f: Fixtures) -> [CommentThread] {
        let page = "https://gitlab.example.com/group/subgroup/project/-/merge_requests/14#note_"
        func note(_ id: Int, _ username: String, _ name: String, _ minutesAgo: Double, _ body: String) -> ThreadNote {
            ThreadNote(
                id: "gid://gitlab/Note/\(id)", author: .init(username: username, name: name), body: body,
                createdAt: f.now.addingTimeInterval(-minutesAgo * 60), url: URL(string: page + "\(id)"))
        }
        return [
            CommentThread(
                id: "m1",
                first: note(
                    921, "slee", "Sam Lee", 180,
                    """
                    Could this use the shared helper instead? Something like:

                    ```swift
                    let color = ColorTokens.badge(state, scheme: colorScheme)
                    ```

                    @jdoe what do you think? It's the same as in !12.
                    """),
                replies: [
                    note(922, "jdoe", "Jane Doe", 60, "Good point, done in the last commit. `BadgeView` now has no constant left."),
                ], location: "Sources/Badges/BadgeView.swift:42"),
            CommentThread(
                id: "m2",
                first: note(
                    923, "akim", "Alex Kim", 25,
                    """
                    Two things before I approve:

                    1. The **dark** failed color is a bit loud next to the running one.
                    2. Please add a line to the release notes, see #28.

                    > Contrast is fine, I checked both modes.
                    """)),
            // A mention in a reply: the thread opens unfolded, and the reply has the bar and the badge.
            CommentThread(
                id: "m3",
                first: note(924, "akim", "Alex Kim", 300, "The migration drops the old column in the same step. Is that safe for the rollback?"),
                replies: [
                    note(925, "slee", "Sam Lee", 240, "It is, the column is empty since 2026.45."),
                    note(926, "slee", "Sam Lee", 20, "@jdoe you wrote the rollback script, can you confirm? `scripts/rollback.sh @jdoe` is not it."),
                ]),
        ]
    }

    /// the cards as the details show them, in the window's background
    struct Page: View {
        let fixtures: Fixtures
        let kind: Kind
        let size: CGSize

        enum Kind {
            case claude, claudeEnd, description, comments
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch kind {
                    case .claude:
                        DetailCard("Why Did It Fail", symbol: "sparkles", width: .fullWidth) {
                            MarkdownView(markdown: MarkdownGallery.claudeAnswer, base: nil)
                        }
                    case .claudeEnd:
                        DetailCard("Why Did It Fail", symbol: "sparkles", width: .fullWidth) {
                            MarkdownView(markdown: MarkdownGallery.claudeAnswerEnd, base: nil)
                        }
                    case .description:
                        DetailCard("Description", symbol: "text.alignleft", width: .fullWidth) {
                            CollapsibleMarkdown(
                                document: MarkdownDocument.rendered(MarkdownGallery.description, base: MarkdownGallery.base),
                                startsExpanded: true)
                        } accessory: {
                            MarkdownSizeButtons()
                        }
                    case .comments:
                        DetailCard("Discussion", symbol: "bubble.left.and.bubble.right", width: .fullWidth) {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(MarkdownGallery.threads(fixtures)) { thread in
                                    CommentThreadView(
                                        thread: thread, base: MarkdownGallery.base, now: fixtures.now,
                                        expanded: .constant(["replies:m1"]), me: "jdoe", open: { _ in })
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(.windowBackground)
            .frame(width: size.width, height: size.height)
        }
    }
}

extension GalleryCatalog {
    @MainActor
    static var markdownEntries: [GalleryEntry] {
        [
            GalleryEntry(screen: "markdown", state: "claude-answer", size: CGSize(width: 860, height: 1100)) { f in
                MarkdownGallery.Page(fixtures: f, kind: .claude, size: CGSize(width: 860, height: 1100))
            },
            GalleryEntry(screen: "markdown", state: "claude-answer-narrow", size: CGSize(width: 420, height: 1100)) { f in
                MarkdownGallery.Page(fixtures: f, kind: .claude, size: CGSize(width: 420, height: 1100))
            },
            GalleryEntry(screen: "markdown", state: "claude-answer-end", size: CGSize(width: 860, height: 1000)) { f in
                MarkdownGallery.Page(fixtures: f, kind: .claudeEnd, size: CGSize(width: 860, height: 1000))
            },
            GalleryEntry(screen: "markdown", state: "claude-answer-end-narrow", size: CGSize(width: 420, height: 1100)) { f in
                MarkdownGallery.Page(fixtures: f, kind: .claudeEnd, size: CGSize(width: 420, height: 1100))
            },
            GalleryEntry(screen: "markdown", state: "description", size: CGSize(width: 980, height: 1100)) { f in
                MarkdownGallery.Page(fixtures: f, kind: .description, size: CGSize(width: 980, height: 1100))
            },
            GalleryEntry(screen: "markdown", state: "description-narrow", size: CGSize(width: 440, height: 1100)) { f in
                MarkdownGallery.Page(fixtures: f, kind: .description, size: CGSize(width: 440, height: 1100))
            },
            GalleryEntry(screen: "markdown", state: "comments", size: CGSize(width: 700, height: 840)) { f in
                MarkdownGallery.Page(fixtures: f, kind: .comments, size: CGSize(width: 700, height: 840))
            },
        ]
    }
}
#endif
