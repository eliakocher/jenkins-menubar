import MenubarCore
import SwiftUI

/// The sheet of Import from a Link… and From a File… (TEAM-02), in two stages: the link, then the preview of what the
/// team file would change. A file chosen on disk starts at the preview. Nothing is applied before the click on Apply,
/// and a changed server host only after the user trusted it by name. This is the stateful part: it fetches and applies
/// through the settings store; ``TeamFileLinkContent`` draws.
struct TeamFileLinkSheet: View {
    /// What opens the sheet: a link to prefill, and whether to fetch it at once (an import link from outside does).
    struct Request: Identifiable {
        let id = UUID()
        var link: String
        var fetchesAtOnce: Bool
        /// a team file read from disk, whose preview shows at once
        var file: PreviewedFile?
    }

    /// A team file chosen on disk, read but not applied.
    struct PreviewedFile {
        /// the file's name, which the preview and the log name as the source
        var name: String
        var preview: TeamFileImport.Preview
    }

    @Environment(SettingsStore.self) private var settings
    /// called after the team values were applied, with the host they came from
    let onApplied: (String) -> Void
    let onCancel: () -> Void
    @ViewState private var link: String
    @ViewState private var fetchNumber: Int
    @ViewState private var isFetching = false
    @ViewState private var error: String?
    @ViewState private var preview: TeamFileImport.Preview?
    /// the link the preview came from
    @ViewState private var previewedLink: URL?
    /// the file the preview came from; there is no link then
    private let file: PreviewedFile?
    @ViewState private var confirmed: Set<String> = []
    @ViewState private var applyError: String?

    init(request: Request, onApplied: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _link = ViewState(initialValue: request.link)
        _fetchNumber = ViewState(initialValue: request.fetchesAtOnce ? 1 : 0)
        _preview = ViewState(initialValue: request.file?.preview)
        file = request.file
        self.onApplied = onApplied
        self.onCancel = onCancel
    }

    var body: some View {
        TeamFileLinkContent(
            link: $link, isFetching: isFetching, error: error, preview: preview, source: file?.name ?? previewedLink?.host(),
            confirmed: $confirmed, applyError: applyError, canGoBack: file == nil,
            onFetch: { fetchNumber += 1 },
            onBack: {
                preview = nil
                confirmed = []
                applyError = nil
            },
            onCancel: onCancel, onApply: apply)
            .task(id: fetchNumber) {
                await fetch()
            }
    }

    private func fetch() async {
        guard fetchNumber > 0 else { return }
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = TeamFileImport.FetchError.notHTTPS.message
            return
        }
        isFetching = true
        error = nil
        applyError = nil
        do throws(TeamFileImport.FetchError) {
            let fetched = try await settings.previewTeamFile(at: url)
            guard !Task.isCancelled else { return }
            preview = fetched
            previewedLink = url
            confirmed = []
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.message
        }
        isFetching = false
    }

    private func apply() {
        guard let preview else { return }
        do {
            let applied: Bool
            let source: String
            if let file {
                source = file.name
                applied = try settings.applyTeamFile(preview, fromFile: file.name, confirmedHosts: confirmed)
            } else if let previewedLink {
                source = previewedLink.host() ?? "a link"
                applied = try settings.applyTeamFile(preview, from: previewedLink, confirmedHosts: confirmed)
            } else {
                return
            }
            if applied {
                onApplied(source)
            } else {
                applyError = "Trust the new servers first, then apply"
            }
        } catch {
            applyError = "The team values could not be saved: \(error.localizedDescription)"
        }
    }
}

/// The sheet's content from values and closures: the link stage, or the preview stage once there is a ``preview``.
struct TeamFileLinkContent: View {
    @Binding var link: String
    var isFetching = false
    /// why the fetch failed, under the link
    var error: String?
    var preview: TeamFileImport.Preview?
    /// the host the preview came from
    var source: String?
    /// the new hosts the user trusts
    @Binding var confirmed: Set<String>
    var applyError: String?
    /// whether the preview has a link stage to go back to; a file from disk has none
    var canGoBack = true
    var onFetch: () -> Void = {}
    var onBack: () -> Void = {}
    var onCancel: () -> Void = {}
    var onApply: () -> Void = {}
    @FocusState private var linkFocused: Bool

    /// the sheet's height: the link stage is short, the preview grows with its rows up to a limit
    nonisolated static func height(preview: TeamFileImport.Preview?) -> CGFloat {
        guard let preview else { return 250 }
        if preview.changes.isEmpty { return 200 }
        let rows = CGFloat(preview.changes.count) * 56 + CGFloat(preview.hostChanges.count) * 138
        return min(max(rows + 180, 300), 640)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let preview {
                previewStage(preview)
            } else {
                linkStage
            }
        }
        .frame(width: 560, height: Self.height(preview: preview))
    }

    // MARK: - Link stage

    private var linkStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from a Link")
                .font(.title3.weight(.semibold))
            Text("Paste the link to your team's file. You see what it changes before anything is saved.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Link", text: $link, prompt: Text("https://…"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($linkFocused)
                .onSubmit(onFetch)
                .disabled(isFetching)
                .task {
                    linkFocused = true
                }
            if isFetching {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching the team file…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let error {
                StatusLine(.problem, error)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Fetch", action: onFetch)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isFetching || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: - Preview stage

    private func previewStage(_ preview: TeamFileImport.Preview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(preview.changes.isEmpty ? "Nothing to import" : Self.count(preview.changes.count))
                    .font(.title3.weight(.semibold))
                if let source {
                    Text(verbatim: "From \(source)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 4)
            if preview.changes.isEmpty {
                StatusLine(.ok, "Your values already match this team file")
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(preview.hostChanges, id: \.key) { change in
                            hostCard(change)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(preview.changes.enumerated()), id: \.element.key) { index, change in
                                if index > 0 {
                                    Divider()
                                }
                                ChangeRow(change: change)
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
            if let applyError {
                StatusLine(.problem, applyError)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
            }
            HStack {
                if !preview.changes.isEmpty && canGoBack {
                    Button("Back", action: onBack)
                }
                Spacer()
                if preview.changes.isEmpty {
                    Button("Done", action: onCancel)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Apply", action: onApply)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!preview.canApply(confirmedHosts: confirmed))
                }
            }
            .padding(20)
        }
    }

    /// "1 value changes", "3 values change"
    static func count(_ number: Int) -> String {
        number == 1 ? "1 value changes" : "\(number) values change"
    }

    /// A server whose host changes, red-tinted: the tokens would follow it, so the user trusts it by name.
    private func hostCard(_ change: TeamFileImport.Preview.HostChange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(Self.title(of: change))
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Text(Self.warning(of: change))
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: Binding(
                get: { confirmed.contains(change.new) },
                set: { isOn in
                    if isOn {
                        confirmed.insert(change.new)
                    } else {
                        confirmed.remove(change.new)
                    }
                }
            )) {
                Text(verbatim: "I trust \(change.new)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.35)))
    }

    /// "New GitLab server" or "New Jenkins server"
    static func title(of change: TeamFileImport.Preview.HostChange) -> String {
        change.key == .gitLabURL ? "New GitLab server" : "New Jenkins server"
    }

    /// "Your tokens would go to **new** instead of old. Continue only if your team really moved to it." Built from
    /// runs, not Markdown, so a host never reads as formatting.
    static func warning(of change: TeamFileImport.Preview.HostChange) -> AttributedString {
        var text = AttributedString("Your tokens would go to ")
        var new = AttributedString(change.new)
        new.inlinePresentationIntent = .stronglyEmphasized
        text.append(new)
        text.append(AttributedString(change.old.map { " instead of \($0)" } ?? ""))
        text.append(AttributedString(". Continue only if your team really moved to it."))
        return text
    }
}

/// One changed value: its name, then `old → new`, each on one line that truncates in the middle, with the whole value
/// as the tooltip.
private struct ChangeRow: View {
    let change: TeamFileImport.Preview.Change

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(TeamValueFields.label(of: change.key))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                value(change.old)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("becomes")
                value(change.new, isNew: true)
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func value(_ text: String, isNew: Bool = false) -> some View {
        if text.isEmpty {
            Text("(empty)")
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(verbatim: text)
                .foregroundStyle(isNew ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(text)
        }
    }
}
