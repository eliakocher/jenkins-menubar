import MenubarCore
import SwiftUI

/// The "Add a To-Do…" field at the top of My To-Dos (INBOX-16): Return adds the words as a to-do, a pasted GitLab or Jenkins
/// link or a bare `!123` becomes its reference chip. The button at its end opens the form for a note, a date and a link.
struct MyTodoAddField: View {
    let add: @MainActor (String) -> Void
    let addWithDetails: @MainActor () -> Void
    @ViewState private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .imageScale(.large)
                .foregroundStyle(text.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                .accessibilityHidden(true)
            TextField("Add a To-Do…", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(submit)
            Button {
                addWithDetails()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .accessibilityLabel("Add with Details")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Add a to-do with a note, a date and a link")
        }
        .padding(.vertical, 3)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }

    private func submit() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            return
        }
        add(words)
        text = ""
        // Ready for the next one.
        isFocused = true
    }
}

/// What the to-do form edits: a new to-do, or one that exists.
enum MyTodoSheetTarget: Identifiable, Hashable {
    case new
    case edit(MyTodo)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let todo): todo.id
        }
    }
}

/// The small form of a to-do (INBOX-16): the title, a note, an optional due date, and an optional link that becomes the
/// reference chip and opens in the app.
struct MyTodoSheet: View {
    let target: MyTodoSheetTarget
    let parseLink: @MainActor (String) -> MyTodoLink?
    let save: @MainActor (MyTodoDraft) -> Void
    let cancel: @MainActor () -> Void
    @ViewState private var title: String
    @ViewState private var note: String
    @ViewState private var hasDueDate: Bool
    @ViewState private var dueDate: Date
    @ViewState private var linkText: String
    @FocusState private var titleFocused: Bool

    init(
        target: MyTodoSheetTarget, parseLink: @escaping @MainActor (String) -> MyTodoLink?,
        save: @escaping @MainActor (MyTodoDraft) -> Void, cancel: @escaping @MainActor () -> Void
    ) {
        self.target = target
        self.parseLink = parseLink
        self.save = save
        self.cancel = cancel
        var existing: MyTodo?
        if case .edit(let todo) = target {
            existing = todo
        }
        _title = ViewState(initialValue: existing?.title ?? "")
        _note = ViewState(initialValue: existing?.note ?? "")
        _hasDueDate = ViewState(initialValue: existing?.dueDate != nil)
        _dueDate = ViewState(initialValue: existing?.dueDate ?? Calendar.current.startOfDay(for: .now).addingTimeInterval(86400))
        _linkText = ViewState(initialValue: existing?.link?.url.absoluteString ?? "")
    }

    private var isNew: Bool {
        if case .new = target { true } else { false }
    }

    /// what the link field holds, read: `nil` for an empty or unreadable field
    private var link: MyTodoLink? {
        let words = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : parseLink(words)
    }

    private var linkIsUnreadable: Bool {
        !linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && link == nil
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !linkIsUnreadable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New To-Do" : "Edit To-Do")
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                TextField("Title", text: $title)
                    .focused($titleFocused)
                TextField("Note", text: $note, axis: .vertical)
                    .lineLimit(2...5)
                HStack {
                    Toggle("Due", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                            .labelsHidden()
                    }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Link, like a GitLab or Jenkins page, or !123", text: $linkText)
                    linkNote
                }
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { titleFocused = true }
    }

    @ViewBuilder
    private var linkNote: some View {
        if let link {
            HStack(spacing: 6) {
                if let reference = link.reference, let sign = reference.lastIndex(where: { $0 == "!" || $0 == "#" }) {
                    let text = String(reference[sign...])
                    ReferenceChip(kind: text.hasPrefix("!") ? .mergeRequest : .workItem, text: text)
                }
                Text(verbatim: link.defaultTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if linkIsUnreadable {
            Label("That isn't a link, and !123 needs a project in Settings → Team.", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    private func submit() {
        guard canSave else {
            return
        }
        save(
            MyTodoDraft(
                title: title, note: note, dueDate: hasDueDate ? Calendar.current.startOfDay(for: dueDate) : nil, link: link))
    }
}
