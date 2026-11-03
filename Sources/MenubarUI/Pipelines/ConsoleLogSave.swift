import AppKit
import MenubarCore
import SwiftUI
import UniformTypeIdentifiers

/// The Console Log card's "Save…": the save panel, then the whole log streamed to the chosen file (PIPE-12). The panel's
/// toolbar shows its progress with Cancel, and then where it went.
@Observable @MainActor
final class ConsoleLogSave {
    enum State: Equatable {
        case idle
        case saving(ConsoleLogSaveProgress)
        case saved(URL, ConsoleLogSaveResult)
        case failed(String)
    }

    private(set) var state = State.idle
    @ObservationIgnored private var work: Task<ConsoleLogSaveResult, any Error>?
    @ObservationIgnored private var wasCancelled = false

    var isSaving: Bool {
        if case .saving = state { true } else { false }
    }

    /// The file name the save panel starts with: `<job>-<number>.log`, the job's name as people read it.
    ///
    /// - Parameter build: the build
    static func fileName(for build: BuildID) -> String {
        var job = build.job.removingPercentEncoding?.removingPercentEncoding ?? build.job
        // A branch job like `feature/foo` must not become a folder.
        job = job.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(job)-\(build.number).log"
    }

    /// Asks where to save, then saves.
    ///
    /// - Parameters:
    ///   - source: where the log is read
    ///   - name: the panel's starting file name
    func start(source: ConsoleLogSource, name: String) {
        guard !isSaving else { return }
        let panel = NSSavePanel()
        panel.title = "Save Console Log"
        panel.prompt = "Save"
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.log]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self?.run(source: source, to: url)
            }
        }
    }

    #if DEBUG
    /// Shows a state without saving, for the gallery and the renders.
    func preview(_ state: State) {
        self.state = state
    }
    #endif

    func cancel() {
        wasCancelled = true
        work?.cancel()
    }

    /// Clears what a finished or failed save says.
    func dismiss() {
        if !isSaving {
            state = .idle
        }
    }

    private func run(source: ConsoleLogSource, to url: URL) {
        wasCancelled = false
        state = .saving(ConsoleLogSaveProgress(fraction: 0, bytes: 0))
        let work = Task.detached(priority: .utility) { [weak self] in
            try await ConsoleLogSaver.save(source: source, to: url) { progress in
                Task { @MainActor in self?.advance(progress) }
            }
        }
        self.work = work
        Task {
            do {
                state = .saved(url, try await work.value)
            } catch {
                if wasCancelled || error is CancellationError {
                    state = .idle
                } else {
                    state = .failed(ConsoleLogLoader.message(of: error))
                }
            }
            self.work = nil
        }
    }

    private func advance(_ progress: ConsoleLogSaveProgress) {
        if case .saving(let current) = state, progress.fraction >= current.fraction {
            state = .saving(progress)
        }
    }
}

/// What the toolbar says about a save: its progress with Cancel, where the file went, or why it failed.
struct ConsoleLogSaveStatus: View {
    let save: ConsoleLogSave

    var body: some View {
        switch save.state {
        case .idle:
            EmptyView()
        case .saving(let progress):
            HStack(spacing: 10) {
                ProgressView(value: min(max(progress.fraction, 0), 1))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 220)
                Text(verbatim: "Saving \(Int((progress.fraction * 100).rounded())) % · \(ConsoleLogStats.size(progress.bytes))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel") { save.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
        case .saved(let url, let result):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(MergeRequestStatus.Color.green.swiftUI)
                Text(verbatim: "Saved \(ConsoleLogStats.size(result.bytes)) to \(url.lastPathComponent)\(result.isComplete ? "" : ", the log as far as the running build has written it")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.link)
                .font(.callout)
                Spacer(minLength: 0)
                Button {
                    save.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Dismisses this line")
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(MergeRequestStatus.Color.orange.swiftUI)
                Text(verbatim: "The log couldn't be saved: \(message)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button {
                    save.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Dismisses this line")
            }
        }
    }
}
