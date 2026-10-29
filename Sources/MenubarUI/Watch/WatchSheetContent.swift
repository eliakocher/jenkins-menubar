import AppKit
import MenubarCore
import SwiftUI

/// What the status region under the Watch a Build… field shows (`docs/design/watch-sheet.md`).
public enum WatchStatus: Hashable, Sendable {
    /// nothing; two lines stay reserved
    case none
    /// Jenkins is asked to confirm the job: a small spinner
    case checking
    /// "Watching all builds of !2", with the job's title under it, or "Already watching all builds of !2"
    case watched(message: String, title: String?)
    /// "!1 is yours: it shows with your builds anyway" (WATCH-03)
    case yours(message: String)
    /// a refusal (WATCH-02) or a standing problem, with "Open Settings…" when a setting fixes it
    case refused(message: String, pane: SettingsPane?)

    /// Returns the status of what the store did with a text.
    ///
    /// - Parameter result: the outcome of `PipelinesStore.watch(_:)`
    public init(_ result: Result<WatchOutcome, WatchRefusal>) {
        switch result {
        case .success(let outcome):
            let title = outcome.title.flatMap { $0 == outcome.watched.label || $0.isEmpty ? nil : $0 }
            self = .watched(message: outcome.message, title: title)
        case .failure(let refusal):
            self.init(refusal)
        }
    }

    /// Returns the status of a refusal.
    ///
    /// - Parameter refusal: why the text isn't watched
    public init(_ refusal: WatchRefusal) {
        switch refusal {
        case .mine(let job):
            // Without the period: a status line, not a sentence (`watch-sheet.md`, Copy).
            self = .yours(message: "\(Build.label(forJob: job)) is yours: it shows with your builds anyway")
        case .problem(let problem):
            self = .refused(message: problem.message, pane: SettingsPane.pane(for: problem))
        case .otherJenkins(let jobURL):
            // The job URL wraps as a whole, never right after "https://".
            self = .refused(message: "That is not a link into the Jenkins job in Team, \(Self.unbroken(jobURL))", pane: nil)
        default:
            self = .refused(message: refusal.message, pane: nil)
        }
    }

    /// Returns a link that a line never breaks inside: a word joiner after each `/`, `.` and `:`.
    static func unbroken(_ link: String) -> String {
        link.reduce(into: "") { result, character in
            result.append(character)
            if "/.:".contains(character) {
                result.append("\u{2060}")
            }
        }
    }

    /// whether the field keeps its text after this outcome; a success and one of mine clear it for the next link
    public var keepsText: Bool {
        switch self {
        case .refused: true
        case .none, .checking, .watched, .yours: false
        }
    }
}

/// The Watch a Build… sheet drawn from plain values: the heading, the instruction, the field, the status region, the
/// explanation and the buttons. ``WatchSheet`` drives it from the stores; the gallery from fixtures.
public struct WatchSheetContent: View {
    @Binding var text: String
    @Binding var selection: TextSelection?
    let status: WatchStatus
    /// changes whenever the field should take the focus again, as after an outcome
    let focusRequest: Int
    /// the easter egg line under the outcome; `nil` for none
    let eggLine: String?
    let onWatch: () -> Void
    let onClose: () -> Void
    let onOpenSettings: (SettingsPane) -> Void
    /// the projects to choose from, with their names; empty with one project, which shows no picker (plan Phase 13)
    var projects: [(id: ProjectID, name: String)] = []
    /// the project a number like `!123` is watched in; a link picks its own
    var project: Binding<ProjectID> = .constant(.main)
    @FocusState private var isFieldFocused: Bool
    @ScaledMetric(relativeTo: .body) private var statusHeight: CGFloat = 34

    /// the sheet's fixed width
    public static let width: CGFloat = 480

    public init(
        text: Binding<String>, selection: Binding<TextSelection?>, status: WatchStatus, focusRequest: Int = 0,
        eggLine: String? = nil, onWatch: @escaping () -> Void, onClose: @escaping () -> Void, onOpenSettings: @escaping (SettingsPane) -> Void
    ) {
        _text = text
        _selection = selection
        self.status = status
        self.focusRequest = focusRequest
        self.eggLine = eggLine
        self.onWatch = onWatch
        self.onClose = onClose
        self.onOpenSettings = onOpenSettings
    }

    private var isChecking: Bool { status == .checking }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Watch a Build")
                .font(.headline)
            Text("Paste a link to a Jenkins build or a GitLab merge request, or type a merge request number like !123.")
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            TextField("Link or !123", text: $text, selection: $selection)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .disabled(isChecking)
                .helpWhenCut(text, width: Self.width - 40 - 10)
                .padding(.top, 8)
            if projects.count > 1 {
                Picker("Project:", selection: project) {
                    ForEach(projects, id: \.id) { project in
                        Text(verbatim: project.name).tag(project.id)
                    }
                }
                .help("A number is watched in this project; a link picks its own")
                .disabled(isChecking)
                .fixedSize()
                .padding(.top, 8)
            }
            statusRegion
                .frame(minHeight: statusHeight, alignment: .topLeading)
                .padding(.top, 6)
            Text("Watching follows every build of the merge request or branch, the later ones too, until Jenkins drops the job or you stop watching.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Watch", action: onWatch)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
            }
            .padding(.top, 20)
        }
        .padding(20)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { isFieldFocused = true }
        .onChange(of: focusRequest) { isFieldFocused = true }
    }

    /// The outcome, and under it the easter egg's line when there is one: the line follows the outcome and never
    /// replaces it (EGG-18).
    @ViewBuilder private var statusRegion: some View {
        VStack(alignment: .leading, spacing: 4) {
            outcome
            if let eggLine {
                Text(verbatim: eggLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var outcome: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch status {
            case .none:
                EmptyView()
            case .checking:
                ProgressView()
                    .controlSize(.small)
            case .watched(let message, let title):
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: message)
                        .fixedSize(horizontal: false, vertical: true)
                    if let title {
                        Text(verbatim: title)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .helpWhenCut(title, width: Self.width - 40 - 22)
                    }
                }
            case .yours(let message):
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(verbatim: message)
                    .fixedSize(horizontal: false, vertical: true)
            case .refused(let message, let pane):
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
                Text(verbatim: message)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let pane {
                    // Small, so it doesn't push the message down or the sheet taller.
                    Button("Open Settings…") { onOpenSettings(pane) }
                        .controlSize(.small)
                        .help("Opens Settings → \(pane.title)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Shows a text as the tooltip only when it is cut, measured in the body font against the width it gets
    /// (`watch-sheet.md`, Copy): an uncut text needs none.
    @ViewBuilder
    func helpWhenCut(_ text: String, width: CGFloat) -> some View {
        let font = NSFont.preferredFont(forTextStyle: .body)
        if (text as NSString).size(withAttributes: [.font: font]).width > width {
            help(text)
        } else {
            self
        }
    }
}
