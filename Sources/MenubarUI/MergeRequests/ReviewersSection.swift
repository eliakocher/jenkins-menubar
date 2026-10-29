import MenubarCore
import SwiftUI

/// What the Reviewers section is doing about re-requests (MR-09, MR-10).
enum ReReviewPhase: Equatable {
    case idle
    /// the bulk action asked once: "Re-request review from Sam, Kim and 5 others?"
    case confirming
    /// the requests of these reviewers (by username) are on their way
    case sending(Set<String>)
    /// what the last run did
    case done(ReReviewOutcome)
    /// the token can't write: the explanation, with the way to a new one
    case needsToken
}

/// The merge request detail's Reviewers: each reviewer with their review, a "Re-request Review" button (↻) on those who
/// reviewed with a nudge where the code changed since ("2 new commits since Sam's review"), and above the list
/// "Re-request Reviews (N)" for the stale ones, which confirms once (MR-09, MR-10).
///
/// The first write of the app: nothing is sent without a click, and nothing again after a failure. A token without the
/// `api` scope gets the explanation, from what GitLab says of the token before the click, else from its refusal.
struct ReviewersSection: View {
    let model: MergeRequestDetailModel
    let actions: GitLabSectionActions

    @Environment(AppModel.self) private var appModel: AppModel?
    @Environment(\.mergeRequestDetailsFixtures) private var fixtures
    @ViewState private var phase: ReReviewPhase?
    /// what the check of the token asked for last, so a state change for the same merge request doesn't ask again
    @ViewState private var checked: Check?

    private struct Check: Hashable {
        var id: MergeRequest.ID
        var hasReviewers: Bool
    }

    private var currentPhase: ReReviewPhase { phase ?? fixtures?.reReviewPhase ?? .idle }

    private var reviews: MergeRequestReviews? {
        let state = fixtures?.states[model.mergeRequest.reference] ?? appModel?.mergeRequestDetails.state(of: model.mergeRequest)
        return state?.details?.reviews
    }

    private var writeAccess: WriteAccess {
        fixtures?.writeAccess ?? appModel?.mergeRequestDetails.writeAccess ?? .unknown
    }

    var body: some View {
        let reviews = reviews
        let toAsk = reviews?.reviewersToAsk ?? []
        let isBusy = if case .sending = currentPhase { true } else { false }
        Section("Reviewers") {
            if model.reviewers.isEmpty {
                Text(verbatim: MergeRequestDetailModel.noReviewers)
                    .foregroundStyle(.secondary)
            }
            if toAsk.count >= 2 {
                bulk(toAsk, isBusy: isBusy)
            }
            ForEach(model.reviewers) { row in
                ReviewerRowView(
                    row: row, reviews: reviews, reviewer: reviews?.reviewers.first { $0.username == row.id },
                    phase: currentPhase, isBusy: isBusy
                ) { reviewer in
                    start([reviewer])
                }
            }
            feedback
        }
        .task(id: Check(id: model.mergeRequest.id, hasReviewers: reviews?.reviewers.contains(where: \.hasReviewed) == true)) {
            await checkToken()
        }
    }

    // MARK: Bulk

    /// "Re-request Reviews (N)", or the question it asks once.
    @ViewBuilder
    private func bulk(_ toAsk: [MergeRequestReviews.Reviewer], isBusy: Bool) -> some View {
        if currentPhase == .confirming {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: MergeRequestReviews.confirmation(for: toAsk))
                HStack(spacing: 8) {
                    Button("Re-request Reviews") { start(toAsk) }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel") { phase = .idle }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
            .padding(.vertical, 2)
        } else {
            HStack {
                Button("Re-request Reviews (\(toAsk.count))") {
                    // A token that can't write is told at the first click, before a question about asking anyone.
                    phase = writeAccess == .readOnly ? .needsToken : .confirming
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy)
                .help("Ask the reviewers whose review is older than the last push to review again")
                Spacer()
            }
        }
    }

    // MARK: The outcome

    @ViewBuilder
    private var feedback: some View {
        switch currentPhase {
        case .idle, .confirming, .sending:
            EmptyView()
        case .needsToken:
            TokenNote(newTokenURL: model.newTokenURL, actions: actions) { phase = .idle }
        case .done(let outcome):
            if !outcome.sent.isEmpty {
                SymbolText(
                    symbol: "checkmark.circle.fill", style: AnyShapeStyle(MergeRequestStatus.Color.green.swiftUI),
                    text: Self.sentText(outcome.sent))
            }
            ForEach(outcome.failures, id: \.reviewer.id) { failure in
                SymbolText(
                    symbol: "exclamationmark.triangle.fill", style: AnyShapeStyle(MergeRequestStatus.Color.red.swiftUI),
                    text: "\(failure.reviewer.displayName): \(failure.message)")
            }
        }
    }

    /// "Review re-requested from Sam", "Review re-requested from 5 reviewers"
    static func sentText(_ sent: [MergeRequestReviews.Reviewer]) -> String {
        sent.count == 1 ? "Review re-requested from \(sent[0].displayName)" : "Review re-requested from \(sent.count) reviewers"
    }

    // MARK: Actions

    /// Sends the requests after a click, unless the token is known to be unable to write; then reloads the details.
    private func start(_ reviewers: [MergeRequestReviews.Reviewer]) {
        guard writeAccess != .readOnly else {
            phase = .needsToken
            return
        }
        guard fixtures == nil, let store = appModel?.mergeRequestDetails else {
            return
        }
        phase = .sending(Set(reviewers.map(\.username)))
        let mergeRequest = model.mergeRequest
        Task {
            let outcome = await store.reRequest(reviewers, of: mergeRequest)
            // What GitLab said of the token isn't known to be wrong, so its refusal gets the same explanation.
            phase = outcome.needsToken && store.writeAccess != .allowed ? .needsToken : .done(outcome)
        }
    }

    /// Asks GitLab what the token may do, when there is a review to ask for again.
    private func checkToken() async {
        let check = Check(id: model.mergeRequest.id, hasReviewers: reviews?.reviewers.contains(where: \.hasReviewed) == true)
        guard fixtures == nil, let store = appModel?.mergeRequestDetails, check.hasReviewers, checked != check else {
            return
        }
        checked = check
        await store.checkWriteAccess()
    }
}

// MARK: - A reviewer

/// A reviewer: the name with the nudge under it, the review's state and the ↻ button.
private struct ReviewerRowView: View {
    let row: MergeRequestDetailModel.ReviewerRow
    let reviews: MergeRequestReviews?
    let reviewer: MergeRequestReviews.Reviewer?
    let phase: ReReviewPhase
    let isBusy: Bool
    let reRequest: (MergeRequestReviews.Reviewer) -> Void

    /// The row as GitLab's newest answer has it, which a re-request changes before the list reloads.
    private var current: MergeRequestDetailModel.ReviewerRow {
        guard let reviewer else {
            return row
        }
        var row = row
        (row.word, row.mark) = MergeRequestDetailModel.ReviewerRow.describe(state: reviewer.reviewState, approved: reviewer.approved)
        return row
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                ReviewStateView(reviewer: current)
                if let reviewer, reviewer.hasReviewed {
                    button(reviewer)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.name)
                if let reviews, let reviewer, let nudge = reviews.nudge(for: reviewer) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(verbatim: nudge)
                    }
                    .font(.subheadline)
                    .foregroundStyle(MergeRequestStatus.Color.orange.swiftUI)
                }
            }
        }
    }

    /// ↻ in the accent color where the review is stale, quiet where it saw the last push; a spinner while it is sent.
    @ViewBuilder
    private func button(_ reviewer: MergeRequestReviews.Reviewer) -> some View {
        if case .sending(let who) = phase, who.contains(reviewer.username) {
            ProgressView()
                .controlSize(.small)
        } else {
            let stale = if case .stale = reviews?.freshness(of: reviewer) { true } else { false }
            Button { reRequest(reviewer) } label: {
                Image(systemName: "arrow.clockwise")
                    .fontWeight(stale ? .semibold : .regular)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(stale ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .disabled(isBusy)
            .help("Re-request review from \(reviewer.displayName)")
            .accessibilityLabel("Re-request Review")
        }
    }
}

/// A reviewer's review: a symbol for an approval or requested changes, and the state's word, `.secondary` without a
/// symbol.
private struct ReviewStateView: View {
    let reviewer: MergeRequestDetailModel.ReviewerRow

    var body: some View {
        switch reviewer.mark {
        case .approved:
            SymbolText(symbol: "checkmark.circle.fill", style: AnyShapeStyle(MergeRequestStatus.Color.green.swiftUI),
                       text: reviewer.word)
        case .requestedChanges:
            SymbolText(symbol: "exclamationmark.circle.fill", style: AnyShapeStyle(MergeRequestStatus.Color.orange.swiftUI),
                       text: reviewer.word)
        case nil:
            Text(verbatim: reviewer.word)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - The token

/// "Re-requesting a review needs a GitLab token with the api scope.", with the button that opens GitLab's new-token page
/// with the name and scope filled in, and the way to Settings → Accounts, where the new token replaces the stored one.
private struct TokenNote: View {
    let newTokenURL: URL?
    let actions: GitLabSectionActions
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "key.fill")
                    .foregroundStyle(MergeRequestStatus.Color.orange.swiftUI)
                Text(verbatim: WriteAccess.explanation)
                    .textSelection(.enabled)
            }
            Text("Create one in GitLab, then paste it in Settings → Accounts: it replaces the stored token.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if let newTokenURL {
                    Button("Create Token…") { actions.open(newTokenURL) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Open Accounts") { actions.openSettings(.accounts) }
                    .buttonStyle(.bordered)
                Button("Not Now", action: dismiss)
                    .buttonStyle(.link)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}
