import MenubarCore
import SwiftUI

/// What the rows of the menu pane, its flyouts and the main window's lists do. The pane closes after each action that
/// opens something, since opening a window doesn't close it (`docs/decisions.md`, Task 0.10); the gallery passes ``none``.
public struct PanelActions {
    /// opens a web page in the real browser, for the buttons that say so: "Open in GitLab", "Open Build in Jenkins", a link
    /// row. Anything that stays in the app goes through ``follow(_:)``.
    public var open: @MainActor (URL) -> Void
    /// follows a link inside the app (WIN-06): a build, merge request or work item shows in its section or under
    /// "Opened"; ⌥ held, a GitLab pipeline and any other page go to ``open``. `nil` where the surface has no window to
    /// show it in, as the gallery.
    public var followLink: (@MainActor (URL) -> Void)?
    /// opens Settings at a pane
    public var openSettings: @MainActor (SettingsPane) -> Void
    public var openWindow: @MainActor () -> Void
    /// opens the main window at a section, which a summary row of the panel does
    public var openSection: @MainActor (MainWindowSection) -> Void
    /// opens the main window, then Watch a Build…
    public var watchBuild: @MainActor () -> Void
    public var checkNow: @MainActor () -> Void
    /// shows the builds hidden by hand again (HIDE-01)
    public var showHidden: @MainActor () -> Void
    /// rebuilds the app (APP-05)
    public var rebuild: @MainActor () -> Void
    public var quit: @MainActor () -> Void
    /// hides a build until its job's next build (HIDE-01)
    public var hide: @MainActor (Build) -> Void
    /// stops watching a job (WATCH-05)
    public var stopWatching: @MainActor (String) -> Void
    /// puts a link on the clipboard
    public var copy: @MainActor (URL) -> Void
    /// closes the panel, as Esc in an empty search field does
    public var close: @MainActor () -> Void
    /// starts a build's job again with its parameters (PIPE-09)
    public var rebuildBuild: @MainActor (BuildID) -> Void
    /// removes a job's queued rebuild from Jenkins's queue (PIPE-09)
    public var cancelRebuild: @MainActor (String) -> Void
    /// watches the builds of an MR, by its number, in one click and without the sheet (WATCH-01)
    public var watchBuilds: @MainActor (MergeRequest) -> Void
    /// opens GitLab's new issue page for a New Work Item entry point (NEW-01); `nil` where the surface has none or the
    /// team values can't make a link, so the menus don't offer it
    public var newWorkItem: (@MainActor (NewWorkItemSource) -> Void)?
    /// sets a job's notifications by its job key: always, never, or `nil` for its group's switch (ALERT-08)
    public var setJobNotifications: @MainActor (String, NotificationPolicy.JobSetting?) -> Void
    /// switches the notifications of My Builds or Watching on or off (ALERT-08)
    public var setGroupNotifications: @MainActor (NotificationPolicy.Group, Bool) -> Void

    public init(
        open: @escaping @MainActor (URL) -> Void, openSettings: @escaping @MainActor (SettingsPane) -> Void,
        openWindow: @escaping @MainActor () -> Void, watchBuild: @escaping @MainActor () -> Void,
        checkNow: @escaping @MainActor () -> Void, showHidden: @escaping @MainActor () -> Void,
        rebuild: @escaping @MainActor () -> Void, quit: @escaping @MainActor () -> Void,
        hide: @escaping @MainActor (Build) -> Void, stopWatching: @escaping @MainActor (String) -> Void,
        copy: @escaping @MainActor (URL) -> Void, close: @escaping @MainActor () -> Void,
        rebuildBuild: @escaping @MainActor (BuildID) -> Void = { _ in },
        cancelRebuild: @escaping @MainActor (String) -> Void = { _ in },
        watchBuilds: @escaping @MainActor (MergeRequest) -> Void = { _ in },
        openSection: @escaping @MainActor (MainWindowSection) -> Void = { _ in },
        newWorkItem: (@MainActor (NewWorkItemSource) -> Void)? = nil,
        followLink: (@MainActor (URL) -> Void)? = nil,
        setJobNotifications: @escaping @MainActor (String, NotificationPolicy.JobSetting?) -> Void = { _, _ in },
        setGroupNotifications: @escaping @MainActor (NotificationPolicy.Group, Bool) -> Void = { _, _ in }
    ) {
        self.setJobNotifications = setJobNotifications
        self.setGroupNotifications = setGroupNotifications
        self.followLink = followLink
        self.open = open
        self.openSettings = openSettings
        self.openWindow = openWindow
        self.watchBuild = watchBuild
        self.checkNow = checkNow
        self.showHidden = showHidden
        self.rebuild = rebuild
        self.quit = quit
        self.hide = hide
        self.stopWatching = stopWatching
        self.copy = copy
        self.close = close
        self.rebuildBuild = rebuildBuild
        self.cancelRebuild = cancelRebuild
        self.watchBuilds = watchBuilds
        self.openSection = openSection
        self.newWorkItem = newWorkItem
    }

    /// Follows a link inside the app: a build, merge request or work item shows in the main window, and anything the app
    /// has no page for goes to the browser (the user, 2026-10-30).
    ///
    /// - Parameter url: the link
    @MainActor
    public func follow(_ url: URL) {
        (followLink ?? open)(url)
    }

    /// actions that do nothing, for the gallery
    public static var none: PanelActions {
        PanelActions(
        open: { _ in }, openSettings: { _ in }, openWindow: {}, watchBuild: {}, checkNow: {}, showHidden: {},
            rebuild: {}, quit: {}, hide: { _ in }, stopWatching: { _ in }, copy: { _ in }, close: {})
    }
}

/// What a build's row shows: the state's symbol, the title, the facts in three parts, then the progress bar or the
/// failures (PIPE-02, PIPE-03), or the rebuild (PIPE-09). The panel's rows and the main window's Pipelines list share
/// it (`pipelines.md`).
struct BuildRowContent: View {
    let model: BuildRowModel
    /// removes the queued rebuild, the row's Cancel (PIPE-09)
    var cancelRebuild: @MainActor () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        PanelRowLayout {
            Image(systemName: model.state.symbol)
                .tint(model.state.color)
        } lines: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: model.title)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    .help(model.title)
                Spacer(minLength: 0)
                if model.notifications.isMuted {
                    MutedMark()
                }
                // The checkout the build lives in (WS-07).
                WorkspaceTag(subject: .build(model.build))
            }
            facts
                .font(.subheadline)
                .foregroundStyle(.secondary)
            thirdLine
        }
    }

    /// The author, the build, the status and the timing. What matters most stays whole: the build ("!14 #3") and a
    /// finished build's result and times never truncate. Short of room, line 2 gives up its parts whole, in this order:
    /// the running stages truncate and then go, then the author and its " · ", then a finished build's "finished …".
    /// Only when even that doesn't fit, the timing truncates, and then a branch name, cut in the middle so its number
    /// stays (reviews PANEL-02, PIPELINES-01). At accessibility sizes the line wraps instead.
    @ViewBuilder private var facts: some View {
        if typeSize.isAccessibilitySize {
            Text(verbatim: model.facts)
        } else if model.build.isRunning, model.status != nil {
            ViewThatFits(in: .horizontal) {
                factsLine(stages: .whole)
                factsLine(stages: .truncating)
                factsLine()
                factsLine(byline: false)
                factsLine(byline: false, fits: false)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                factsLine()
                factsLine(byline: false)
                factsLine(byline: false, age: false)
                factsLine(byline: false, age: false, fits: false)
            }
        }
    }

    /// the least room the running stages need on line 2, or they don't show
    private static let leastStagesWidth: CGFloat = 60

    /// how much of the running stages line 2 shows
    private enum Stages {
        /// at their natural width
        case whole
        /// cut at the end, with at least ``leastStagesWidth``
        case truncating
        case none
    }

    /// Returns line 2 in parts, with or without some of them.
    ///
    /// - Parameters:
    ///   - showsByline: whether the author shows
    ///   - stages: how much of the running stages shows; a finished build's result always shows
    ///   - age: whether a finished build's "finished …" shows
    ///   - fits: `false` for the last resort, whose timing and branch name truncate instead of keeping their width
    /// - Returns: the line
    private func factsLine(byline showsByline: Bool = true, stages: Stages = .none, age: Bool = true, fits: Bool = true)
        -> some View
    {
        HStack(spacing: 0) {
            if showsByline, let byline = model.byline {
                Text(verbatim: byline)
                    .fixedSize()
                separator
            }
            // An MR's reference is never cut; a branch's is, in the middle.
            Text(verbatim: model.buildName)
                .truncationMode(.middle)
                .fixedSize(horizontal: model.build.mergeRequestIID != nil, vertical: false)
                .layoutPriority(2)
            if let status = model.status {
                if !model.build.isRunning {
                    separator
                    Text(verbatim: status)
                        .fixedSize()
                } else if stages != .none {
                    // Its ideal width is at most the least room, so `ViewThatFits` picks this line only while the
                    // stages get that much.
                    separator
                    Text(verbatim: status)
                        .frame(idealWidth: stages == .whole ? nil : Self.leastStagesWidth, alignment: .leading)
                        .fixedSize(horizontal: stages == .whole, vertical: false)
                }
            }
            separator
            Text(verbatim: age ? model.timing : model.timingWithoutAge)
                .fixedSize(horizontal: fits, vertical: false)
        }
        .lineLimit(1)
    }

    private var separator: some View {
        Text(verbatim: " · ")
            .fixedSize()
    }

    @ViewBuilder private var thirdLine: some View {
        if let rebuild = model.rebuild {
            RebuildLine(rebuild: rebuild, cancel: cancelRebuild)
                .font(.subheadline)
        } else {
            progressOrFailures
        }
    }

    @ViewBuilder private var progressOrFailures: some View {
        switch model.progress {
        case .fraction(let fraction)?:
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .padding(.top, 2)
        case .indeterminate?:
            // With Reduce Motion, the hourglass and the elapsed time carry the state (`docs/design/panel.md`).
            if !reduceMotion {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        case nil:
            if let failures = model.failures {
                Text(verbatim: failures)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
        }
    }
}

/// A rebuild's line under a build (PIPE-09): "Rebuilding…", with Cancel while the new build waits in Jenkins's queue,
/// or the failure after the red problem marker, its text in the label color as in a problem row. In the font around it.
struct RebuildLine: View {
    let rebuild: JenkinsRebuild
    /// removes the new build from the queue; `nil` shows no Cancel, for a place with a Cancel Rebuild button
    let cancel: (@MainActor () -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if let failure = rebuild.failure {
                // The marker apart, so a second line starts under the text.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: Marker.problem)
                        .foregroundStyle(.red)
                    Text(verbatim: failure)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(verbatim: rebuild.text)
                        .foregroundStyle(.secondary)
                    if rebuild.canCancel, let cancel {
                        Text(verbatim: " · ")
                            .foregroundStyle(.secondary)
                        // The tint by hand: the panel's row draws its label, this link too, in the label color.
                        Button("Cancel", action: cancel)
                            .buttonStyle(.link)
                            .foregroundStyle(.tint)
                            .help("Removes the new build from Jenkins's queue")
                    }
                }
                .lineLimit(1)
            }
        }
    }
}

/// A build's context menu: its links, Copy Link, Rebuild (or Cancel Rebuild while queued) and Rebuild with Changes…
/// for a finished build, Hide Until the Next Build and, for a watched build, Stop Watching. The panel's rows and the
/// main window's Pipelines list share it.
struct BuildRowMenu: View {
    let model: BuildRowModel
    let actions: PanelActions

    var body: some View {
        menu
    }

    @ViewBuilder private var menu: some View {
        ForEach(model.links) { link in
            // The merge request shows in the app; Jenkins and the branch open in the browser.
            Button(link.title) { if link.kind == .mergeRequest { actions.follow(link.url) } else { actions.open(link.url) } }
        }
        if let page = model.buildPage {
            Divider()
            Button("Copy Link") { actions.copy(page.url) }
        }
        if model.offersRebuild {
            Divider()
            if model.rebuild?.canCancel == true {
                Button("Cancel Rebuild") { actions.cancelRebuild(model.build.jobKey) }
            } else {
                Button("Rebuild") { actions.rebuildBuild(model.build.id) }
                    .disabled(model.rebuild?.isUnderWay == true)
            }
            if let url = model.rebuildWithChanges {
                Button("Rebuild with Changes…") { actions.open(url) }
            }
        }
        if let newWorkItem = actions.newWorkItem, model.build.result == .failure || model.build.result == .unstable {
            Divider()
            Button("New Bug from This Build") { newWorkItem(.bugFromBuild(model.build, model.buildPage?.url)) }
        }
        Divider()
        JobNotificationsMenu(notifications: model.notifications) {
            actions.setJobNotifications(model.build.jobKey, $0)
        }
        Button("Hide Until the Next Build") { actions.hide(model.build) }
        if model.build.kind == .watched {
            Button("Stop Watching") { actions.stopWatching(model.build.jobKey) }
        }
    }
}
