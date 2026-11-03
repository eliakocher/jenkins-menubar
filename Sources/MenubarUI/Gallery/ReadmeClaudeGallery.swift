#if DEBUG
import MenubarCore
import SwiftUI

/// The README's shots of the Claude features and of a comment that mentions you. Claude's cards are drawn here from
/// canned answers: nothing runs `claude`, and the app's own cards (which need the running store) are not used. The
/// pieces are the app's own views: the question bubble, the answer rows with Markdown, the build explanation card,
/// the Changes card with its picked lines, the comment threads.
extension GalleryCatalog {
    static var readmeClaudeEntries: [GalleryEntry] {
        let tall = CGSize(width: 1400, height: 1330)
        let window = CGSize(width: 1400, height: 900)
        return [
            // Lines picked in the diff, and Claude's answer about them.
            GalleryEntry(screen: "readme", state: "ask-claude", size: tall) { f in
                // The diff inline, from a defaults suite of its own, so the user's choice doesn't leak in.
                let defaults = UserDefaults(suiteName: "gallery.readme.ask-claude") ?? .standard
                defaults.set(DiffLayoutChoice.inline.rawValue, forKey: "mergeRequestDiffLayout")
                return ReadmeMergeRequestWindow(fixtures: f, size: tall) { m in
                    let code = ReadmeCode.shared
                    ReadmeClaudeCard(
                        question: ReadmeCode.question, scope: .lines(code.selection, code.span), answer: ReadmeCode.answer,
                        placeholder: "Ask about this MR…", useCase: .askAboutCode)
                    ChangesCard(mergeRequest: m.mr16, changesURL: m.mr16.webURL.appending(path: "diffs"), actions: .none)
                        .environment(
                            \.mergeRequestDetailsFixtures,
                            MergeRequestDetailsFixtures(
                                states: [:], writeAccess: .allowed,
                                changes: [m.mr16.reference: .loaded(code.changes)], selection: code.selection))
                        .environment(\.askClaudeAboutCode, AskClaudeAboutCodeAction { _ in })
                        .defaultAppStorage(defaults)
                }
            },
            // A comment that mentions you stands out: an accent bar and the "@you" badge.
            GalleryEntry(screen: "readme", state: "discussion", size: CGSize(width: 1400, height: 720)) { f in
                ReadmeMergeRequestWindow(fixtures: f, size: CGSize(width: 1400, height: 720)) { m in
                    ReadmeDiscussionCard(mergeRequest: m.mr16)
                }
            },
            // Claude's analysis of a failed build.
            GalleryEntry(screen: "readme", state: "why-failed", size: window) { f in
                ReadmeBuildWindow(fixtures: f, size: window)
            },
        ]
    }
}

// MARK: - The merge request's window

/// The main window at Merge Requests with !16 selected: the real list, and a detail made of a header and the cards given.
private struct ReadmeMergeRequestWindow<Cards: View>: View {
    let fixtures: Fixtures
    let size: CGSize
    @ViewBuilder let cards: (MergeRequestsFixtures) -> Cards

    var body: some View {
        let m = fixtures.mergeRequestsScreen
        let panel = m.panel(m.sections + [m.mr16])
        let data = MergeRequestsData(panel)
        let model = MergeRequestDetailModel(data, selection: m.mr16.id)
        MainWindowGalleryView(
            model: MainWindowShellModel(panel, section: .mergeRequests), section: .mergeRequests, size: size
        ) {
            MergeRequestsListContent(
                model: MergeRequestsListModel(data, query: ""), selection: .constant(m.mr16.id), actions: .none)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let model {
                        header(model)
                    }
                    cards(m)
                }
                .pageContentWidth()
            }
        }
    }

    private func header(_ model: MergeRequestDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                StatusBadge(text: model.status.text, symbol: model.status.symbol, tint: model.status.color.swiftUI)
                ReferenceChip(kind: .mergeRequest, text: "!\(String(model.mergeRequest.iid))", help: model.mergeRequest.reference)
                    .fixedSize()
                Text(verbatim: model.projectName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: model.mergeRequest.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                InitialsAvatar(name: model.mergeRequest.author.name, username: model.mergeRequest.author.username, size: 18)
                Text(verbatim: "\(model.author) · updated \(model.updated)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - The Claude card

/// The Claude card with a first question answered and the field for the next, as the merge request's chat shows it.
private struct ReadmeClaudeCard: View {
    let question: String
    var scope: CodeScope?
    let answer: String
    let placeholder: String
    let useCase: AIUseCase

    var body: some View {
        let result = AIAnswer(
            text: answer, model: "claude-opus-5-5",
            prompt: ClaudePrompt(useCase: useCase, instructions: "", text: "The title, the description and the diff."),
            answeredAt: .now)
        DetailCard("Claude", symbol: "sparkles", width: .fullWidth) {
            VStack(alignment: .leading, spacing: 10) {
                QuestionBubble(question: question, scope: scope)
                AIAnswerRows(state: .answered(result), send: {}, dismiss: {}) { answer in
                    MarkdownView(markdown: answer.text ?? "", base: nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ClaudeComposer(placeholder: placeholder, isThinking: false, send: { _, _ in }, stop: { nil })
            }
        }
    }
}

/// The lines, the question and the answer of the "Ask Claude" shot: a retry loop, made up.
private struct ReadmeCode {
    static let shared = ReadmeCode()

    static let question = "Does this retry also retry errors that can never succeed, and what happens if the task is cancelled?"

    static let answer = """
        Yes to the first, and the second works only by accident.

        - **Every error is retried.** `catch where attempt < attempts` also catches a 4xx from the uploader or a decoding \
        error, so a permanent failure costs three attempts and four seconds before it surfaces.
        - **Cancellation.** A `CancellationError` thrown by `body` is caught like any other; the loop then calls \
        `Task.sleep`, which throws again, and only that ends it. It is one iteration late and would run `body` again if the \
        sleep were removed.
        - **A fixed delay.** Two seconds each time is fine for a dropped connection and unkind to a server that is overloaded.

        A safer shape retries only what can recover, and waits longer each time:

        ```swift
        } catch let error where attempt < attempts && RetryPolicy.isTransient(error) {
            attempt += 1
            try await Task.sleep(for: delay * attempt)
        }
        ```

        `isTransient` is a small helper: `true` for `URLError`s like `.timedOut` and `.networkConnectionLost`, `false` for the rest.
        """

    let changes: MergeRequestChanges
    let selection: DiffSelection
    let span: LineSpan

    init() {
        let policy = """
            @@ -0,0 +1,19 @@
            +/// How often and how long an export retries when the connection drops.
            +struct RetryPolicy: Sendable {
            +    var attempts: Int
            +    var delay: Duration
            +
            +    static let standard = RetryPolicy(attempts: 3, delay: .seconds(2))
            +
            +    func run<T>(_ body: () async throws -> T) async throws -> T {
            +        var attempt = 1
            +        while true {
            +            do {
            +                return try await body()
            +            } catch where attempt < attempts {
            +                attempt += 1
            +                try await Task.sleep(for: delay)
            +            }
            +        }
            +    }
            +}

            """
        func file(_ path: String, _ kind: MergeRequestChanges.FileChange.Kind, diff: String) -> MergeRequestChanges.FileChange {
            MergeRequestChanges.FileChange(
                oldPath: path, newPath: path, kind: kind, isGenerated: false, content: UnifiedDiff.parse(diff))
        }
        let policyFile = file("Sources/Export/RetryPolicy.swift", .added, diff: policy)
        changes = MergeRequestChanges(files: [policyFile])
        let picked = DiffSelection(
            path: policyFile.newPath, anchor: DiffLineID(old: nil, new: 9), head: DiffLineID(old: nil, new: 17))
        selection = picked
        let hunks: [DiffHunk]
        if case .hunks(let found) = policyFile.content {
            hunks = found
        } else {
            hunks = []
        }
        span = picked.span(in: hunks) ?? LineSpan(first: 9, last: 17, isOld: false)
    }
}

// MARK: - The discussion

/// The Discussion card with threads, two of which mention the signed-in user (`jdoe`).
private struct ReadmeDiscussionCard: View {
    let mergeRequest: MergeRequest

    private var threads: [CommentThread] {
        let person = { (username: String, name: String) in MergeRequest.Person(username: username, name: name) }
        let sam = person("slee", "Sam Lee")
        let alex = person("akim", "Alex Kim")
        let robin = person("rmeyer", "Robin Meyer")
        let me = person("jdoe", "Jane Doe")
        func note(_ id: Int, _ who: MergeRequest.Person, _ minutesAgo: Double, _ text: String) -> ThreadNote {
            ThreadNote(
                id: "gid://gitlab/DiffNote/\(id)", author: who, body: text, createdAt: Date.now.addingTimeInterval(-minutesAgo * 60),
                url: URL(string: "https://gitlab.example.com/group/subgroup/project/-/merge_requests/16#note_\(id)"))
        }
        let threads = [
            CommentThread(
                id: "t1", first: note(1, sam, 95, "@jdoe the retry belongs next to the **timeout**, see `RetryPolicy`. Could the caller pass the number of attempts in?"),
                replies: [
                    note(2, me, 70, "Yes, I'll add `attempts` to the job's result."),
                    note(3, sam, 40, "Thanks, then @jdoe can drop the constant below."),
                ], location: "Sources/Export/ExportJob.swift:42"),
            CommentThread(
                id: "t2", first: note(4, alex, 130, "This swallows the error. Please log it, or the next person will search for an hour."),
                replies: [note(5, robin, 30, "Logged now, with the job's id.")], location: "Sources/Export/ExportJob.swift:77"),
            CommentThread(
                id: "t3", first: note(6, robin, 20, "Missing a test for the case where the second attempt fails as well."),
                location: "Tests/ExportTests/RetryTests.swift:120"),
        ]
        return threads
    }

    var body: some View {
        DetailCard("Discussion", symbol: "bubble.left.and.bubble.right", width: .fullWidth) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(threads) { thread in
                    CommentThreadView(thread: thread, base: mergeRequest.webURL, me: "jdoe") { _ in }
                }
            }
        } accessory: {
            CountBadge(text: "3 open", tint: MergeRequestStatus.Color.orange.swiftUI)
        }
    }
}

// MARK: - Why did it fail

/// The main window at Pipelines with the failed build, and Claude's analysis in its detail.
private struct ReadmeBuildWindow: View {
    let fixtures: Fixtures
    let size: CGSize

    var body: some View {
        let data = fixtures.readmePipelines
        let result = AIAnswer(
            explanation: Self.explanation, model: "claude-opus-5-5",
            prompt: ClaudePrompt(useCase: .explainBuild, instructions: "", text: "The failed tests, the log and the commits."),
            answeredAt: .now)
        MainWindowGalleryView(
            model: MainWindowShellModel(data.panel, section: .pipelines), section: .pipelines, size: size
        ) {
            PipelinesListContent(model: PipelinesListModel(data, query: ""), selection: .constant("MR-16"), actions: .none)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    DetailCard("Claude", symbol: "sparkles", width: .fullWidth) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                ClaudeActionButton(
                                    title: "Why Did It Fail?", systemImage: "sparkles", prominent: true, help: "Ask Claude why it failed"
                                ) { _ in }
                                Spacer(minLength: 0)
                            }
                            .controlSize(.small)
                            AIAnswerRows(state: .answered(result), send: {}, dismiss: {}) { answer in
                                if let explanation = answer.explanation {
                                    BuildExplanationCard(explanation: explanation)
                                }
                            }
                        }
                    }
                }
                .pageContentWidth()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusBadge(text: "Failed", symbol: "xmark.circle.fill", tint: .red)
                ReferenceChip(kind: .mergeRequest, text: "!16", help: "group/subgroup/project!16")
                    .fixedSize()
                Text(verbatim: "#3")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: "Add a retry to the export job")
                .font(.title2.weight(.semibold))
            PillFlowLayout(spacing: 6, lineSpacing: 6) {
                DetailChip(symbol: "timer", text: "12m")
                DetailChip(symbol: "clock", text: "Finished 30m ago")
                DetailChip(symbol: "xmark.circle.fill", tint: .red, text: "3 failed tests")
            }
        }
    }

    static let explanation = BuildExplanation(
        headline: "A new test fails because the retry never gives up in time",
        verdict: .real, failedAt: "Stage tests, ExportRetryTest",
        cause: "The export job now retries the upload three times with a two second delay, but ExportRetryTest runs against "
            + "a stub that never answers, so the first call alone waits for the whole 20 second timeout. Three attempts "
            + "take a minute, and the test's own limit is 30 seconds. givesUpAfterTheLastRetry fails the same way: it "
            + "expects the exception after the last attempt and times out before that.",
        evidence: [
            "ExportRetryTest.retriesAfterATimeout: expected: <3> but was: <1>",
            "ExportRetryTest.givesUpAfterTheLastRetry: Test timed out after 30 seconds",
            "[ERROR] Failed to execute goal on project export: There are test failures.",
        ],
        suspects: [
            BuildExplanation.Suspect(
                commit: "b71e04c9a3", author: "Jane Doe", message: "Retry the export when the connection drops",
                why: "adds the retry loop and raises the timeout to 20 seconds in the same change")
        ],
        nextStep: "Give the stub in ExportRetryTest a short answer time, or let the test pass a RetryPolicy with one attempt "
            + "and no delay. Then rebuild.")
}
#endif
