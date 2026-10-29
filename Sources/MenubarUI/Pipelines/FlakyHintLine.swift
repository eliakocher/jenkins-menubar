import MenubarCore
import SwiftUI

/// The quiet hint under the build detail's buttons (PIPE-10): which failed stages of the selected build look flaky, from
/// the job's recent runs, like "unit-tests passed on the same commit in #4: likely flaky". It loads when the build is
/// selected; while it loads, a small spinner with one line, and it leaves out what the history can't say or a failed
/// load, so it only ever adds. It never starts a rebuild.
///
/// It takes the hints from `AppModel.flakyHints`, or from the gallery's ``FlakyHintFixtures``, so the detail inserts it
/// as one view: `FlakyHintLine(build:)`.
struct FlakyHintLine: View {
    let build: Build

    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.flakyHintFixtures) private var fixtures
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = fixtures?.state(of: build.id) ?? model?.flakyHints.state(of: build.id) ?? .loading
        Group {
            switch state {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Checking recent runs…")
                }
                .foregroundStyle(.tertiary)
            case .loaded(let hints) where !hints.isEmpty:
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(hints, id: \.self) { hint in
                        Label {
                            Text(verbatim: Self.message(of: hint))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: Self.symbol(of: hint))
                        }
                    }
                }
                .foregroundStyle(.secondary)
            case .loaded, .failed:
                EmptyView()
            }
        }
        .font(.callout)
        // The line grows and shrinks with the answer, so the buttons above stay and the rest eases down or up.
        .animation(reduceMotion ? nil : .snappy, value: state)
        .task(id: build.id) {
            guard fixtures == nil, let model else { return }
            await model.flakyHints.load(build.id, stages: build.stages ?? [])
        }
    }

    /// Returns a hint's text: "unit-tests passed on the same commit in #4: likely flaky".
    static func message(of hint: FlakyHint) -> String {
        switch hint {
        case .passedOnSameCommit(let stage, let number):
            "\(stage) passed on the same commit in #\(number): likely flaky"
        case .failedBefore(let stage, let failed, let total):
            "\(stage) failed \(failed) of the last \(total) runs"
        }
    }

    static func symbol(of hint: FlakyHint) -> String {
        switch hint {
        case .passedOnSameCommit: "dice"
        case .failedBefore: "clock.arrow.circlepath"
        }
    }
}

/// The hints the gallery shows in place of the store's, by build.
struct FlakyHintFixtures: Sendable {
    var states: [BuildID: FlakyHintState]

    func state(of build: BuildID) -> FlakyHintState {
        states[build] ?? .loaded([])
    }
}

private struct FlakyHintFixturesKey: EnvironmentKey {
    static let defaultValue: FlakyHintFixtures? = nil
}

extension EnvironmentValues {
    /// the gallery's hints; `nil` in the app, which takes the store's
    var flakyHintFixtures: FlakyHintFixtures? {
        get { self[FlakyHintFixturesKey.self] }
        set { self[FlakyHintFixturesKey.self] = newValue }
    }
}
