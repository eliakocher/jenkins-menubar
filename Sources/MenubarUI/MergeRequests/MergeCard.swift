import MenubarCore
import SwiftUI

/// Where a check's fix leads inside the detail page.
enum MergeCardJump {
    case reviewers
    case builds
    case discussion
}

/// What the gallery shows of the card's own state, which a click sets in the app.
enum MergeCardPhase: Equatable {
    /// "Merge !16 into develop? This can't be undone."
    case confirming
    /// the commit message fields are open
    case editingMessage
}

/// The merge request detail's Merge card (MR-16): the state at a glance in one tinted headline, the checks that need
/// something with their fix inline and the passed ones folded to "3 checks passed", what merging does (the commits, the
/// branches and the work item), the options (delete the source branch, squash, the commit message) and the actions:
/// Merge after an inline confirmation, Set to Auto-Merge, Cancel Auto-Merge and Mark as Ready, as GitLab's own merge
/// widget offers them (the user, 2026-11-03: "the merge button should do what gitlab does"; no Rebase).
///
/// Every write runs on a click only; afterwards the merge request is loaded again and the outcome shows, a failure with
/// GitLab's words and Try Again.
struct MergeCard: View {
    /// whether Merge asks "Merge !16 into develop? This can't be undone." first: the app's rule for a write that can't be
    /// undone; `false` merges on the first click, as GitLab's widget does
    static let confirmsMerge = true

    let model: MergeRequestDetailModel
    let details: MergeRequestDetails?
    let actions: GitLabSectionActions
    let jump: (MergeCardJump) -> Void

    @Environment(AppModel.self) private var appModel: AppModel?
    @Environment(\.mergeRequestDetailsFixtures) private var fixtures
    @ViewState private var phase: MergeCardPhase?
    @ViewState private var showsPassed = false
    /// the user's choices; `nil` keeps GitLab's
    @ViewState private var squash: Bool?
    @ViewState private var removeSourceBranch: Bool?
    @ViewState private var commitMessage: String?
    @ViewState private var squashMessage: String?
    /// the merge request and update last asked for
    @ViewState private var asked: Ask?

    private struct Ask: Hashable {
        var id: MergeRequest.ID
        var updatedAt: Date
    }

    private var mergeRequest: MergeRequest { model.mergeRequest }

    private var store: MergeRequestMergeStore? { fixtures == nil ? appModel?.mergeRequestDetails.merge : nil }

    private var load: MergeStateLoad {
        fixtures?.mergeStates[mergeRequest.reference] ?? store?.load(of: mergeRequest) ?? .loading
    }

    private var activity: MergeActivity {
        fixtures?.mergeActivity[mergeRequest.reference] ?? store?.activity(of: mergeRequest) ?? .idle
    }

    private var currentPhase: MergeCardPhase? { phase ?? fixtures?.mergePhase }

    private var writeAccess: WriteAccess {
        fixtures?.writeAccess ?? appModel?.mergeRequestDetails.writeAccess ?? .unknown
    }

    var body: some View {
        let load = load
        DetailCard("Merge", symbol: "arrow.triangle.merge", width: .fullWidth) {
            if let state = load.state {
                content(state)
            } else if load.failed {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("The merge state couldn't be loaded")
                        .foregroundStyle(.secondary)
                    Button("Try Again") { reload() }
                        .buttonStyle(.link)
                }
            } else {
                skeleton
            }
        }
        .task(id: Ask(id: mergeRequest.id, updatedAt: mergeRequest.updatedAt)) { await loadOnce() }
    }

    // MARK: The content

    @ViewBuilder
    private func content(_ state: MergeState) -> some View {
        let overview = MergeOverview(
            state, approvals: details?.approvals.summary, openThreads: details.flatMap { $0.discussionsLoaded ? $0.threads.count : nil })
        let isOpen = state.lifecycle == .opened
        VStack(alignment: .leading, spacing: 14) {
            // With nothing open, the headline's "All 8 checks passed" unfolds them.
            let foldsInHeadline = overview.open.isEmpty && !overview.passed.isEmpty
            MergeHeadline(
                headline: overview.headline, isWorking: activity.running != nil || state.isMerging,
                isUnfolded: foldsInHeadline && isOpen ? showsPassed : nil
            ) {
                withAnimation(.snappy) { showsPassed.toggle() }
            }
            if isOpen, !overview.open.isEmpty || (foldsInHeadline && showsPassed) {
                checks(overview, foldsInHeadline: foldsInHeadline)
            }
            branches(state)
            if isOpen, overview.actions.contains(where: { $0 == .merge || $0 == .setAutoMerge }) {
                options(state)
            }
            outcome(state)
            if isOpen {
                actionRow(state, overview: overview)
            }
        }
    }

    // MARK: The checks

    private func checks(_ overview: MergeOverview, foldsInHeadline: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(overview.open) { check in
                MergeCheckRow(check: check, isRunning: isRunning(check)) { fix(check) }
                    .disabled(activity.running != nil && !isRunning(check))
            }
            if foldsInHeadline {
                ForEach(overview.passed) { check in
                    MergeCheckRow(check: check, isQuiet: true) {}
                }
            } else if !overview.passed.isEmpty {
                Button {
                    withAnimation(.snappy) { showsPassed.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MergeRequestStatus.Color.green.swiftUI)
                            .frame(width: 18)
                        Text(verbatim: "\(overview.passed.count) \(overview.passed.count == 1 ? "check" : "checks") passed")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showsPassed ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(showsPassed ? "Hide the checks that passed" : "Show the checks that passed")
                if showsPassed {
                    ForEach(overview.passed) { check in
                        MergeCheckRow(check: check, isQuiet: true) {}
                    }
                }
            }
        }
        .padding(4)
        .background(.fill.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// whether the check's fix is the write on its way
    private func isRunning(_ check: MergeCheck) -> Bool {
        check.fix == .markReady && activity.running == .markReady
    }

    /// Runs a check's fix: a jump in the page, a page in the browser, or a write.
    private func fix(_ check: MergeCheck) {
        switch check.fix {
        case .assignReviewers, .showReviewers: jump(.reviewers)
        case .showBuild:
            if let build = model.jenkinsBuild {
                actions.showInPipelines(build.job)
            } else {
                jump(.builds)
            }
        case .showThreads: jump(.discussion)
        case .markReady: run(.markReady, state: load.state)
        case .openConflicts: actions.open(mergeRequest.webURL.appending(path: "conflicts"))
        case .openInGitLab: actions.open(mergeRequest.webURL)
        case nil: break
        }
    }

    // MARK: What merging does

    @ViewBuilder
    private func branches(_ state: MergeState) -> some View {
        let squashes = squash ?? state.squash.isOn
        VStack(alignment: .leading, spacing: 8) {
            PillFlowLayout(spacing: 6, lineSpacing: 6) {
                BranchName(name: state.sourceBranch)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
                BranchName(name: state.targetBranch)
                // The work item the merge request names or closes, the blue "#19202" (MR-12).
                WorkItemLinkChips(
                    items: model.workItems, project: Self.project(of: mergeRequest.reference), actions: actions.itemLinks)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if state.lifecycle == .opened, let summary = state.summary(squash: squashes) {
                Text(verbatim: summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "group/project" of `group/project!12`, whose work items show as "#123"
    private static func project(of reference: String) -> String {
        reference.split(separator: "!").dropLast().joined(separator: "!")
    }

    // MARK: The options

    @ViewBuilder
    private func options(_ state: MergeState) -> some View {
        let isBusy = activity.running != nil
        let squashes = squash ?? state.squash.isOn
        let isEditing = currentPhase == .editingMessage
        VStack(alignment: .leading, spacing: 10) {
            PillFlowLayout(spacing: 18, lineSpacing: 8) {
                Toggle("Delete Source Branch", isOn: binding($removeSourceBranch, default: state.removesSourceBranch))
                    .disabled(!state.permissions.canRemoveSourceBranch || isBusy)
                    .help("Deletes \(state.sourceBranch) after the merge")
                switch state.squash {
                case .never:
                    EmptyView()
                case .always:
                    Toggle("Squash Commits", isOn: .constant(true))
                        .disabled(true)
                        .help("The project always squashes")
                case .optional:
                    Toggle("Squash Commits", isOn: binding($squash, default: state.squash.isOn))
                        .disabled(isBusy)
                        .help("Squashes the commits into one before the merge")
                }
                if hasMessage(state, squashes: squashes) {
                    Button(isEditing ? "Hide Commit Message" : "Edit Commit Message…") {
                        withAnimation(.snappy) { phase = isEditing ? nil : .editingMessage }
                    }
                    .buttonStyle(.link)
                    .disabled(isBusy)
                }
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            if isEditing {
                if squashes {
                    MessageField(title: "Squash Commit", text: binding($squashMessage, default: state.defaultSquashMessage ?? mergeRequest.title))
                }
                if !state.fastForwardOnly {
                    MessageField(title: "Merge Commit", text: binding($commitMessage, default: state.defaultMergeMessage ?? ""))
                }
            }
            if state.squash == .always {
                Text("The project always squashes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// whether the merge makes a commit whose message the user may write
    private func hasMessage(_ state: MergeState, squashes: Bool) -> Bool {
        squashes || !state.fastForwardOnly
    }

    private func binding<Value>(_ choice: Binding<Value?>, default value: Value) -> Binding<Value> {
        Binding(get: { choice.wrappedValue ?? value }, set: { choice.wrappedValue = $0 })
    }

    /// The options to send: a message only when the user changed GitLab's.
    private func chosenOptions(_ state: MergeState) -> MergeOptions {
        let squashes = state.squash == .never ? false : state.squash == .always ? true : squash ?? state.squash.isOn
        func edited(_ text: String?, default value: String?) -> String? {
            guard let text, text != value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return text
        }
        return MergeOptions(
            squash: squashes, removeSourceBranch: removeSourceBranch ?? state.removesSourceBranch,
            commitMessage: state.fastForwardOnly ? nil : edited(commitMessage, default: state.defaultMergeMessage),
            squashMessage: squashes ? edited(squashMessage, default: state.defaultSquashMessage) : nil)
    }

    // MARK: The actions

    @ViewBuilder
    private func actionRow(_ state: MergeState, overview: MergeOverview) -> some View {
        let running = activity.running
        let primary = overview.actions.first { [.merge, .setAutoMerge, .cancelAutoMerge].contains($0) }
        if currentPhase == .confirming, primary == .merge {
            confirmation(state)
        } else if let primary {
            HStack(spacing: 10) {
                Button {
                    if primary == .merge, Self.confirmsMerge {
                        withAnimation(.snappy) { phase = .confirming }
                    } else {
                        run(primary, state: state)
                    }
                } label: {
                    HStack(spacing: 6) {
                        if running == primary {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: Self.symbol(primary))
                        }
                        Text(verbatim: running == primary ? Self.runningTitle(primary) : Self.title(primary, state: state))
                    }
                }
                .buttonStyle(MergeButtonStyle(tint: Self.tint(primary), isFilled: primary != .cancelAutoMerge))
                .disabled(running != nil)
                .help(Self.help(primary, state: state))
                if writeAccess == .readOnly {
                    tokenNote
                }
                Spacer(minLength: 0)
            }
        } else if writeAccess == .readOnly, !overview.actions.isEmpty {
            tokenNote
        }
    }

    /// "Merge !16 into develop? This can't be undone."
    private func confirmation(_ state: MergeState) -> some View {
        let options = chosenOptions(state)
        var also: [String] = []
        if options.squash {
            also.append("squashes the commits")
        }
        if options.removeSourceBranch {
            also.append("deletes \(state.sourceBranch)")
        }
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "Merge !\(mergeRequest.iid) into \(state.targetBranch)?")
                    .font(.body.weight(.semibold))
                Text(verbatim: (also.isEmpty ? "" : "It \(also.joined(separator: " and ")). ") + "This can't be undone.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    phase = nil
                    run(.merge, state: state)
                } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(MergeButtonStyle(tint: MergeRequestStatus.Color.green.swiftUI))
                .keyboardShortcut(.defaultAction)
                Button("Cancel") { withAnimation(.snappy) { phase = nil } }
                    .buttonStyle(MergeButtonStyle(tint: MergeRequestStatus.Color.neutral.swiftUI, isFilled: false))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MergeRequestStatus.Color.green.swiftUI.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(MergeRequestStatus.Color.green.swiftUI.opacity(0.30), lineWidth: 0.75)
        }
    }

    private var tokenNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "key.fill")
                .foregroundStyle(MergeRequestStatus.Color.orange.swiftUI)
            Text("Merging needs a GitLab token with the api scope.")
                .foregroundStyle(.secondary)
            Button("Open Accounts") { actions.openSettings(.accounts) }
                .buttonStyle(.link)
        }
        .font(.callout)
    }

    // MARK: The outcome

    @ViewBuilder
    private func outcome(_ state: MergeState) -> some View {
        switch activity {
        case .idle, .running:
            EmptyView()
        case .succeeded(let action):
            OutcomeLine(
                symbol: "checkmark.circle.fill", tint: MergeRequestStatus.Color.green.swiftUI,
                text: Self.doneText(action, state: state), dismiss: dismiss)
        case .failed(let action, let message, let needsToken):
            OutcomeLine(
                symbol: "exclamationmark.triangle.fill", tint: MergeRequestStatus.Color.red.swiftUI,
                // A message that already names the scope ("GitLab refused: your token may only have read access…") stands alone.
                text: needsToken && !message.contains("api scope")
                    ? "\(message). \(action.title) needs a GitLab token with the api scope." : message,
                dismiss: dismiss
            ) {
                if needsToken {
                    Button("Open Accounts") { actions.openSettings(.accounts) }
                        .buttonStyle(.link)
                } else {
                    Button("Try Again") { run(action, state: state) }
                        .buttonStyle(.link)
                }
            }
        }
    }

    // MARK: Running

    /// Runs a write after the user's click; the store refreshes the merge request after it.
    private func run(_ action: MergeAction, state: MergeState?) {
        guard let store, let state else {
            return
        }
        let options = chosenOptions(state)
        let mergeRequest = mergeRequest
        Task { await store.perform(action, on: mergeRequest, options: options) }
    }

    private func dismiss() {
        store?.dismiss(mergeRequest)
    }

    private func reload() {
        asked = nil
        Task { await loadOnce() }
    }

    private func loadOnce() async {
        let ask = Ask(id: mergeRequest.id, updatedAt: mergeRequest.updatedAt)
        guard let store, asked != ask else {
            return
        }
        asked = ask
        await store.load(mergeRequest)
        await appModel?.mergeRequestDetails.checkWriteAccess()
    }

    // MARK: Words

    private static func symbol(_ action: MergeAction) -> String {
        switch action {
        case .merge: "arrow.triangle.merge"
        case .setAutoMerge: "clock.badge.checkmark"
        case .cancelAutoMerge: "xmark.circle"
        case .markReady: "checkmark.circle"
        }
    }

    private static func runningTitle(_ action: MergeAction) -> String {
        switch action {
        case .merge: "Merging…"
        case .setAutoMerge: "Setting Auto-Merge…"
        case .cancelAutoMerge: "Canceling…"
        case .markReady: "Marking as Ready…"
        }
    }

    private static func tint(_ action: MergeAction) -> Color {
        switch action {
        case .merge: MergeRequestStatus.Color.green.swiftUI
        case .setAutoMerge: MergeRequestStatus.Color.blue.swiftUI
        case .cancelAutoMerge: MergeRequestStatus.Color.red.swiftUI
        default: MergeRequestStatus.Color.neutral.swiftUI
        }
    }

    private static func help(_ action: MergeAction, state: MergeState) -> String {
        switch action {
        case .merge: "Merges into \(state.targetBranch)\(confirmsMerge ? ", after your confirmation" : "")"
        case .setAutoMerge: state.autoMergeJoinsTrain ? "Adds it to the merge train" : "GitLab merges it once every check passes"
        case .cancelAutoMerge: "Stops GitLab from merging it when the checks pass"
        case .markReady: "Takes the draft mark off"
        }
    }

    /// the button's words: GitLab's "Add to Merge Train" when that is the auto-merge it offers
    private static func title(_ action: MergeAction, state: MergeState) -> String {
        action == .setAutoMerge && state.autoMergeJoinsTrain ? "Add to Merge Train" : action.title
    }

    private static func doneText(_ action: MergeAction, state: MergeState) -> String {
        switch action {
        case .merge: state.lifecycle == .merged ? "Merged into \(state.targetBranch)" : "GitLab took the merge"
        case .setAutoMerge: "Auto-merge set: GitLab merges it when the checks pass"
        case .cancelAutoMerge: "Auto-merge canceled"
        case .markReady: "Marked as ready"
        }
    }

    // MARK: Loading

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBlock(height: 54)
            SkeletonBlock(fraction: 0.6, height: 10, lineHeight: 20)
            SkeletonBlock(fraction: 0.4, height: 10, lineHeight: 20)
        }
        .skeletonShimmer()
    }
}

// MARK: - The pieces

/// The state at a glance: a tinted band with the state's glyph, its words and the line under them.
private struct MergeHeadline: View {
    let headline: MergeOverview.Headline
    /// whether a write or GitLab's own work is under way: the glyph pulses
    let isWorking: Bool
    /// whether the passed checks the detail line names are unfolded; `nil` when the line folds nothing
    var isUnfolded: Bool?
    var toggle: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tint = headline.tone.color
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: headline.symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: isWorking)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: headline.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                if let detail = headline.detail {
                    if let isUnfolded {
                        Button(action: toggle) {
                            HStack(spacing: 4) {
                                Text(verbatim: detail)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .rotationEffect(.degrees(isUnfolded ? 90 : 0))
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(isUnfolded ? "Hide the checks" : "Show the checks that passed")
                    } else {
                        Text(verbatim: detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(tint.opacity(colorScheme == .dark ? 0.16 : 0.10), in: shape)
        .overlay { shape.strokeBorder(tint.opacity(0.28), lineWidth: 0.75) }
        .accessibilityElement(children: .combine)
    }
}

/// One check: its status glyph, its words and the line under them, and its fix as a small button.
private struct MergeCheckRow: View {
    let check: MergeCheck
    /// a passed check, listed when unfolded: no fix, a lighter look
    var isQuiet = false
    /// whether its write is on its way: a spinner in place of the button
    var isRunning = false
    let fix: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: check.status.symbol)
                .foregroundStyle(check.status.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: check.title)
                    .foregroundStyle(isQuiet ? .secondary : .primary)
                if let detail = check.detail {
                    Text(verbatim: detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 8)
            if isRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: "Saving…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if !isQuiet, let title = check.fix?.title {
                Button(action: fix) {
                    if check.fix?.opensBrowser == true {
                        Label(title, systemImage: "arrow.up.forward")
                            .labelStyle(.titleAndIcon)
                    } else {
                        Text(verbatim: title)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(check.fix?.help ?? title)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// A branch's name as a quiet monospaced capsule.
private struct BranchName: View {
    let name: String

    var body: some View {
        Text(verbatim: name)
            .font(.callout.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .textSelection(.enabled)
            .help(name)
    }
}

/// A commit message to edit, prefilled with GitLab's.
private struct MessageField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .padding(6)
                .frame(minHeight: 72, maxHeight: 140)
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.75)
                }
        }
    }
}

/// The outcome of the last write, with a button of its own and a close button.
private struct OutcomeLine<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    let dismiss: () -> Void
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            accessory
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension OutcomeLine where Accessory == EmptyView {
    init(symbol: String, tint: Color, text: String, dismiss: @escaping () -> Void) {
        self.init(symbol: symbol, tint: tint, text: text, dismiss: dismiss) { EmptyView() }
    }
}

/// The card's own buttons: a filled capsule in the action's color, or a quiet one for Cancel.
private struct MergeButtonStyle: ButtonStyle {
    let tint: Color
    var isFilled = true

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let opacity = isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.55
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isFilled ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background {
                Capsule()
                    .fill(isFilled ? AnyShapeStyle(tint.opacity(opacity)) : AnyShapeStyle(tint.opacity(configuration.isPressed ? 0.22 : 0.12)))
                    .shadow(color: isFilled ? tint.opacity(0.28) : .clear, radius: 3, y: 1)
            }
            .contentShape(Capsule())
    }
}

// MARK: - Colors and words

extension MergeOverview.Tone {
    /// GitLab's colors: green ready, red blocked, orange waiting, blue auto-merge, purple merged
    var color: Color {
        switch self {
        case .ready: MergeRequestStatus.Color.green.swiftUI
        case .blocked: MergeRequestStatus.Color.red.swiftUI
        case .waiting: MergeRequestStatus.Color.orange.swiftUI
        case .autoMerge: MergeRequestStatus.Color.blue.swiftUI
        case .merged: .purple
        case .neutral: MergeRequestStatus.Color.neutral.swiftUI
        }
    }
}

extension MergeCheck.Status {
    var symbol: String {
        switch self {
        case .failed: "xmark.circle.fill"
        case .pending: "clock.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        case .passed: "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .failed: MergeRequestStatus.Color.red.swiftUI
        case .pending, .warning: MergeRequestStatus.Color.orange.swiftUI
        case .info: MergeRequestStatus.Color.neutral.swiftUI
        case .passed: MergeRequestStatus.Color.green.swiftUI
        }
    }
}

extension MergeCheck.Fix {
    /// the button's title, in Title Style
    var title: String {
        switch self {
        case .assignReviewers: "Assign Reviewers"
        case .showReviewers: "Show Reviewers"
        case .showBuild: "Show Build"
        case .showThreads: "Show Threads"
        case .markReady: "Mark as Ready"
        case .openConflicts, .openInGitLab: "Open in GitLab"
        }
    }

    /// whether the fix opens a page in the browser, which its arrow says
    var opensBrowser: Bool { self == .openConflicts || self == .openInGitLab }

    var help: String {
        switch self {
        case .assignReviewers: "Shows the Reviewers card"
        case .showReviewers: "Shows the reviewers and their reviews"
        case .showBuild: "Shows the merge request's build"
        case .showThreads: "Jumps to the open threads in the Discussion card"
        case .markReady: "Takes the draft mark off in GitLab"
        case .openConflicts: "Opens GitLab's page for the conflicts"
        case .openInGitLab: "Opens the merge request in GitLab"
        }
    }
}
