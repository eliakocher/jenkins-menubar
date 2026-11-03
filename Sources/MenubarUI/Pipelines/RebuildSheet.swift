import MenubarCore
import SwiftUI

/// The sheet of "Rebuild with Changes…" (PIPE-09): the job's parameters, filled with the build's values and editable by
/// their Jenkins types, a boolean as a toggle, a choice as a picker, a string or text as a field, a password as a
/// secure field that shows nothing. Nothing is written until "Rebuild" is clicked.
///
/// The form loads from Jenkins when the sheet opens, as skeleton rows; a failure says why, with Try Again. A password
/// stays empty, and a password left empty isn't sent, so Jenkins keeps the job's default as "Rebuild Identically"
/// does; the secure field says so. The values go nowhere but the one request: the log names none of them.
struct RebuildSheet: View {
    /// the build, like `!1 #7`, which the subtitle names
    let build: String
    /// asks Jenkins for the form
    let load: @MainActor () async -> Result<RebuildForm, JenkinsRebuildError>
    /// starts the rebuild with the edited form; the sheet closes after
    let rebuild: @MainActor (RebuildForm) -> Void
    /// closes the sheet without rebuilding
    let close: @MainActor () -> Void

    @ViewState private var form: RebuildForm?
    @ViewState private var failure: String?
    @ViewState private var attempt = 0

    /// - Parameters:
    ///   - build: the build, like `!1 #7`
    ///   - form: a form to show at once, without asking Jenkins; the gallery's
    ///   - load: asks Jenkins for the form
    ///   - rebuild: starts the rebuild with the edited form
    ///   - close: closes the sheet
    init(
        build: String, form: RebuildForm? = nil,
        load: @escaping @MainActor () async -> Result<RebuildForm, JenkinsRebuildError>,
        rebuild: @escaping @MainActor (RebuildForm) -> Void, close: @escaping @MainActor () -> Void
    ) {
        self.build = build
        self.load = load
        self.rebuild = rebuild
        self.close = close
        _form = ViewState(initialValue: form)
    }

    static let width: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
            content
            buttons
                .padding(20)
        }
        .frame(width: Self.width)
        .task(id: attempt) {
            guard form == nil else { return }
            failure = nil
            switch await load() {
            case .success(let loaded): form = loaded
            case .failure(let error): failure = error.message
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Rebuild with Changes")
                .font(.headline)
            Text(verbatim: "Starts \(build) again with the values below. Nothing changes until you click Rebuild.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var content: some View {
        if let form {
            if form.fields.isEmpty {
                Text(form.isParameterized
                    ? "This job's parameters can't be edited here: Jenkins keeps their defaults."
                    : "This job has no parameters, so there is nothing to change.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                fields(form)
            }
        } else if let failure {
            VStack(alignment: .leading, spacing: 8) {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { attempt += 1 }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 10) {
                SkeletonRows(count: 4, leading: .none, lines: 2)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
    }

    private func fields(_ form: RebuildForm) -> some View {
        Form {
            Section {
                ForEach(Array(form.fields.indices), id: \.self) { index in
                    row(index)
                }
            } footer: {
                if !form.skipped.isEmpty {
                    Text(verbatim: "Jenkins keeps the defaults of \(form.skipped.formatted(.list(type: .and))): they can't be edited here.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func row(_ index: Int) -> some View {
        if let field = form?.fields[safe: index] {
            let binding = value(index)
            VStack(alignment: .leading, spacing: 4) {
                switch field.definition.kind {
                case .boolean:
                    Toggle(isOn: Binding(get: { binding.wrappedValue == "true" }, set: { binding.wrappedValue = $0 ? "true" : "false" })) {
                        Text(verbatim: field.definition.name)
                    }
                case .choice:
                    Picker(selection: binding) {
                        ForEach(field.definition.choices, id: \.self) { choice in
                            Text(verbatim: choice.isEmpty ? "(empty)" : choice).tag(choice)
                        }
                    } label: {
                        Text(verbatim: field.definition.name)
                    }
                case .text:
                    LabeledContent {
                        TextField(text: binding, axis: .vertical) { EmptyView() }
                            .lineLimit(2...6)
                            .multilineTextAlignment(.leading)
                    } label: {
                        Text(verbatim: field.definition.name)
                    }
                case .password:
                    SecureField(text: binding, prompt: Text("Leave empty to keep the job's default")) {
                        Text(verbatim: field.definition.name)
                    }
                    .textContentType(.password)
                    .autocorrectionDisabled()
                default:
                    TextField(text: binding, prompt: Text(verbatim: field.definition.defaultValue ?? "")) {
                        Text(verbatim: field.definition.name)
                    }
                }
                if let details = field.definition.details {
                    Text(verbatim: details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// the value of one field, which writes into the form
    private func value(_ index: Int) -> Binding<String> {
        Binding(
            get: { self.form?.fields[safe: index]?.value ?? "" },
            set: { newValue in
                if var edited = self.form, edited.fields.indices.contains(index) {
                    edited.fields[index].value = newValue
                    self.form = edited
                }
            })
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
            Button("Rebuild") {
                if let form {
                    rebuild(form)
                }
                close()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(form == nil)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// "Rebuild" as a button with an arrow: the button starts the job again with the build's parameters, the
/// arrow's menu offers that and "Rebuild with Changes…" (the user, 2026-11-03). It shows as the bordered button of the
/// action rows, or full width in the alert.
struct RebuildSplitButton: View {
    /// whether the button is disabled, while a rebuild of the job is under way
    var isDisabled = false
    let identically: () -> Void
    let withChanges: () -> Void

    var body: some View {
        Menu {
            Button("Rebuild Identically", systemImage: "arrow.clockwise", action: identically)
            Button("Rebuild with Changes…", systemImage: "slider.horizontal.3", action: withChanges)
        } label: {
            // Plain "Rebuild" on the button; the menu names both ways (the user, 2026-11-03).
            Label("Rebuild", systemImage: "arrow.clockwise")
        } primaryAction: {
            identically()
        }
        .menuStyle(.button)
        .help("Starts the job again with this build's parameters; the arrow offers to change them first")
        .disabled(isDisabled)
    }
}
