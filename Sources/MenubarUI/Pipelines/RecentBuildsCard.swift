import MenubarCore
import SwiftUI

/// The build detail's Recent Builds card (PIPE-11): the job's last builds as a strip of small tiles, each with its state
/// and duration; a click shows that build in the app, ⌥ opens it in Jenkins. The selected build is lit. The "likely
/// flaky" hints (PIPE-10) live here, under the strip, since they come from these runs.
struct RecentBuildsCard: View {
    let build: Build
    /// the team's Jenkins job, which makes the tiles' links; `nil` makes tiles that do nothing
    let jobURL: URL?
    /// the finished failed build whose stages the flaky hints judge; `nil` for any other
    let flakyCheck: Build?
    let actions: PanelActions

    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.buildInfoFixtures) private var fixtures

    var body: some View {
        let state = fixtures?.history(of: build.id) ?? model?.buildInfo.history(of: build.id) ?? .loading
        DetailCard("Recent Builds", symbol: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 12) {
                switch state {
                case .loading:
                    SkeletonStrip()
                case .failed:
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("The job's recent builds couldn't be loaded")
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            Task { await model?.buildInfo.load(build) }
                        }
                        .buttonStyle(.link)
                    }
                case .loaded(let builds):
                    PillFlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(builds) { entry in
                            RecentBuildTile(
                                entry: entry, isSelected: entry.number == build.number, url: url(of: entry), actions: actions)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let flakyCheck {
                    FlakyHintLine(build: flakyCheck, asChips: true)
                }
            }
        } accessory: {
            if case .loaded(let builds) = state {
                let failed = builds.filter { $0.result.map { $0 != .success } == true }.count
                if failed > 0 {
                    CountBadge(text: "\(failed) of \(builds.count) not green", tint: MergeRequestStatus.Color.orange.swiftUI)
                }
            }
        }
    }

    private func url(of entry: JobHistoryBuild) -> URL? {
        jobURL.map { AlertContent.buildURL(job: build.job, number: entry.number, jobURL: $0) }
    }
}

/// One build of the strip: its symbol and number over its duration, tinted by its state.
private struct RecentBuildTile: View {
    let entry: JobHistoryBuild
    let isSelected: Bool
    let url: URL?
    let actions: PanelActions

    @ViewState private var isHovered = false

    var body: some View {
        let state = entry.result.map(BuildState.init) ?? .running
        let tint = state.detailTint
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let tile = VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: state.symbol)
                    .foregroundStyle(tint)
                Text(verbatim: "#\(entry.number)")
                    .fontWeight(isSelected ? .semibold : .regular)
                    .monospacedDigit()
            }
            Text(verbatim: entry.duration.map(BuildDetailModel.shortDuration) ?? (entry.isRunning ? "running" : "–"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 64, alignment: .leading)
        .background(tint.opacity(isSelected ? 0.20 : (isHovered && url != nil ? 0.16 : 0.09)), in: shape)
        .overlay { shape.strokeBorder(tint.opacity(isSelected ? 0.7 : 0.25), lineWidth: isSelected ? 1.25 : 0.5) }
        .contentShape(shape)
        .help(help(state))
        if let url, !isSelected {
            Button { actions.follow(url) } label: { tile }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .contextMenu {
                    Button("Show Build #\(String(entry.number))") { actions.follow(url) }
                    Button("Open Build in Jenkins") { actions.open(url) }
                    Divider()
                    Button("Copy Link") { actions.copy(url) }
                }
        } else {
            tile
        }
    }

    private func help(_ state: BuildState) -> String {
        var parts = ["Build #\(String(entry.number))", state.resultText?.capitalized ?? "Running"]
        if let started = entry.startedAt {
            parts.append(started.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
}

/// The strip while the history loads: tiles' worth of bars, in the card's own chrome.
private struct SkeletonStrip: View {
    var body: some View {
        PillFlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(0..<5, id: \.self) { _ in
                SkeletonBlock(width: 64, height: 38)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .skeletonShimmer()
    }
}

extension BuildState {
    /// the state's color in the build detail, in the tokens of the merge request detail
    var detailTint: Color {
        switch self {
        case .running: MergeRequestStatus.Color.blue.swiftUI
        case .failed: MergeRequestStatus.Color.red.swiftUI
        case .unstable: MergeRequestStatus.Color.orange.swiftUI
        case .successful: MergeRequestStatus.Color.green.swiftUI
        case .aborted, .other: MergeRequestStatus.Color.neutral.swiftUI
        }
    }
}
