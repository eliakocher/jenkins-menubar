import MenubarCore
import SwiftUI

// MARK: - The chip model

/// One suggested reviewer as the Reviewers card's chip shows them (MR-15): the person, how strong the reason is, and
/// the reason for the tooltip.
struct SuggestedReviewerChip: Hashable, Sendable, Identifiable {
    var username: String
    /// the full name, else "@username"
    var name: String
    /// the full name for the avatar's initials; empty when GitLab sent none
    var fullName: String
    /// whether an approval rule that blocks the merge needs the person, or someone else of its pool
    var isRequired: Bool
    /// the tooltip: what Add does, the strongest reason, and the other reasons
    var help: String

    var id: String { username }

    init(_ suggestion: ReviewerSuggestion) {
        username = suggestion.username
        name = suggestion.displayName
        fullName = suggestion.name
        isRequired = suggestion.isRequired
        var lines = ["Add \(suggestion.displayName) as a reviewer", suggestion.reason]
        lines += suggestion.otherReasons.map { "Also: \($0)" }
        help = lines.joined(separator: "\n")
    }
}

/// What the suggestions part of the Reviewers card shows for a merge request: the ranked chips of those who aren't on
/// it yet, and the people "Add Required Reviewers" adds (MR-15).
struct SuggestedReviewersModel: Equatable, Sendable {
    /// how many chips show before "Show More"
    static let visibleLimit = 8

    /// the people not yet reviewers, ranked: the required ones first
    var chips: [SuggestedReviewerChip]
    /// the fewest people who satisfy the open required rules and aren't reviewers yet
    var required: [SuggestedReviewerChip]
    /// what couldn't be read ("CODEOWNERS couldn't be read: …"); the chips are what the rest gave
    var notes: [String]

    /// - Parameters:
    ///   - list: the ranked suggestions
    ///   - current: the usernames that are reviewers already, in any case, also those added a moment ago
    init(_ list: ReviewerSuggestionList, current: Set<String>) {
        let taken = Set(current.map { $0.lowercased() })
        chips = list.items.filter { !taken.contains($0.username.lowercased()) }.map(SuggestedReviewerChip.init)
        required = list.minimalRequired.filter { !taken.contains($0.username.lowercased()) }.map(SuggestedReviewerChip.init)
        notes = list.notes
    }

    var isEmpty: Bool { chips.isEmpty }

    /// the chips before "Show More", or all of them
    func shown(showsAll: Bool) -> [SuggestedReviewerChip] {
        showsAll ? chips : Array(chips.prefix(Self.visibleLimit))
    }

    /// "Add Required Reviewers", with how many when it is more than one; `nil` when no rule needs anyone
    var addRequiredTitle: String? {
        switch required.count {
        case 0: nil
        case 1: "Add Required Reviewer"
        default: "Add Required Reviewers (\(required.count))"
        }
    }

    /// The question "Add Required Reviewers" asks once, when it adds more than one person.
    var requiredQuestion: String {
        "Add \(required.map(\.name).formatted(.list(type: .and))) as reviewers?"
    }

    /// "Sam Lee added as a reviewer", "Sam Lee and Pat Wu added as reviewers"
    static func addedText(_ people: [SuggestedReviewerChip]) -> String {
        let names = people.map(\.name).formatted(.list(type: .and))
        return "\(names) added as \(people.count == 1 ? "a reviewer" : "reviewers")"
    }
}

/// What the suggestions part is doing about adds.
enum SuggestionAddPhase: Equatable {
    case idle
    /// "Add Required Reviewers" asked once: "Add Sam and Pat as reviewers?"
    case confirming
    /// the adds of these usernames are on their way
    case sending(Set<String>)
    /// these were added
    case done([SuggestedReviewerChip])
    /// GitLab refused, with its words
    case failed(String)
    /// the token can't write: the explanation, with the way to a new one
    case needsToken
}

// MARK: - The section

/// The Reviewers card's "Suggested" part on my open merge requests: the people GitLab's rules, the target branch's
/// CODEOWNERS and the squad name, as chips with their avatars and the reason in the tooltip. A click on a chip adds the
/// person (`mergeRequestSetReviewers` with append); "Add Required Reviewers" adds the fewest who satisfy the open rules,
/// after one question when it is more than one. Nothing is sent without a click.
///
/// The chip moves up to the reviewers at once (``added``), and the lists load again behind it. A token without the
/// `api` scope gets the explanation, from what GitLab says of the token before the click, else from its refusal.
struct SuggestedReviewersSection: View {
    let model: MergeRequestDetailModel
    let actions: GitLabSectionActions
    /// what the token may write, as the card has it
    let writeAccess: WriteAccess
    /// the usernames that are reviewers, with those added here
    let current: Set<String>
    /// the people added here, which the card shows among the reviewers before GitLab's list has them
    @Binding var added: [SuggestedReviewerChip]

    @Environment(AppModel.self) private var appModel: AppModel?
    @Environment(\.mergeRequestDetailsFixtures) private var fixtures
    @ViewState private var phase: SuggestionAddPhase?
    @ViewState private var showsAll = false

    private var currentPhase: SuggestionAddPhase { phase ?? fixtures?.suggestionPhase ?? .idle }

    private var state: ReviewerSuggestionState? {
        fixtures?.suggestions[model.mergeRequest.reference] ?? appModel?.reviewerSuggestions.state(of: model.mergeRequest)
    }

    /// the merge request and update whose suggestions were last asked for
    private struct Ask: Hashable {
        var id: MergeRequest.ID
        var updatedAt: Date
    }

    var body: some View {
        content
            .task(id: Ask(id: model.mergeRequest.id, updatedAt: model.mergeRequest.updatedAt)) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        let phase = currentPhase
        switch state {
        case nil, .loading:
            if fixtures == nil || state == .loading {
                skeleton
            }
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "Suggestions couldn't be loaded: \(message)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Try Again") { Task { await load(force: true) } }
                    .buttonStyle(.link)
            }
        case .loaded(let list):
            let suggestions = SuggestedReviewersModel(list, current: current)
            if !suggestions.isEmpty || !isIdle(phase) {
                VStack(alignment: .leading, spacing: 8) {
                    if phase == .confirming, suggestions.required.count >= 2 {
                        confirmation(suggestions)
                    }
                    if !suggestions.isEmpty {
                        header(suggestions, phase: phase)
                        chips(suggestions, phase: phase)
                        if !suggestions.required.isEmpty {
                            Text("Tinted: an approval rule needs one of them")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(suggestions.notes, id: \.self) { note in
                        Text(verbatim: note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    feedback(phase)
                }
            }
        }
    }

    private func isIdle(_ phase: SuggestionAddPhase) -> Bool {
        if case .idle = phase { true } else { false }
    }

    // MARK: Pieces

    /// "Suggested", with "Add Required Reviewers" at the right where a rule still needs someone.
    private func header(_ suggestions: SuggestedReviewersModel, phase: SuggestionAddPhase) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Label {
                Text("Suggested")
            } icon: {
                Image(systemName: "sparkles")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let title = suggestions.addRequiredTitle, phase != .confirming {
                Button {
                    // A token that can't write is told at the first click, before a question about adding anyone.
                    if writeAccess == .readOnly {
                        self.phase = .needsToken
                    } else if suggestions.required.count >= 2 {
                        self.phase = .confirming
                    } else {
                        add(suggestions.required)
                    }
                } label: {
                    Label(title, systemImage: "person.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy(phase))
                .help("Adds the fewest people who satisfy the approval rules that still need someone")
            }
        }
    }

    private func chips(_ suggestions: SuggestedReviewersModel, phase: SuggestionAddPhase) -> some View {
        let shown = suggestions.shown(showsAll: showsAll)
        return PillFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(shown) { chip in
                SuggestedChipView(chip: chip, isSending: sending(chip, in: phase), isDisabled: isBusy(phase)) {
                    add([chip])
                }
            }
            if suggestions.chips.count > shown.count {
                Button("Show \(suggestions.chips.count - shown.count) More") { showsAll = true }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confirmation(_ suggestions: SuggestedReviewersModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: suggestions.requiredQuestion)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Add Reviewers") { add(suggestions.required) }
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

    @ViewBuilder
    private func feedback(_ phase: SuggestionAddPhase) -> some View {
        switch phase {
        case .idle, .confirming, .sending:
            EmptyView()
        case .needsToken:
            TokenNote(
                newTokenURL: model.newTokenURL, actions: actions, text: "Adding a reviewer needs a GitLab token with the api scope."
            ) { self.phase = .idle }
        case .done(let people):
            SymbolText(
                symbol: "checkmark.circle.fill", style: AnyShapeStyle(MergeRequestStatus.Color.green.swiftUI),
                text: SuggestedReviewersModel.addedText(people))
        case .failed(let message):
            SymbolText(
                symbol: "exclamationmark.triangle.fill", style: AnyShapeStyle(MergeRequestStatus.Color.red.swiftUI), text: message)
        }
    }

    /// Chips' height, so the card doesn't jump when the suggestions arrive.
    private var skeleton: some View {
        HStack(spacing: 6) {
            ForEach([112.0, 96.0, 124.0], id: \.self) { width in
                SkeletonBlock(width: width, height: 28)
            }
        }
        .skeletonShimmer(announces: false)
    }

    private func isBusy(_ phase: SuggestionAddPhase) -> Bool {
        if case .sending = phase { true } else { false }
    }

    private func sending(_ chip: SuggestedReviewerChip, in phase: SuggestionAddPhase) -> Bool {
        if case .sending(let who) = phase, who.contains(chip.username) { true } else { false }
    }

    // MARK: Actions

    /// Asks for the suggestions, and what the token may do once there is someone to add.
    private func load(force: Bool = false) async {
        guard fixtures == nil, let appModel else {
            return
        }
        await appModel.reviewerSuggestions.load(model.mergeRequest, force: force)
        if case .loaded(let list) = appModel.reviewerSuggestions.state(of: model.mergeRequest), !list.isEmpty {
            await appModel.mergeRequestDetails.checkWriteAccess()
        }
    }

    /// Adds the people after a click, unless the token is known to be unable to write; the chips move to the reviewers.
    private func add(_ people: [SuggestedReviewerChip]) {
        guard writeAccess != .readOnly else {
            phase = .needsToken
            return
        }
        guard fixtures == nil, let appModel else {
            return
        }
        phase = .sending(Set(people.map(\.username)))
        let mergeRequest = model.mergeRequest
        Task {
            let outcome = await appModel.reviewerSuggestions.add(people.map(\.username), to: mergeRequest)
            if outcome.succeeded {
                added += people.filter { person in !added.contains { $0.username == person.username } }
                phase = .done(people)
                // GitLab's lists have them now: the reviewers of the list, and the reviews of the details.
                appModel.reloadList(.mergeRequests)
                await appModel.mergeRequestDetails.load(mergeRequest, force: true)
            } else {
                // What GitLab said of the token isn't known to be wrong, so its refusal gets the same explanation.
                phase = outcome.needsToken && appModel.mergeRequestDetails.writeAccess != .allowed
                    ? .needsToken : .failed(outcome.failure ?? "GitLab didn't add the reviewers")
            }
        }
    }
}

// MARK: - A suggested chip

/// The avatar and the name of a suggested person, with a plus: a click adds them. A required one is tinted in the accent
/// color and has a solid border, the others a dashed one. The reason is the tooltip.
private struct SuggestedChipView: View {
    let chip: SuggestedReviewerChip
    let isSending: Bool
    let isDisabled: Bool
    let add: () -> Void

    @ViewState private var isHovered = false

    var body: some View {
        // Not orange: that is the outdated review's color next to these chips.
        let tint = Color.accentColor
        Button(action: add) {
            HStack(spacing: 7) {
                InitialsAvatar(name: chip.fullName, username: chip.username, size: 24)
                Text(verbatim: chip.name)
                    .font(.callout)
                    .lineLimit(1)
                if isSending {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 14)
                } else {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .frame(width: 14)
                        .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 9)
            .padding(.vertical, 4)
            .background(chip.isRequired ? AnyShapeStyle(tint.opacity(0.12)) : AnyShapeStyle(.fill.quaternary), in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    chip.isRequired ? tint.opacity(0.5) : Color.secondary.opacity(isHovered ? 0.5 : 0.25),
                    style: StrokeStyle(lineWidth: 0.75, dash: chip.isRequired ? [] : [3, 2]))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .help(chip.help)
        .accessibilityLabel("Add \(chip.name) as a reviewer")
    }
}
