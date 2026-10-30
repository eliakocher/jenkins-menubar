import MenubarCore
import SwiftUI

/// The update's offer and its progress in the panel's footer, group 1 (`docs/design/update-row.md`, APP-05).
///
/// - "Update Ready — Rebuild" while an update is ready, and again after a failed rebuild, to try again;
/// - "Rebuilding…" with a bar and the current step under it while `build.sh --install` runs: indeterminate until
///   `build.sh` reports counts, then determinate (update-row Decisions 1);
/// - "Relaunching…" with the bar full once the new app is installed;
/// - nothing while the app is up to date.
///
/// The failure is ``UpdateFailureRow``, which the panel shows first in the group.
struct UpdateRow: View {
    let state: UpdateState
    let rebuild: @MainActor () -> Void

    var body: some View {
        switch state {
        case .upToDate:
            EmptyView()
        case .updateReady, .failed:
            Button(action: rebuild) {
                Text(UpdateText.offer)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(PanelRowButtonStyle())
            .help(UpdateText.help)
        case .rebuilding(let progress):
            UpdateProgressRow(title: UpdateText.rebuilding, fraction: progress.fraction, step: progress.step)
        case .installed:
            UpdateProgressRow(title: UpdateText.relaunching, fraction: 1, step: UpdateText.installed)
        }
    }

    /// Returns whether the row shows anything, so the footer knows whether group 1 has a row.
    ///
    /// - Parameter state: where the update stands
    static func shows(_ state: UpdateState) -> Bool {
        state != .upToDate
    }
}

/// "Rebuilding…" or "Relaunching…", the bar, and the step in one line, truncated in the middle. Not clickable.
private struct UpdateProgressRow: View {
    let title: String
    let fraction: Double?
    let step: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `PanelRowLayout`'s spacing before its spacer, by which a build row's bar ends short of the margin; the rebuild
    /// bar ends where the build rows' bars end (review UPDATE-ROW-03)
    private static let trailingInset: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            } else if !reduceMotion {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            } else {
                // With Reduce Motion, the step line alone says that it runs until the first count. The bar keeps its
                // space, so the row doesn't grow when the first count comes (review UPDATE-ROW-01).
                ProgressView(value: 0)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .hidden()
            }
            Text(verbatim: step)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.trailing, Self.trailingInset)
        .panelRowPadding()
    }
}

/// "Update failed: <reason>" as the panel's problem row: up to three lines, then cut in the middle, the whole text as
/// the tooltip (`docs/design/update-row.md`, Failure row).
struct UpdateFailureRow: View {
    /// "Update failed: <reason>"
    let text: String

    var body: some View {
        PanelRowLayout {
            Image(systemName: Marker.problem)
                .foregroundStyle(.red)
        } lines: {
            Text(verbatim: text)
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelRowPadding()
        .help(text)
    }
}

/// The update's words, which the panel row, the toolbar item and the gallery share (`docs/design/update-row.md`, Copy).
enum UpdateText {
    static let offer = "Update Ready — Rebuild"
    static let help = "Rebuild the app from the checkout, then relaunch it"
    static let rebuilding = "Rebuilding…"
    static let relaunching = "Relaunching…"
    static let installed = "Installed"

    /// "Update failed: <reason>", as `RebuildError.message` and the Activity entry say it
    static func failed(_ reason: String) -> String {
        "Update failed: \(reason)"
    }
}
