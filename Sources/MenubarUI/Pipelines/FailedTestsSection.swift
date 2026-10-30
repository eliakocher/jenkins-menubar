import MenubarCore
import SwiftUI

/// The build detail's Failed Tests card (PIPE-03): each failed test as its class and method with the start of its
/// error message, cut after 10 tests with "Show All (N)". It loads when the build is selected; while it loads,
/// skeleton rows; when it fails, a quiet line with "Try Again". The "Test Results" link of the ⋯ menu opens Jenkins' own page.
///
/// It takes the tests from `AppModel.failedTests`, or from the gallery's ``FailedTestsFixtures``, so the detail inserts
/// it as one view: `FailedTestsSection(build: id)`.
struct FailedTestsSection: View {
    let build: BuildID

    /// the tests shown before "Show All"
    static let cutAfter = 10

    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.failedTestsFixtures) private var fixtures
    @ViewState private var showsAll = false

    var body: some View {
        let state = fixtures?.state(of: build) ?? model?.failedTests.state(of: build) ?? .loading
        DetailCard("Failed Tests", symbol: "xmark.octagon") {
            switch state {
            case .loading:
                // Three tests' worth of lines, in the card's own chrome.
                SkeletonRows(count: 3, leading: .symbol(column: 16))
            case .failed:
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("The failed tests couldn't be loaded")
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        Task { await load() }
                    }
                    .buttonStyle(.link)
                }
            case .loaded(let tests) where tests.isEmpty:
                Text("The test report lists no failed tests")
                    .foregroundStyle(.secondary)
            case .loaded(let tests):
                let shown = showsAll || fixtures?.expanded == true ? tests : Array(tests.prefix(Self.cutAfter))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, test in
                        FailedTestRow(test: test)
                    }
                }
                if tests.count > Self.cutAfter {
                    Button(showsAll ? "Show Fewer" : "Show All (\(String(tests.count)))") {
                        withAnimation(.snappy) { showsAll.toggle() }
                    }
                    .buttonStyle(.link)
                }
            }
        } accessory: {
            if case .loaded(let tests) = state, !tests.isEmpty {
                CountBadge(text: "\(String(tests.count)) failed", tint: MergeRequestStatus.Color.red.swiftUI)
            }
        }
        // Once per build shown, not once per state: a failure asks again at the next selection or Try Again.
        .task(id: build) { await load() }
        // Another build starts cut again.
        .onChange(of: build) { showsAll = false }
    }

    private func load() async {
        guard fixtures == nil, let model else {
            return
        }
        await model.failedTests.load(build)
    }
}

/// One failed test: a symbol, the class dimmed before the method, and the error message under them; it lights up on
/// hover like the merge request detail's rows.
private struct FailedTestRow: View {
    let test: FailedTest
    @ViewState private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: BuildState.failed.symbol)
                .foregroundStyle(MergeRequestStatus.Color.red.swiftUI)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    if test.status == .regression {
                        // Passing in the build before: the likely cause of this build's result.
                        CountBadge(text: "regression", tint: MergeRequestStatus.Color.orange.swiftUI)
                            .fixedSize()
                    }
                }
                if let message = test.message {
                    Text(verbatim: message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.fill.quaternary.opacity(isHovered ? 1 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { isHovered = $0 }
    }

    /// "CartServiceTest.addsAnItem", the class secondary
    private var title: some View {
        let prefix = test.shortClassName.isEmpty ? "" : test.shortClassName + "."
        return Text("\(Text(verbatim: prefix).foregroundStyle(.secondary))\(Text(verbatim: test.name))")
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The failed tests the gallery shows in place of the store's, by build, and whether the list shows whole.
struct FailedTestsFixtures: Sendable {
    var states: [BuildID: FailedTestsState]
    /// what a build without an entry shows
    var fallback: FailedTestsState = .loading
    var expanded = false

    func state(of build: BuildID) -> FailedTestsState {
        states[build] ?? fallback
    }
}

private struct FailedTestsFixturesKey: EnvironmentKey {
    static let defaultValue: FailedTestsFixtures? = nil
}

extension EnvironmentValues {
    /// the gallery's failed tests; `nil` in the app, which takes the store's
    var failedTestsFixtures: FailedTestsFixtures? {
        get { self[FailedTestsFixturesKey.self] }
        set { self[FailedTestsFixturesKey.self] = newValue }
    }
}
