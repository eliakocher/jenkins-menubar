import MenubarCore
import SwiftUI

/// What the user typed to start work: a work item's number, and a title for the branch name when the app doesn't know the
/// item (WS-08).
struct StartWorkDraft: Hashable, Sendable {
    /// the search or the number, like `fix login` or `#1234`
    var query = ""
    /// the title for the branch name, asked for only when the number is none of the known items
    var title = ""

    /// the number the query names: only digits, with an optional `#`; `nil` for a search
    var number: Int? {
        let text = query.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }
        guard !text.isEmpty, text.count <= 9, text.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(text), number > 0 else {
            return nil
        }
        return number
    }

    /// Returns the known work item the number names.
    func item(in items: [StartWorkItem]) -> StartWorkItem? {
        number.flatMap { number in items.first { $0.number == number } }
    }

    /// Returns the known items the query searches, by number or title; none while the number is an item's.
    func matches(in items: [StartWorkItem], limit: Int = 5) -> [StartWorkItem] {
        let text = query.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }
        guard !text.isEmpty, item(in: items) == nil else {
            return []
        }
        let found = items.filter { item in
            String(item.number).hasPrefix(text) || item.title.localizedCaseInsensitiveContains(text)
        }
        return Array(found.prefix(limit))
    }

    /// Returns the branch name: the number, then the known item's title, else the typed one.
    func branch(in items: [StartWorkItem]) -> String? {
        guard let number else {
            return nil
        }
        return BranchSlug.name(number: number, title: item(in: items)?.title ?? title)
    }
}

/// The detail's "Start Work Here" section, for a free checkout only (WS-08): the work item, the branch it names, and an
/// inline confirmation that says which checkout and which branch before anything runs.
struct StartWorkSection: View {
    let checkout: Checkout
    let items: [StartWorkItem]
    let isRunning: Bool
    let start: (String) -> Void
    @ViewState private var draft = StartWorkDraft()
    @ViewState private var isConfirming = false

    var body: some View {
        let branch = draft.branch(in: items)
        let known = draft.item(in: items)
        Section {
            TextField("Work item", text: $draft.query, prompt: Text("Search your work items or type a number"))
                .disabled(isRunning)
                .onSubmit { confirmIfReady(branch) }
            ForEach(draft.matches(in: items)) { item in
                Button {
                    draft.query = String(item.number)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "#\(item.number)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(verbatim: item.title)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.reference)
            }
            if draft.number != nil, known == nil {
                TextField("Title", text: $draft.title, prompt: Text("For the branch name; the app doesn't know item #\(draft.number ?? 0)"))
                    .disabled(isRunning)
            }
            if let branch {
                LabeledContent("Branch") {
                    Text(verbatim: branch)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if isConfirming || isRunning {
                    confirmation(branch)
                } else {
                    Button("Start Work…") { isConfirming = true }
                        .buttonStyle(.bordered)
                }
            }
        } header: {
            Text("Start Work Here")
        } footer: {
            Text("Starts a branch named after a work item from the latest origin/\(checkout.baseBranch). It only runs after your confirmation.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: branch) {
            // Another branch name is another question.
            isConfirming = false
        }
    }

    /// Names the checkout and the branch, and the two git commands, before anything runs.
    private func confirmation(_ branch: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "In \(checkout.name), this runs git fetch origin \(checkout.baseBranch), then creates \(branch) from origin/\(checkout.baseBranch) and switches to it. No file is changed, and it stops if the checkout isn't clean.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    isConfirming = false
                    start(branch)
                } label: {
                    HStack(spacing: 6) {
                        if isRunning {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(verbatim: "Start Work in \(checkout.name)")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
                Button("Cancel") { isConfirming = false }
                    .buttonStyle(.bordered)
                    .disabled(isRunning)
            }
        }
    }

    private func confirmIfReady(_ branch: String?) {
        if branch != nil {
            isConfirming = true
        }
    }
}
