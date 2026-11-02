import AppKit
import MenubarCore
import SwiftUI

/// The build detail's Build Info card (PIPE-11): what started the build, when, how long it took against the job's usual,
/// the branch, the commit, the agent, and the parameters. What the list already knows (the start, the duration) shows at
/// once; the rest loads when the build is selected, in skeleton lines, and leaves out what Jenkins doesn't say.
///
/// It takes the info from `AppModel.buildInfo`, or from the gallery's ``BuildInfoFixtures``.
struct BuildInfoCard: View {
    let build: Build
    /// the start in the user's short format, "10:12"
    let started: String?
    /// the branch of a branch job, which opens in GitLab; `nil` for a merge request's job
    let branch: BuildLink?
    let actions: PanelActions

    /// the parameters shown before "Show All"
    static let cutAfter = 6

    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.buildInfoFixtures) private var fixtures
    @ViewState private var showsAll = false

    var body: some View {
        let state = fixtures?.info(of: build.id) ?? model?.buildInfo.info(of: build.id) ?? .loading
        let info: BuildInfo? = if case .loaded(let info) = state { info } else { nil }
        DetailCard("Build Info", symbol: "info.circle") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                    if let cause = info?.cause {
                        row("Trigger") { Text(verbatim: cause) }
                    }
                    if let started {
                        row("Started") { Text(verbatim: started) }
                    }
                    if let line = Self.durationLine(of: build, usual: info?.estimatedDuration) {
                        row(line.label) {
                            Text(verbatim: line.text).foregroundStyle(line.tint ?? .primary)
                        }
                    }
                    if let branch {
                        row("Branch") {
                            Button(build.label) { actions.open(branch.url) }
                                .buttonStyle(.link)
                                .help(branch.title)
                        }
                    }
                    if let commit = info?.commit {
                        row("Commit") {
                            Text(verbatim: String(commit.prefix(10)))
                                .font(.callout.monospaced())
                                .help("\(commit)\nRight-click to copy")
                                .contextMenu {
                                    Button("Copy Commit") { Self.copy(commit) }
                                }
                        }
                    }
                    if let node = info?.node {
                        row("Agent") { Text(verbatim: node) }
                    }
                }
                switch state {
                case .loading:
                    SkeletonLines(count: 3, lastFraction: 0.5)
                case .failed:
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("The build's details couldn't be loaded")
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            Task { await model?.buildInfo.load(build) }
                        }
                        .buttonStyle(.link)
                    }
                case .loaded(let info):
                    parameters(info.parameters)
                }
            }
        } accessory: {
            if let info, !info.parameters.isEmpty {
                CountBadge(text: info.parameters.count == 1 ? "1 parameter" : "\(info.parameters.count) parameters")
            }
        }
    }

    private func row(_ label: String, @ViewBuilder _ value: () -> some View) -> some View {
        GridRow {
            Text(verbatim: label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            value()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .gridColumnAlignment(.leading)
        }
    }

    @ViewBuilder
    private func parameters(_ list: [BuildParameter]) -> some View {
        if !list.isEmpty {
            let shown = showsAll ? list : Array(list.prefix(Self.cutAfter))
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text("Parameters")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(shown, id: \.name) { parameter in
                        GridRow {
                            Text(verbatim: parameter.name)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.leading)
                            Text(verbatim: parameter.value.isEmpty ? "–" : parameter.value)
                                .font(.callout.monospaced())
                                .lineLimit(2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .gridColumnAlignment(.leading)
                        }
                    }
                }
                if list.count > Self.cutAfter {
                    Button(showsAll ? "Show Fewer" : "Show All (\(String(list.count)))") {
                        withAnimation(.snappy) { showsAll.toggle() }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    /// The duration against the job's usual, or what is expected while the build runs.
    ///
    /// - Parameters:
    ///   - build: the build
    ///   - usual: Jenkins's expectation from the build's own request; the list's estimate stands in
    /// - Returns: the row's label, text and tint; `nil` with nothing to say
    static func durationLine(of build: Build, usual: TimeInterval?) -> (label: String, text: String, tint: Color?)? {
        let usual = usual ?? build.estimatedDuration
        guard case .finished(_, let duration) = build.phase else {
            return usual.map { ("Expected", "About \(BuildDetailModel.shortDuration($0))", nil) }
        }
        let actual = BuildDetailModel.shortDuration(duration)
        guard let usual else { return ("Duration", actual, nil) }
        let difference = duration - usual
        let typical = BuildDetailModel.shortDuration(usual)
        if abs(difference) < max(30, usual * 0.1) {
            return ("Duration", "\(actual) · about the usual \(typical)", nil)
        }
        let slower = difference > 0
        let by = BuildDetailModel.shortDuration(abs(difference))
        return (
            "Duration", "\(actual) · \(by) \(slower ? "longer" : "shorter") than the usual \(typical)",
            slower ? MergeRequestStatus.Color.orange.swiftUI : MergeRequestStatus.Color.green.swiftUI
        )
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The info and recent builds the gallery shows in place of the store's, by build.
struct BuildInfoFixtures: Sendable {
    var infos: [BuildID: BuildInfoState] = [:]
    var histories: [BuildID: JobHistoryState] = [:]

    func info(of build: BuildID) -> BuildInfoState {
        infos[build] ?? .loading
    }

    func history(of build: BuildID) -> JobHistoryState {
        histories[build] ?? .loading
    }
}

private struct BuildInfoFixturesKey: EnvironmentKey {
    static let defaultValue: BuildInfoFixtures? = nil
}

extension EnvironmentValues {
    /// the gallery's build info; `nil` in the app, which takes the store's
    var buildInfoFixtures: BuildInfoFixtures? {
        get { self[BuildInfoFixturesKey.self] }
        set { self[BuildInfoFixturesKey.self] = newValue }
    }
}
