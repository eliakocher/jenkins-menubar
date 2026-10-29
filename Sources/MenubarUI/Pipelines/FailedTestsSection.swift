import MenubarCore
import SwiftUI

/// The build detail's Failed Tests section (PIPE-03): each failed test as its class and method with the start of its
/// error message, cut after 10 tests with "Show All (N)". It loads when the build is selected; while it loads, a small
/// spinner; when it fails, a quiet line with "Try Again". The "Test Results" link of Links opens Jenkins' own page.
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
        Section {
            switch state {
            case .loading:
                // A small spinner in the part still loading, never over the pane (OD-01).
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                ForEach(Array(shown.enumerated()), id: \.offset) { _, test in
                    FailedTestRow(test: test)
                }
                if tests.count > Self.cutAfter {
                    Button(showsAll ? "Show Fewer" : "Show All (\(String(tests.count)))") {
                        withAnimation(.snappy) { showsAll.toggle() }
                    }
                    .buttonStyle(.link)
                }
            }
        } header: {
            Text("Failed Tests")
                // Once per build shown, not once per state: a failure asks again at the next selection or Try Again.
                .task(id: build) { await load() }
                // Another build starts cut again.
                .onChange(of: build) { showsAll = false }
        }
    }

    private func load() async {
        guard fixtures == nil, let model else {
            return
        }
        await model.failedTests.load(build)
    }
}

/// One failed test: a symbol, the class dimmed before the method, and the error message under them.
private struct FailedTestRow: View {
    let test: FailedTest

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: BuildState.failed.symbol)
                .foregroundStyle(BuildState.failed.color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    if test.status == .regression {
                        // Passing in the build before: the likely cause of this build's result.
                        Text("regression")
                            .font(.callout)
                            .foregroundStyle(.secondary)
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
