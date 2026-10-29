import MenubarCore
import SwiftUI

/// The problem rows atop a section's list (`docs/design/main-window.md`, "What the sections share"): put them first in
/// the section's `List`, before its first `Section`, with the app-wide items first (``MainWindowProblems/appWide(jenkins:update:)``)
/// and then the section's own. They aren't selectable; a linked one has a trailing "Open Settings…" button.
///
/// It draws only what it is given, so the gallery can show it with fixtures.
public struct MainWindowProblemRows: View {
    private let items: [PanelModel.ProblemItem]
    private let openSettings: (SettingsPane) -> Void

    /// - Parameters:
    ///   - items: the rows, app-wide first
    ///   - openSettings: opens Settings at a pane, for a linked row's button
    public init(_ items: [PanelModel.ProblemItem], openSettings: @escaping (SettingsPane) -> Void) {
        self.items = items
        self.openSettings = openSettings
    }

    public var body: some View {
        ForEach(items) { item in
            row(item)
                .selectionDisabled()
        }
    }

    /// The text with its button beside it while both fit on one line, else the button under the text, so the
    /// explanation, the part people need, is never cut.
    private func row(_ item: PanelModel.ProblemItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                label(of: item)
                    .lineLimit(1)
                Spacer(minLength: 8)
                button(of: item)
            }
            VStack(alignment: .leading, spacing: 6) {
                label(of: item)
                    .lineLimit(4)
                button(of: item)
            }
        }
    }

    private func label(of item: PanelModel.ProblemItem) -> some View {
        Label {
            Text(verbatim: item.text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func button(of item: PanelModel.ProblemItem) -> some View {
        if let pane = item.pane {
            Button("Open Settings…") {
                openSettings(pane)
            }
            .help(item.help ?? "")
        }
    }
}

/// The problem rows every section's list starts with.
public enum MainWindowProblems {
    /// Returns the app-wide problem rows: the team values (TEAM-03), offline (OD-05), then a failed update (APP-05).
    /// Jenkins' own problems (JERR) aren't among them: only Pipelines shows those.
    ///
    /// - Parameters:
    ///   - jenkins: `PipelinesStore.problem`
    ///   - update: `UpdateStore.state`
    /// - Returns: the rows, in their order
    public static func appWide(jenkins: Problem?, update: UpdateState) -> [PanelModel.ProblemItem] {
        if teamValuesMissing(jenkins) {
            // TEAM-03 shows alone: nothing can be asked without the values.
            return [PanelModel.problemItem(.teamValuesMissing)]
        }
        var items: [PanelModel.ProblemItem] = []
        if jenkins == .offline {
            items.append(PanelModel.problemItem(.offline))
        }
        if case .failed(let reason) = update {
            items.append(PanelModel.ProblemItem(text: "Update failed: \(reason)", pane: nil))
        }
        return items
    }

    /// Returns whether the team values are missing; the section then shows their row alone, without rows of its own.
    ///
    /// - Parameter jenkins: `PipelinesStore.problem`
    public static func teamValuesMissing(_ jenkins: Problem?) -> Bool {
        jenkins == .teamValuesMissing
    }
}
