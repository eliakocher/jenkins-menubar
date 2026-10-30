import AppKit
import MenubarCore
import SwiftUI

/// The merge request detail's Changes card (MR-11), read only: the changed files with their kind, path and +/−, each
/// unfolding to its unified diff with both line numbers. Small merge requests start unfolded; generated files and big
/// diffs start folded. From six files a header per folder, folded when there are several folders; many files get a
/// filter. Expand All and Collapse All work on the folders, and the Diffs menu on the files. "Open in IDE" opens a file where a checkout
/// has the merge request's branch (Workspaces).
///
/// Nothing loads on selection: until the card scrolls into view it shows the totals the list of merge requests has.
/// Then GitLab's list of paths and the first page of diffs load, and every other page when one of its files shows or
/// unfolds (`AppModel.mergeRequestChanges`, or the gallery's fixtures).
struct ChangesCard: View {
    let mergeRequest: MergeRequest
    /// GitLab's Changes tab of the merge request
    let changesURL: URL
    let actions: GitLabSectionActions
    /// the folders that start unfolded although the others fold, for the gallery
    var unfoldedFolders: Set<String> = []

    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.mergeRequestDetailsFixtures) private var fixtures
    /// the files the user folded or unfolded, by id, over the defaults
    @ViewState private var toggled: [String: Bool] = [:]
    /// the folders the user folded or unfolded, by path, over the defaults
    @ViewState private var toggledFolders: [String: Bool] = [:]
    @ViewState private var filter = ""
    /// how many diffs Expand All Diffs would open, while it asks first
    @ViewState private var confirmingExpand: Int?
    /// whether the card is in the scroll view's visible part
    @ViewState private var isVisible = false
    /// inline or side by side, kept between launches
    @AppStorage("mergeRequestDiffLayout") private var layout: DiffLayoutChoice = .inline
    /// opens "Ask Claude" about lines or a file (AI-07); `nil` while the Claude features are off
    @Environment(\.askClaudeAboutCode) private var askClaude
    /// the lines picked by their numbers, in one file, for "Ask Claude About Lines…" (AI-07)
    @ViewState private var selection: DiffSelection?
    /// the file whose code is selected by dragging (AI-07); one at a time
    @ViewState private var textPickPath: String?

    /// a merge request with at most this many files starts with its small diffs unfolded
    private static let unfoldedFiles = 8
    /// from this many files the filter shows
    private static let filterFrom = 12
    /// Expand All Diffs on more files than this asks first: every page of diffs comes from GitLab
    private static let expandWithoutAsking = 50

    private var state: MergeRequestChangesState {
        fixtures?.changes[mergeRequest.reference] ?? model?.mergeRequestChanges.state(of: mergeRequest) ?? .loading
    }

    var body: some View {
        let state = state
        DetailCard("Changes", symbol: "plus.forwardslash.minus", width: .fullWidth) {
            Group {
                if let changes = state.changes {
                    files(changes, isLoadingDiffs: state.isLoadingDiffs)
                } else if state.failed {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("The changes couldn't be loaded")
                            .foregroundStyle(.secondary)
                        Button("Try Again") { open() }
                            .buttonStyle(.link)
                    }
                } else {
                    totals
                }
            }
        } accessory: {
            accessory(state.changes)
        }
        // Selecting asks nothing, but stops the requests of the merge request before.
        .task(id: mergeRequest.id) {
            if fixtures == nil {
                model?.mergeRequestChanges.select(mergeRequest)
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            isVisible = visible
            if visible {
                open()
            }
        }
        .onChange(of: mergeRequest.updatedAt) {
            if isVisible {
                open()
            }
        }
        .confirmationDialog(
            "Expand \(confirmingExpand ?? 0) Diffs?", isPresented: Binding(get: { confirmingExpand != nil }, set: { if !$0 { confirmingExpand = nil } }),
            titleVisibility: .visible
        ) {
            Button("Expand Diffs") {
                if let changes = state.changes {
                    setDiffs(unfolded: true, in: changes)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The diffs load from GitLab, a page at a time, as they scroll into view.")
        }
        // The modifiers above wrap the card, which hides the card's own width from the page's layout.
        .layoutValue(key: DetailCardWidthKey.self, value: .fullWidth)
    }

    /// Before the files come: the totals the list of merge requests has, and skeleton rows where the files go.
    private var totals: some View {
        VStack(alignment: .leading, spacing: 10) {
            totalsLine
            if isVisible || fixtures != nil {
                VStack(alignment: .leading, spacing: 0) {
                    SkeletonRows(count: 4, leading: .symbol(column: 16), lines: 1, spacing: 8, titleLine: 24)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var totalsLine: some View {
        HStack(spacing: 8) {
            if let stats = mergeRequest.diffStats {
                HStack(spacing: 4) {
                    Text(verbatim: "+\(String(stats.additions))")
                        .foregroundStyle(MergeRequestStatus.Color.green.swiftUI)
                    Text(verbatim: "−\(String(stats.deletions))")
                        .foregroundStyle(MergeRequestStatus.Color.red.swiftUI)
                    Text(verbatim: "in \(String(stats.fileCount)) \(stats.fileCount == 1 ? "file" : "files")")
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
            if !(isVisible || fixtures != nil) {
                // Scrolling the card into view loads it; the link is there should the scroll view not say so.
                Button("Show Files") { open() }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accessory(_ changes: MergeRequestChanges?) -> some View {
        HStack(spacing: 10) {
            Picker("Layout", selection: $layout) {
                Image(systemName: "rectangle.split.1x2")
                    .help("Inline")
                    .accessibilityLabel("Inline")
                    .tag(DiffLayoutChoice.inline)
                Image(systemName: "rectangle.split.2x1")
                    .help("Side by Side")
                    .accessibilityLabel("Side by Side")
                    .tag(DiffLayoutChoice.sideBySide)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .help("Inline or side by side")
            if let changes, !changes.files.isEmpty, !changes.isListOnly {
                let folders = ChangesOutline.folderPaths(of: changes.files)
                if ChangesOutline.isGrouped(changes.files), folders.count > 1 {
                    let allOpen = folders.allSatisfy { !isFolded($0, in: changes) }
                    Button(allOpen ? "Collapse All" : "Expand All") {
                        withAnimation(.snappy) {
                            for folder in folders {
                                toggledFolders[folder] = allOpen
                            }
                        }
                    }
                    .help(allOpen ? "Folds every folder" : "Opens every folder")
                }
                Menu("Diffs") {
                    Button("Expand All Diffs") { expandDiffs(in: changes) }
                    Button("Collapse All Diffs") { setDiffs(unfolded: false, in: changes) }
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Unfolds or folds the diffs of the files shown")
            }
            Button("Changes in GitLab") { actions.open(changesURL) }
        }
        .buttonStyle(.link)
        .font(.callout)
    }

    @ViewBuilder
    private func files(_ changes: MergeRequestChanges, isLoadingDiffs: Bool) -> some View {
        if changes.files.isEmpty, changes.isComplete {
            Text("No files changed")
                .foregroundStyle(.secondary)
        } else {
            let checkout = self.checkout
            let grouped = ChangesOutline.isGrouped(changes.files)
            let rows = rows(of: changes)
            let prefix = grouped ? ChangesOutline.commonPrefix(of: ChangesOutline.folderPaths(of: changes.files)) : ""
            VStack(alignment: .leading, spacing: 8) {
                if changes.isListOnly {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(changes.files.count) files: too many to show their diffs here")
                            .foregroundStyle(.secondary)
                        Button("Open Changes in GitLab") { actions.open(changesURL) }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                }
                if changes.files.count >= Self.filterFrom {
                    filterField(shown: rows.count { if case .file = $0 { true } else { false } }, of: changes.files.count)
                }
                if !prefix.isEmpty {
                    CommonPath(prefix: prefix)
                }
                // Lazy: a merge request of a thousand files builds the rows that scroll into view, and each asks for
                // its page of diffs as it shows.
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        switch row {
                        case .folder(let folder):
                            FolderRow(folder: folder, prefix: prefix) {
                                withAnimation(.snappy) { toggledFolders[folder.path] = !folder.isFolded }
                            }
                        case .file(let index, _):
                            fileRow(changes, index: index, grouped: grouped, checkout: checkout, isLoadingDiffs: isLoadingDiffs)
                        }
                    }
                }
                .padding(.horizontal, -6)
                if !changes.isComplete, isLoadingDiffs {
                    // The next page of files' diffs is on its way.
                    SkeletonLines(count: 2, lastFraction: 0.4, lineHeight: 18)
                }
                if let checkout, let problem = model?.workspaces.actionProblems[checkout.id] {
                    SymbolText(
                        symbol: "exclamationmark.triangle.fill", style: AnyShapeStyle(MergeRequestStatus.Color.orange.swiftUI),
                        text: problem)
                    .font(.callout)
                    .padding(.top, 4)
                }
            }
        }
    }

    private func fileRow(
        _ changes: MergeRequestChanges, index: Int, grouped: Bool, checkout: Checkout?, isLoadingDiffs: Bool
    ) -> some View {
        let file = changes.files[index]
        let unfolded = isUnfolded(file, in: changes)
        return ChangedFileView(
            file: file, isUnfolded: unfolded, layout: layout, checkout: checkout, showsFolder: !grouped,
            diffState: changes.isListOnly ? .listOnly : isLoadingDiffs ? .loading : .idle,
            openInIDE: checkout.map { checkout in { openInIDE(file, in: checkout) } },
            openInGitLab: { actions.open(changesURL) }, copy: copyPath, loadDiff: { loadDiff(at: index) },
            selection: selection?.path == file.path ? selection : nil,
            select: askClaude == nil ? nil : { line in
                // A pick by number replaces the selected text.
                textPickPath = nil
                selection = DiffSelection.click(
                    line, path: file.path, extending: NSEvent.modifierFlags.contains(.shift), in: selection)
            },
            clearSelection: { selection = nil }, askClaude: askClaude, isTextOwner: textPickPath == file.path,
            textOwnerChanged: { owns in
                if owns {
                    // Selected text replaces the lines picked by number, and the selection in another file.
                    selection = nil
                    textPickPath = file.path
                } else if textPickPath == file.path {
                    textPickPath = nil
                }
            }
        ) {
            withAnimation(.snappy) { toggled[file.id] = !unfolded }
            if !unfolded {
                loadDiff(at: index)
            }
        }
        .padding(.leading, grouped ? 16 : 0)
        // As the row shows, and again when another selection dropped the diff.
        .task(id: file.content == .notLoaded) {
            if file.content == .notLoaded {
                await model?.mergeRequestChanges.loadDiff(of: mergeRequest, fileAt: index)
            }
        }
    }

    private func filterField(shown: Int, of total: Int) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                TextField("Filter Files", text: $filter, prompt: Text("Filter Files"))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                if !filter.isEmpty {
                    Button {
                        filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear the filter")
                    .accessibilityLabel("Clear the Filter")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            }
            .frame(maxWidth: 320)
            if !filter.isEmpty {
                Text("\(shown) of \(total) files")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// the folders start folded when there are several; the user's own toggles win
    private func isFolded(_ folder: String, in changes: MergeRequestChanges) -> Bool {
        toggledFolders[folder] ?? (ChangesOutline.startsFolded(changes.files) && !unfoldedFolders.contains(folder))
    }

    private func rows(of changes: MergeRequestChanges) -> [ChangesOutline.Row] {
        ChangesOutline.rows(of: changes.files, filter: filter) { isFolded($0, in: changes) }
    }

    /// the files on screen: not in a folded folder, and passing the filter
    private func shownFiles(in changes: MergeRequestChanges) -> [MergeRequestChanges.FileChange] {
        rows(of: changes).compactMap { if case .file(let index, _) = $0 { changes.files[index] } else { nil } }
    }

    /// Expand All Diffs opens the files shown; their diffs load page by page as the rows build (the lazy list builds
    /// only those in view). Above 50 files it asks first.
    private func expandDiffs(in changes: MergeRequestChanges) {
        let count = shownFiles(in: changes).count
        if count > Self.expandWithoutAsking {
            confirmingExpand = count
        } else {
            setDiffs(unfolded: true, in: changes)
        }
    }

    /// Folding takes every file, including those in folded folders, so that a later open finds them folded.
    private func setDiffs(unfolded: Bool, in changes: MergeRequestChanges) {
        let files = unfolded ? shownFiles(in: changes) : changes.files
        withAnimation(.snappy) {
            for file in files {
                toggled[file.id] = unfolded
            }
        }
    }

    private func isUnfolded(_ file: MergeRequestChanges.FileChange, in changes: MergeRequestChanges) -> Bool {
        toggled[file.id] ?? (changes.files.count <= Self.unfoldedFiles && !file.foldsByDefault && !file.hunks.isEmpty)
    }

    /// The checkout that has the merge request's branch, where Open in IDE opens a file; `nil` without one or without
    /// an Open in IDE command.
    private var checkout: Checkout? {
        guard let store = model?.workspaces, LaunchCommand.words(of: store.settings.ideCommand)?.isEmpty == false,
            let entry = WorkspaceLinks(checkouts: store.checkouts, readings: store.readings, mergeRequests: [])
                .checkout(for: mergeRequest)
        else {
            return nil
        }
        return store.checkouts.first { $0.id == entry.id }
    }

    private func openInIDE(_ file: MergeRequestChanges.FileChange, in checkout: Checkout) {
        guard let store = model?.workspaces else {
            return
        }
        Task { await store.openInIDE(checkout, file: file.path) }
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// Asks the store for the list, once the card shows; the store asks nothing for a list it has.
    private func open() {
        guard fixtures == nil, let model else {
            return
        }
        let mergeRequest = mergeRequest
        Task { await model.mergeRequestChanges.open(mergeRequest) }
    }

    private func loadDiff(at index: Int) {
        guard fixtures == nil, let model else {
            return
        }
        let mergeRequest = mergeRequest
        Task { await model.mergeRequestChanges.loadDiff(of: mergeRequest, fileAt: index) }
    }
}

/// A folder's header among many files: the fold chevron, the folder, its file count and +/−.
private struct FolderRow: View {
    let folder: ChangesOutline.Folder
    /// the start every folder shares, shown once above the folders
    let prefix: String
    let toggle: () -> Void

    @ViewState private var isHovered = false

    /// the path below the shared start; "./" for the shared folder itself, "/" for the top
    private var shownPath: String {
        guard !folder.path.isEmpty else {
            return "/"
        }
        guard !prefix.isEmpty, folder.path.hasPrefix(prefix) else {
            return folder.path
        }
        let rest = String(folder.path.dropFirst(prefix.count))
        return rest.isEmpty ? "./" : rest
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(folder.isFolded ? 0 : 90))
                .frame(width: 10)
            Image(systemName: "folder.fill")
                .foregroundStyle(MergeRequestStatus.Color.blue.swiftUI.opacity(0.75))
                .imageScale(.small)
            ShortenedPath(path: shownPath)
                .fontWeight(.medium)
                .help(folder.path.isEmpty ? "The top folder" : folder.path)
            Text(verbatim: "\(folder.fileCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.fill.tertiary, in: Capsule())
            Spacer(minLength: 8)
            DiffStat(additions: folder.additions, deletions: folder.deletions, content: .empty)
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.fill.quaternary.opacity(isHovered ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(folder.isFolded ? "Shows the folder's files" : "Hides the folder's files")
    }
}

/// A folder path that gives way at a slash from the left, as "…/qa/services/carddemo/", when it doesn't fit; the last
/// resort cuts its start mid-name.
private struct ShortenedPath: View {
    let path: String

    var body: some View {
        let variants = ChangesOutline.pathVariants(of: path)
        ViewThatFits(in: .horizontal) {
            ForEach(variants, id: \.self) { variant in
                Text(verbatim: variant)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(verbatim: variants.last ?? path)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }
}

/// The start every folder shares, once above them, so each header shows only what differs.
private struct CommonPath: View {
    let prefix: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .imageScale(.small)
            Text("In")
            ShortenedPath(path: prefix)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .help(prefix)
    }
}

// MARK: - A file

/// Where a file's diff is, while it isn't here.
private enum DiffState {
    case idle
    case loading
    /// too many files to load diffs
    case listOnly
}

/// A changed file: a row with the fold chevron, the kind's letter, the path and +/− with a small bar, then its diff when
/// unfolded. Open in IDE shows on hover where a checkout has the branch; the context menu has it too.
private struct ChangedFileView: View {
    let file: MergeRequestChanges.FileChange
    let isUnfolded: Bool
    let layout: DiffLayoutChoice
    let checkout: Checkout?
    /// whether the path shows its folder; under a folder's header, only the name
    let showsFolder: Bool
    let diffState: DiffState
    let openInIDE: (() -> Void)?
    let openInGitLab: () -> Void
    let copy: (String) -> Void
    let loadDiff: () -> Void
    /// the lines picked in this file (AI-07)
    var selection: DiffSelection?
    /// picks a line, or extends the pick with Shift; `nil` while the Claude features are off
    var select: ((DiffLineID) -> Void)?
    var clearSelection: () -> Void = {}
    var askClaude: AskClaudeAboutCodeAction?
    /// whether this file holds the selected text the card knows (AI-07)
    var isTextOwner = false
    var textOwnerChanged: (Bool) -> Void = { _ in }
    let toggle: () -> Void

    @ViewState private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row
            if isUnfolded {
                content
                    .padding(.leading, 6)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isUnfolded ? 90 : 0))
                .frame(width: 10)
            KindBadge(kind: file.kind)
            FilePath(file: file, showsFolder: showsFolder)
            if file.isGenerated {
                Text("generated")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.fill.tertiary, in: Capsule())
            }
            Spacer(minLength: 8)
            if let openInIDE, file.kind != .deleted {
                Button(action: openInIDE) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.borderless)
                .opacity(isHovered ? 1 : 0)
                .help("Open \(file.path) in your IDE, in \(checkout?.name ?? "the checkout")")
                .accessibilityLabel("Open in IDE")
            }
            DiffStat(additions: file.additions, deletions: file.deletions, content: file.content)
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.fill.quaternary.opacity(isHovered ? 1 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(isUnfolded ? "Fold" : "Unfold", action: toggle)
            if let openInIDE, file.kind != .deleted {
                Button("Open in IDE", action: openInIDE)
            }
            Button("Changes in GitLab", action: openInGitLab)
            if let askClaude {
                Divider()
                Button("Ask Claude About This File…") { askClaude(.file(file.path)) }
            }
            Divider()
            Button("Copy Path") { copy(file.path) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isUnfolded ? "Folds the diff" : "Unfolds the diff")
    }

    @ViewBuilder
    private var content: some View {
        switch file.content {
        case .hunks(let hunks):
            DiffView(
                hunks: hunks, path: file.path, layout: layout, lineSelection: selection, select: select,
                askClaude: askClaude, clearPick: clearSelection, isTextOwner: isTextOwner,
                textOwnerChanged: textOwnerChanged)
        case .binary:
            note("A binary file: no lines to show")
        case .notShown:
            HStack(spacing: 8) {
                note("Too large to show here")
                Button("Changes in GitLab", action: openInGitLab)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        case .empty:
            note(file.kind == .renamed ? "Renamed, no line changed" : "No line changed")
        case .notLoaded:
            switch diffState {
            case .loading:
                // The lines of the diff, about as tall as a short one.
                SkeletonLines(count: 4, lastFraction: 0.5, lineHeight: 18)
                    .padding(.leading, 24)
            case .idle:
                HStack(spacing: 8) {
                    note("The diff isn't loaded")
                    Button("Load Diff", action: loadDiff)
                        .buttonStyle(.link)
                        .font(.callout)
                }
            case .listOnly:
                HStack(spacing: 8) {
                    note("Too many files to show diffs here")
                    Button("Changes in GitLab", action: openInGitLab)
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.leading, 24)
    }
}

/// The kind of change as Xcode's source control shows it: a letter in a small tinted square; an empty square until the
/// file's page of diffs says.
private struct KindBadge: View {
    let kind: MergeRequestChanges.FileChange.Kind?

    var body: some View {
        let (letter, tint): (String, Color) =
            switch kind {
            case .added: ("A", MergeRequestStatus.Color.green.swiftUI)
            case .deleted: ("D", MergeRequestStatus.Color.red.swiftUI)
            case .renamed: ("R", MergeRequestStatus.Color.blue.swiftUI)
            case .modified: ("M", Color.secondary)
            case nil: ("", Color.secondary)
            }
        Text(verbatim: letter)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .frame(width: 15, height: 15)
            .background(tint.opacity(kind == nil ? 0.08 : 0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .help(help)
    }

    private var help: String {
        switch kind {
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .modified: "Modified"
        case nil: "Changed"
        }
    }
}

/// The file's folder in the secondary color and its name in the label color, cut in the middle; a rename shows the old
/// name before an arrow.
private struct FilePath: View {
    let file: MergeRequestChanges.FileChange
    var showsFolder = true

    var body: some View {
        HStack(spacing: 4) {
            if file.kind == .renamed {
                Text(verbatim: Self.name(of: file.oldPath))
                    .foregroundStyle(.secondary)
                    .strikethrough(color: .secondary.opacity(0.6))
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            Text("\(Text(verbatim: showsFolder ? ChangesOutline.folder(of: file.path) : "").foregroundStyle(.secondary))\(Text(verbatim: Self.name(of: file.path)).fontWeight(.medium))")
                .lineLimit(1)
                .truncationMode(.head)
        }
        .help(file.kind == .renamed ? "\(file.oldPath) → \(file.newPath)" : file.path)
    }

    private static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// "+12 −3" in monospaced digits with five small blocks as GitLab's diffstat: filled by the size of the change, split by
/// the share of green and red (``DiffStatBlocks``).
private struct DiffStat: View {
    let additions: Int
    let deletions: Int
    let content: MergeRequestChanges.FileChange.Content

    var body: some View {
        HStack(spacing: 6) {
            switch content {
            case .binary:
                Text("binary")
                    .foregroundStyle(.secondary)
            case .notShown:
                Text("large")
                    .foregroundStyle(.secondary)
            case .hunks, .empty, .notLoaded:
                HStack(spacing: 4) {
                    if additions > 0 {
                        Text(verbatim: "+\(additions)")
                            .foregroundStyle(MergeRequestStatus.Color.green.swiftUI)
                    }
                    if deletions > 0 {
                        Text(verbatim: "−\(deletions)")
                            .foregroundStyle(MergeRequestStatus.Color.red.swiftUI)
                    }
                }
                blocks
            }
        }
        .font(.caption.monospacedDigit())
    }

    private var blocks: some View {
        HStack(spacing: 1.5) {
            ForEach(Array(DiffStatBlocks.blocks(additions: additions, deletions: deletions).enumerated()), id: \.offset) { _, block in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Self.style(of: block))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private static func style(of block: DiffStatBlocks.Block) -> AnyShapeStyle {
        switch block {
        case .added: AnyShapeStyle(MergeRequestStatus.Color.green.swiftUI)
        case .removed: AnyShapeStyle(MergeRequestStatus.Color.red.swiftUI)
        case .none: AnyShapeStyle(.quaternary)
        }
    }
}

// MARK: - The diff

/// How the diff shows a change: removed and added lines one under the other, or the old and new file side by side.
enum DiffLayoutChoice: String, CaseIterable {
    case inline
    case sideBySide
}

/// A file's hunks as a diff, inline or side by side, in text views (`DiffSurfaceView`): each hunk's header in a quiet
/// band, then its lines with their numbers, syntax colors, added lines on green and removed on red, the part of a line
/// that changed against its partner stronger. The code can be selected by dragging, across lines and hunks; the
/// selection offers "Ask Claude" (AI-07). Inline, long lines scroll sideways; side by side, they wrap. A long diff shows
/// its first ``firstLines`` with "Show All N Lines".
private struct DiffView: View {
    let hunks: [DiffHunk]
    /// the file's path, which picks the language of the syntax colors
    let path: String
    let layout: DiffLayoutChoice
    /// the lines picked by their numbers (AI-07)
    var lineSelection: DiffSelection?
    /// picks a line by a click on its number; `nil` leaves the numbers plain
    var select: ((DiffLineID) -> Void)?
    /// opens the sheet; `nil` while the Claude features are off
    var askClaude: AskClaudeAboutCodeAction?
    var clearPick: () -> Void = {}
    /// whether this file holds the selected text the card knows
    var isTextOwner = false
    var textOwnerChanged: (Bool) -> Void = { _ in }

    @ViewState private var limit = DiffView.firstLines
    /// the hunks styled once, off the main actor; plain until then
    @ViewState private var styled: [[StyledLine]]?
    /// changes when `styled` does
    @ViewState private var styleStamp = 0

    /// the lines shown before "Show All N Lines"
    private static let firstLines = 300

    var body: some View {
        let total = hunks.reduce(0) { $0 + $1.lines.count + 1 }
        VStack(alignment: .leading, spacing: 0) {
            DiffSurfaceView(
                hunks: hunks, styled: styled, stamp: styleStamp, path: path, layout: layout, limit: limit,
                lineSelection: lineSelection, isTextOwner: isTextOwner,
                asks: askClaude.map { ask in { scope in ask(scope) } }, pickLine: select, clearLinePick: clearPick,
                textOwnerChanged: textOwnerChanged)
            if total > limit {
                Button("Show All \(hunks.reduce(0) { $0 + $1.lines.count }) Lines") {
                    limit = .max
                }
                .buttonStyle(.link)
                .font(.callout)
                .padding(8)
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
        .task(id: path) {
            let hunks = hunks
            let path = path
            styled = await Task.detached(priority: .userInitiated) { DiffStyling.style(hunks, path: path) }.value
            styleStamp += 1
        }
    }
}
