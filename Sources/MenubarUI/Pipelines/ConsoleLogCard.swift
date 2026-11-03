import AppKit
import MenubarCore
import SwiftUI

/// The build detail's Console Log card (PIPE-12; the user, 2026-11-03: "a section where i can see all the console logs
/// of the pipeline… it can be very very very long, so we need to load it lazy with low priority. maybe it's collapsed").
///
/// Collapsed, it reads nothing. Opened, it reads the log's end first, then earlier pages when scrolled to the top or on
/// "Load Earlier", and follows a running build's end until it closes. The lines don't wrap: a long one scrolls sideways,
/// as in a terminal, so every line is one row and the line numbers stay beside their lines.
struct ConsoleLogCard: View {
    let build: BuildID
    let consoleURL: URL?
    let open: (URL) -> Void

    @Environment(AppModel.self) private var appModel: AppModel?
    @Environment(\.consoleLogFixture) private var fixture
    @ViewState private var isOpen = false
    @ViewState private var loader: ConsoleLogLoader?
    @ViewState private var controller: ConsoleLogController?

    var body: some View {
        DetailCard("Console Log", symbol: "terminal", width: .fullWidth) {
            if isOpen, let loader, let controller {
                ConsoleLogPanel(
                    loader: loader, controller: controller, height: 460, consoleURL: consoleURL,
                    openFullLog: { ConsoleLogWindows.show(build: build, loader: loader, consoleURL: consoleURL, open: open) },
                    open: open)
            }
        } accessory: {
            HStack(spacing: 10) {
                if isOpen, let loader, loader.phase == .loaded {
                    ConsoleLogStats(loader: loader)
                }
                Button {
                    toggle()
                } label: {
                    Label(isOpen ? "Hide Log" : "Show Log", systemImage: isOpen ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(isOpen ? "Hides the log; a running build's end isn't followed meanwhile" : "Loads the log, its end first")
            }
        }
        // Reading and following last while the card is open and shows; closing or leaving the build cancels them.
        .task(id: isOpen) {
            guard isOpen, let loader else { return }
            await loader.open()
            await loader.follow()
        }
        .onAppear {
            if fixture?.startsOpen == true, !isOpen {
                toggle()
            }
        }
    }

    private func toggle() {
        if !isOpen, loader == nil {
            let source = fixture?.source ?? appModel?.consoleLogSource(for: build)
            guard let source else { return }
            let loader = ConsoleLogLoader(source: source)
            fixture?.prepare?(loader)
            self.loader = loader
            controller = ConsoleLogController()
        }
        withAnimation(.snappy) {
            isOpen.toggle()
        }
    }
}

/// The log with its toolbar, in the card and in the Full Log window.
struct ConsoleLogPanel: View {
    let loader: ConsoleLogLoader
    let controller: ConsoleLogController
    /// the log's height; nil fills the room
    var height: CGFloat?
    let consoleURL: URL?
    /// opens the Full Log window; nil in that window
    var openFullLog: (() -> Void)?
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            switch loader.phase {
            case .idle, .loading:
                frame {
                    VStack(alignment: .leading, spacing: 0) {
                        SkeletonLines(count: 9, lastFraction: 0.4, lineHeight: 18)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: ConsoleLogAppearance.background))
                }
            case .failed(let message):
                frame {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(verbatim: "The log couldn't be loaded: \(message)")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            Task { await loader.open() }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: ConsoleLogAppearance.background))
                }
            case .loaded:
                frame {
                    VStack(spacing: 0) {
                        if loader.hasEarlier {
                            edge(earlier: true)
                            Divider()
                        }
                        ConsoleLogTextArea(
                            controller: controller, blocks: loader.blocks, linesBefore: loader.linesBefore,
                            reachedTop: { Task { await loader.loadEarlier() } },
                            reachedBottom: {
                                if loader.hasLater {
                                    Task { await loader.loadLater() }
                                }
                            })
                        if loader.hasLater {
                            Divider()
                            edge(earlier: false)
                        }
                    }
                }
            }
            if let problem = loader.pageProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func frame(@ViewBuilder content: () -> some View) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return content()
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .frame(maxHeight: height == nil ? .infinity : nil)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75) }
    }

    // MARK: The toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            if loader.errorCount > 0 {
                ConsoleLogErrorNavigator(count: loader.errorCount, current: controller.currentError, controller: controller)
            }
            if loader.warningCount > 0 {
                DetailChip(
                    symbol: "exclamationmark.triangle.fill", tint: MergeRequestStatus.Color.orange.swiftUI,
                    text: "\(loader.warningCount.formatted()) \(loader.warningCount == 1 ? "warning" : "warnings")",
                    help: "Warning lines in the loaded part of the log")
            }
            if loader.phase == .loaded, !loader.isFinished {
                ConsoleLogLiveBadge()
            }
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                buttons(titled: true)
                buttons(titled: false)
            }
        }
    }

    private func buttons(titled: Bool) -> some View {
        HStack(spacing: 6) {
            button("Find", "magnifyingglass", titled: titled, help: "Finds text in the loaded log (⌘F in the log)") {
                controller.showFind()
            }
            .disabled(loader.phase != .loaded)
            button("Copy", "doc.on.doc", titled: titled, help: "Copies the selection, or every loaded line") {
                controller.copy()
            }
            .disabled(loader.phase != .loaded)
            if let openFullLog {
                button("Open Full Log", "arrow.up.left.and.arrow.down.right", titled: titled, help: "Opens the log in a window of its own") {
                    openFullLog()
                }
            }
            if let consoleURL {
                button("Open in Jenkins", "arrow.up.right.square", titled: titled, help: "Opens the build's console in Jenkins") {
                    open(consoleURL)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
    }

    private func button(_ title: String, _ symbol: String, titled: Bool, help: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            if titled {
                Label(title, systemImage: symbol)
            } else {
                Label(title, systemImage: symbol)
                    .labelStyle(.iconOnly)
            }
        }
        .help(help)
    }

    /// "Load Earlier" over the log, "Load Later" under it: what isn't loaded, and a spinner while it loads.
    private func edge(earlier: Bool) -> some View {
        let loading = earlier ? loader.isLoadingEarlier : loader.isLoadingLater
        return Button {
            Task {
                if earlier {
                    await loader.loadEarlier()
                } else {
                    await loader.loadLater()
                }
            }
        } label: {
            HStack(spacing: 6) {
                if loading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: earlier ? "arrow.up" : "arrow.down")
                }
                Text(earlier ? "Load Earlier" : "Load Later")
                    .fontWeight(.medium)
                if earlier, loader.linesBefore == nil {
                    Text(verbatim: "· line numbers count from the first line shown")
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .background(Color(nsColor: ConsoleLogAppearance.gutter))
        .fixedSize(horizontal: false, vertical: true)
        .help(earlier ? "Loads the part of the log before this one; scrolling to the top does too" : "Loads the part of the log after this one")
    }
}

/// "12,345 lines · 1.0 of 48.2 MB": what is loaded, and of how much.
struct ConsoleLogStats: View {
    let loader: ConsoleLogLoader

    var body: some View {
        let lines = "\(loader.lineCount.formatted()) \(loader.lineCount == 1 ? "line" : "lines")"
        let loaded = Self.size(Int64(loader.loadedBytes))
        let whole = Self.size(loader.size)
        let partial = loader.hasEarlier || loader.hasLater
        CountBadge(text: partial ? "\(lines) · \(loaded) of \(whole)" : "\(lines) · \(whole)")
            .help(partial ? "The loaded part of the log, and the whole log's size in Jenkins" : "The whole log")
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }
}

/// ‹ 2 of 5 errors ›: jumps between the loaded error lines.
struct ConsoleLogErrorNavigator: View {
    let count: Int
    let current: Int?
    let controller: ConsoleLogController

    var body: some View {
        let red = MergeRequestStatus.Color.red.swiftUI
        HStack(spacing: 2) {
            Button {
                controller.previousError()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .help("Previous error")
            Text(verbatim: label)
                .monospacedDigit()
                .padding(.horizontal, 2)
            Button {
                controller.nextError()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .help("Next error")
        }
        .buttonStyle(.plain)
        .font(.callout.weight(.medium))
        .foregroundStyle(red)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(red.opacity(0.10), in: Capsule())
        .overlay { Capsule().strokeBorder(red.opacity(0.25), lineWidth: 0.5) }
    }

    private var label: String {
        let errors = "\(count.formatted()) \(count == 1 ? "error" : "errors")"
        return current.map { "\($0.formatted()) of \(errors)" } ?? errors
    }
}

/// A running build's log, followed live.
struct ConsoleLogLiveBadge: View {
    @ViewState private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let green = MergeRequestStatus.Color.green.swiftUI
        HStack(spacing: 5) {
            Circle()
                .fill(green)
                .frame(width: 7, height: 7)
                .opacity(pulse ? 0.35 : 1)
            Text("Live")
                .font(.callout.weight(.medium))
                .foregroundStyle(green)
        }
        .help("Follows the end of the log while the build runs")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - The Full Log window

/// The Full Log windows, one per build: the same loader as the card's, in a window as large as the reader wants.
@MainActor
enum ConsoleLogWindows {
    private static var windows: [BuildID: NSWindow] = [:]
    private static var closers: [BuildID: any NSObjectProtocol] = [:]

    static func show(build: BuildID, loader: ConsoleLogLoader, consoleURL: URL?, open: @escaping (URL) -> Void) {
        if let window = windows[build] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = ConsoleLogWindowContent(loader: loader, controller: ConsoleLogController(), consoleURL: consoleURL, open: open)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        let name = build.job.removingPercentEncoding?.removingPercentEncoding ?? build.job
        window.title = "Console Log — \(name) #\(build.number)"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1040, height: 720))
        window.contentMinSize = NSSize(width: 520, height: 320)
        window.center()
        windows[build] = window
        closers[build] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                windows[build] = nil
                if let closer = closers.removeValue(forKey: build) {
                    NotificationCenter.default.removeObserver(closer)
                }
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private struct ConsoleLogWindowContent: View {
    let loader: ConsoleLogLoader
    let controller: ConsoleLogController
    let consoleURL: URL?
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                if loader.phase == .loaded {
                    ConsoleLogStats(loader: loader)
                }
            }
            ConsoleLogPanel(loader: loader, controller: controller, height: nil, consoleURL: consoleURL, open: open)
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 320)
        .task {
            await loader.open()
            await loader.follow()
        }
    }
}

// MARK: - The gallery's log

/// The gallery's console log: a log in memory in place of Jenkins, and whether the card starts open.
struct ConsoleLogFixture {
    var source: ConsoleLogSource
    var startsOpen = false
    /// fills the new loader at once, as the gallery's screenshots don't wait for the reads
    var prepare: (@MainActor (ConsoleLogLoader) -> Void)?
}

private struct ConsoleLogFixtureKey: EnvironmentKey {
    static let defaultValue: ConsoleLogFixture? = nil
}

extension EnvironmentValues {
    /// the gallery's console log; `nil` in the app, which reads Jenkins
    var consoleLogFixture: ConsoleLogFixture? {
        get { self[ConsoleLogFixtureKey.self] }
        set { self[ConsoleLogFixtureKey.self] = newValue }
    }
}
