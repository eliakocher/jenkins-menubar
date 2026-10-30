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

/// The merge request detail's Reviewers card: each reviewer as a chip with their review's glyph, me with a quiet ring;
/// a review older than the last push in orange, with "Re-request Review" (↻) on the chip, which shows on hover for the
/// other reviews and is in the chip's context menu; "Re-request (N)" in the card's headline for the stale ones, which
/// confirms once (MR-09, MR-10).
///
/// The first write of the app: nothing is sent without a click, and nothing again after a failure. A token without the
/// `api` scope gets the explanation, from what GitLab says of the token before the click, else from its refusal.
struct ReviewersCard: View {
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
        let stale = reviews.map { reviews in reviews.reviewers.filter { reviews.nudge(for: $0) != nil } } ?? []
        DetailCard("Reviewers", symbol: "person.2") {
            VStack(alignment: .leading, spacing: 10) {
                if currentPhase == .confirming, toAsk.count >= 2 {
                    confirmation(toAsk)
                }
                if model.reviewers.isEmpty {
                    Text(verbatim: MergeRequestDetailModel.noReviewers)
                        .foregroundStyle(.secondary)
                } else {
                    PillFlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(model.reviewers) { row in
                            let reviewer = reviews?.reviewers.first { $0.username == row.id }
                            ReviewerChip(
                                row: row, reviewer: reviewer, nudge: reviewer.flatMap { reviews?.nudge(for: $0) },
                                phase: currentPhase, isBusy: isBusy
                            ) { reviewer in
                                start([reviewer])
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !stale.isEmpty {
                    Label {
                        Text(verbatim: Self.staleText(stale))
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .font(.callout)
                    .foregroundStyle(MergeRequestStatus.Color.orange.swiftUI)
                    .fixedSize(horizontal: false, vertical: true)
                }
                feedback
            }
        } accessory: {
            if toAsk.count >= 2, currentPhase != .confirming {
                Button {
                    // A token that can't write is told at the first click, before a question about asking anyone.
                    phase = writeAccess == .readOnly ? .needsToken : .confirming
                } label: {
                    Label("Re-request (\(toAsk.count))", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy)
                .help("Ask the reviewers whose review is older than the last push to review again")
            }
        }
        .task(id: Check(id: model.mergeRequest.id, hasReviewers: reviews?.reviewers.contains(where: \.hasReviewed) == true)) {
            await checkToken()
        }
    }

    /// "Sam's review is older than the last push", "Sam, Pat and Chris reviewed before the last push"
    static func staleText(_ stale: [MergeRequestReviews.Reviewer]) -> String {
        let names = stale.map(\.firstName)
        if names.count == 1 {
            return "\(names[0].hasSuffix("s") ? "\(names[0])'" : "\(names[0])'s") review is older than the last push"
        }
        let listed = names.count <= 3
            ? names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
            : names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) others"
        return "\(listed) reviewed before the last push"
    }

    // MARK: Bulk

    /// The question the bulk action asks once.
    private func confirmation(_ toAsk: [MergeRequestReviews.Reviewer]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: MergeRequestReviews.confirmation(for: toAsk))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Re-request Reviews") { start(toAsk) }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { phase = .idle }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

/// A reviewer as a chip: the avatar with the review's glyph, the name and the state's word; ↻ where a review was given,
/// always in orange where it is stale, else on hover; a spinner while the request is on its way.
private struct ReviewerChip: View {
    let row: MergeRequestDetailModel.ReviewerRow
    let reviewer: MergeRequestReviews.Reviewer?
    /// "2 new commits since Sam's review" where the review is stale
    let nudge: String?
    let phase: ReReviewPhase
    let isBusy: Bool
    let reRequest: (MergeRequestReviews.Reviewer) -> Void

    @ViewState private var isHovered = false

    /// The row as GitLab's newest answer has it, which a re-request changes before the list reloads.
    private var current: MergeRequestDetailModel.ReviewerRow {
        guard let reviewer else {
            return row
        }
        var row = row
        (row.word, row.mark) = MergeRequestDetailModel.ReviewerRow.describe(state: reviewer.reviewState, approved: reviewer.approved)
        row.state = reviewer.reviewState
        return row
    }

    private var isSending: Bool {
        if case .sending(let who) = phase, who.contains(row.id) { true } else { false }
    }

    var body: some View {
        let current = current
        let orange = MergeRequestStatus.Color.orange.swiftUI
        let isStale = nudge != nil
        let glyph = Self.glyph(current)
        HStack(spacing: 7) {
            InitialsAvatar(name: row.name, username: row.id, size: 24, isMe: row.isMe)
                .overlay(alignment: .bottomTrailing) {
                    if let glyph {
                        Image(systemName: glyph.symbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white, glyph.color)
                            .background(Circle().fill(.background).padding(-1.5))
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: Self.shownName(row))
                    .font(.callout.weight(row.isMe ? .semibold : .regular))
                    .lineLimit(1)
                Text(verbatim: isStale ? "\(current.word) · outdated" : current.word)
                    .font(.caption)
                    .foregroundStyle(isStale ? AnyShapeStyle(orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            if let reviewer, reviewer.hasReviewed {
                button(reviewer, isStale: isStale)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(isStale ? AnyShapeStyle(orange.opacity(0.10)) : AnyShapeStyle(.fill.quaternary), in: Capsule())
        .overlay {
            Capsule().strokeBorder(isStale ? orange.opacity(0.45) : .clear, lineWidth: 0.75)
        }
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
        .help(nudge ?? "\(Self.shownName(row)): \(current.word)")
        .contextMenu {
            if let reviewer, reviewer.hasReviewed {
                Button("Re-request Review") { reRequest(reviewer) }
                    .disabled(isBusy)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// ↻ in orange where the review is stale, else in the label's color while hovered; a spinner while it is sent. It
    /// keeps its room when hidden, so a chip doesn't change its width on hover.
    @ViewBuilder
    private func button(_ reviewer: MergeRequestReviews.Reviewer, isStale: Bool) -> some View {
        if isSending {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14)
        } else {
            Button { reRequest(reviewer) } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.bold))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isStale ? AnyShapeStyle(MergeRequestStatus.Color.orange.swiftUI) : AnyShapeStyle(.secondary))
            .opacity(isStale || isHovered ? 1 : 0)
            .disabled(isBusy)
            .help("Re-request review from \(reviewer.displayName)")
            .accessibilityLabel("Re-request Review")
        }
    }

    /// the name without "(me)", which the ring says
    private static func shownName(_ row: MergeRequestDetailModel.ReviewerRow) -> String {
        row.isMe && row.name.hasSuffix(" (me)") ? String(row.name.dropLast(5)) : row.name
    }

    /// The review's glyph on the avatar: approved, requested changes, commented, started; none while not reviewed.
    private static func glyph(_ row: MergeRequestDetailModel.ReviewerRow) -> (symbol: String, color: Color)? {
        switch row.mark {
        case .approved:
            return ("checkmark.circle.fill", MergeRequestStatus.Color.green.swiftUI)
        case .requestedChanges:
            return ("exclamationmark.circle.fill", MergeRequestStatus.Color.orange.swiftUI)
        case nil:
            switch row.state {
            case .reviewed: return ("text.bubble.fill", MergeRequestStatus.Color.blue.swiftUI)
            case .reviewStarted: return ("ellipsis.circle.fill", MergeRequestStatus.Color.neutral.swiftUI)
            default: return nil
            }
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
