import MenubarCore
import SwiftUI

/// File › Open by Link… (⌘⇧O, WIN-06): a small field for a GitLab merge request or work item link, or `group/project!123`
/// and `#123`. A good one opens in its list or under "Opened"; a bad one says why under the field.
struct OpenByLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @ViewState private var text = ""
    @ViewState private var refusal: OpenByLink.Refusal?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open by Link")
                .font(.headline)
            TextField("Link or group/project!123", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(open)
                .onChange(of: text) { refusal = nil }
            Text(verbatim: refusal?.message ?? "A merge request or work item of your GitLab, or !123 and #123 for your project.")
                .font(.callout)
                .foregroundStyle(refusal == nil ? .secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { router.isOpeningByLink = false }
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: open)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { isFocused = true }
    }

    private func open() {
        let team = model.team
        switch OpenByLink.parse(
            text, projects: team.projects(), defaultProject: team.primaryProject().team.gitLabProject)
        {
        case .failure(let reason):
            refusal = reason
        case .success(let route):
            guard let destination = model.destination(for: route, link: URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))) else {
                refusal = .notAnItem
                return
            }
            router.isOpeningByLink = false
            router.show(destination)
        }
    }
}
