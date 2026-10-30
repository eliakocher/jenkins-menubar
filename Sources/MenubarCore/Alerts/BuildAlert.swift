import Foundation

/// An alert about one build: a build that finished (ALERT-01), a running build whose stages failed (ALERT-05), or a
/// preview from Settings (ALERT-07).
///
/// ``AlertPolicy`` decides on them and ``AlertAnnouncer`` hands them to the ``Effects``. The alert window shows one per
/// window, found by its ``id``.
public struct BuildAlert: Codable, Hashable, Identifiable, Sendable {
    /// a new one for every alert, so several alert windows can be open at once
    public var id: UUID
    public var kind: Kind
    /// the build the alert is about; a made-up one for a preview
    public var build: Build
    public var content: AlertContent

    public init(id: UUID = UUID(), kind: Kind, build: Build, content: AlertContent) {
        self.id = id
        self.kind = kind
        self.build = build
        self.content = content
    }

    /// What the alert announces, which decides how it is shown and logged.
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// a followed build finished: the alert window or a banner, as set (ALERT-03)
        case finished
        /// a running build has a new set of failed stages: always a banner (ALERT-05)
        case stageFailed
        /// a sample alert from Settings, shown like a finished one but not logged as an alert (ALERT-07)
        case preview
    }
}

/// What an alert shows, sounds and links to (ALERT-02).
///
/// The alert window shows the icon, the headline, the title and the facts, then the ``buttons``. A banner shows the
/// headline as its title and ``bannerBody`` as its body, with the actions of its ``bannerCategory``.
public struct AlertContent: Codable, Hashable, Sendable {
    public var result: ResultKind
    public var icon: Icon
    /// like `✅ !1 #7 SUCCESS`, or `💥 !1 #7: stage failed` for a stage banner; banners show it as it is
    public var headline: String
    /// the headline's label, number and result, which the alert window shows after the result's SF Symbol instead of
    /// the emoji (ALERT-02); `nil` for a stage banner, which never shows as a window
    public var headlineParts: HeadlineParts?
    /// the build's title; `nil` when it only repeats the job name
    public var title: String?
    /// one line each, like `Duration: 0h30m` and `Failed tests: 3 of 1200`
    public var facts: [String]
    /// a banner's body: the title and the facts for a finished build, the failed stages and the title for a stage banner
    public var bannerBody: String
    public var sound: Sound
    /// Open MR for a SUCCESS with an MR link, otherwise Open Build (ALERT-03)
    public var defaultAction: Action
    public var links: Links
    /// the build that Rebuild starts again: a FAILURE, UNSTABLE or ABORTED build; `nil` for other results, a stage
    /// banner and a preview, which offer no Rebuild (PIPE-09)
    public var rebuild: BuildID?
    /// the build that Hide Until the Next Build hides (HIDE-01); `nil` for a preview, which offers no live actions
    /// (ALERT-07). An alert that has it is live: it also offers Open Console.
    public var hide: BuildID?
    /// the one easter egg line under the facts, and the last line of a banner's body (EGG-11); `nil` for none, and
    /// always for a stage banner and a preview
    public var eggLine: String?
    /// the hat the alert's butler wears (EGG-03, EGG-04); `nil` for none
    public var hat: ButlerHat?
    /// the project's name, the banner's subtitle and the caption above the alert window's headline; only while there
    /// are several projects (plan Phase 13)
    public var project: String?

    public init(
        result: ResultKind,
        icon: Icon,
        headline: String,
        title: String?,
        facts: [String],
        bannerBody: String,
        sound: Sound,
        defaultAction: Action,
        links: Links,
        headlineParts: HeadlineParts? = nil,
        rebuild: BuildID? = nil,
        hide: BuildID? = nil,
        eggLine: String? = nil,
        hat: ButlerHat? = nil
    ) {
        self.eggLine = eggLine
        self.hat = hat
        self.headlineParts = headlineParts
        self.rebuild = rebuild
        self.hide = hide
        self.result = result
        self.icon = icon
        self.headline = headline
        self.title = title
        self.facts = facts
        self.bannerBody = bannerBody
        self.sound = sound
        self.defaultAction = defaultAction
        self.links = links
    }

    /// the banner's body without the egg line, which the Activity log keeps: the log records facts (ALERT-08, EGG-11)
    public var bannerBodyWithoutEggLine: String {
        guard let eggLine, bannerBody.hasSuffix("\n" + eggLine) else {
            return bannerBody
        }
        return String(bannerBody.dropLast(eggLine.count + 1))
    }

    /// the alert window's buttons: the default action first, then the others of Open build, Rebuild (only with a build
    /// to rebuild, PIPE-09), Open MR (only with an MR link) and Dismiss
    public var buttons: [Action] {
        let others = [Action.openBuild, .rebuild, .openMergeRequest, .dismiss].filter {
            $0 != defaultAction && ($0 != .openMergeRequest || links.mergeRequest != nil)
                && ($0 != .rebuild || rebuild != nil)
        }
        return [defaultAction] + others
    }

    /// the actions the alert window keeps in the context menu of its background to keep the buttons calm: Open Console
    /// and Hide Until the Next Build, for a live alert only (HIDE-01, ALERT-03)
    public var moreActions: [Action] {
        isLive ? [.openConsole, .hide] : []
    }

    /// whether the alert is about a real build: a preview isn't, and offers neither Open Console nor Hide
    public var isLive: Bool {
        hide != nil && links.console != nil
    }

    /// `build-and-mr` with an MR link, otherwise `build`; with Rebuild for a build to rebuild (PIPE-09); with Open
    /// Console and Hide for a live alert
    public var bannerCategory: BannerCategory {
        BannerCategory(mergeRequest: links.mergeRequest != nil, rebuild: rebuild != nil, live: isLive)
    }

    /// the banner's actions, in the order of its category: Open MR and Open build, or Open build alone; then Rebuild
    /// for a build to rebuild; then Open Console and Hide Until the Next Build for a live alert
    public var bannerActions: [Action] {
        BannerPayload.actions(of: bannerCategory)
    }

    /// Returns the link an action opens.
    ///
    /// - Parameter action: the button or banner action
    /// - Returns: the build, its console or the MR; `nil` for Rebuild, Hide and Dismiss, and for Open MR and Open
    ///   Console without their link
    public func url(for action: Action) -> URL? {
        switch action {
        case .openBuild: links.build
        case .openMergeRequest: links.mergeRequest
        case .openConsole: links.console
        case .rebuild, .hide, .dismiss: nil
        }
    }

    /// The result an alert is about, which sets its symbol, icon and sound (ALERT-02).
    public enum ResultKind: String, Codable, Hashable, Sendable, CaseIterable {
        case success
        case unstable
        case failure
        case aborted
        /// any other result, like `NOT_BUILT`
        case other

        public init(_ result: BuildResult) {
            switch result {
            case .success: self = .success
            case .unstable: self = .unstable
            case .failure: self = .failure
            case .aborted: self = .aborted
            default: self = .other
            }
        }

        /// the symbol the headline starts with
        public var symbol: String {
            switch self {
            case .success: "✅"
            case .unstable: "⚠️"
            case .failure: "❌"
            case .aborted: "⏹"
            case .other: "❔"
            }
        }

        public var icon: Icon {
            self == .success ? .happy : .sad
        }

        public var sound: Sound {
            switch self {
            case .success: .glass
            case .unstable: .funk
            case .failure: .basso
            case .aborted: .submarine
            case .other: .ping
            }
        }
    }

    /// The image of the alert window: `icons/happy.png` for a SUCCESS, `icons/sad.png` otherwise.
    public enum Icon: String, Codable, Hashable, Sendable, CaseIterable {
        case happy
        case sad
    }

    /// A system sound, named as in `/System/Library/Sounds`.
    public enum Sound: String, Codable, Hashable, Sendable, CaseIterable {
        case glass = "Glass"
        case funk = "Funk"
        case basso = "Basso"
        case submarine = "Submarine"
        case ping = "Ping"
    }

    /// A button of the alert window, or an action of a banner.
    public enum Action: String, Codable, Hashable, Sendable, CaseIterable {
        case openBuild
        case openMergeRequest
        /// starts the build's job again with its parameters (PIPE-09)
        case rebuild
        /// the build's console output in Jenkins
        case openConsole
        /// hides the build until the next build of its job (HIDE-01)
        case hide
        case dismiss

        /// whether the action shows its link in the app: the build and the merge request do (the user, 2026-10-30), while
        /// Jenkins' console output has no page there and opens in the browser
        public var showsInApp: Bool {
            self == .openBuild || self == .openMergeRequest
        }

        /// the button's or the banner action's title
        public var title: String {
            switch self {
            case .openBuild: "Show Build"
            case .openMergeRequest: "Show MR"
            case .rebuild: "Rebuild"
            case .openConsole: "Open Console in Jenkins"
            case .hide: "Hide Until the Next Build"
            case .dismiss: "Dismiss"
            }
        }
    }

    /// The notification category of a banner, which sets its actions.
    public enum BannerCategory: String, Codable, Hashable, Sendable, CaseIterable {
        /// Open build
        case build
        /// Open MR and Open build
        case buildAndMergeRequest = "build-and-mr"
        /// Open build and Rebuild (PIPE-09)
        case buildWithRebuild = "build-rebuild"
        /// Open MR, Open build and Rebuild (PIPE-09)
        case buildAndMergeRequestWithRebuild = "build-and-mr-rebuild"
        /// Open build, Open Console and Hide, for a live alert (the four above are the preview's, without Console and
        /// Hide)
        case buildLive = "build-live"
        /// Open MR, Open build, Open Console and Hide
        case buildAndMergeRequestLive = "build-and-mr-live"
        /// Open build, Rebuild, Open Console and Hide
        case buildWithRebuildLive = "build-rebuild-live"
        /// Open MR, Open build, Rebuild, Open Console and Hide
        case buildAndMergeRequestWithRebuildLive = "build-and-mr-rebuild-live"

        /// Returns the category with these actions.
        ///
        /// - Parameters:
        ///   - mergeRequest: whether the alert has an MR link
        ///   - rebuild: whether it has a build to rebuild
        ///   - live: whether it is about a real build, which adds Open Console and Hide
        public init(mergeRequest: Bool, rebuild: Bool, live: Bool) {
            switch (mergeRequest, rebuild, live) {
            case (false, false, false): self = .build
            case (true, false, false): self = .buildAndMergeRequest
            case (false, true, false): self = .buildWithRebuild
            case (true, true, false): self = .buildAndMergeRequestWithRebuild
            case (false, false, true): self = .buildLive
            case (true, false, true): self = .buildAndMergeRequestLive
            case (false, true, true): self = .buildWithRebuildLive
            case (true, true, true): self = .buildAndMergeRequestWithRebuildLive
            }
        }

        /// the actions of this category, in the order a banner shows them
        public var actions: [Action] {
            let mergeRequest: Bool, rebuild: Bool, live: Bool
            switch self {
            case .build: (mergeRequest, rebuild, live) = (false, false, false)
            case .buildAndMergeRequest: (mergeRequest, rebuild, live) = (true, false, false)
            case .buildWithRebuild: (mergeRequest, rebuild, live) = (false, true, false)
            case .buildAndMergeRequestWithRebuild: (mergeRequest, rebuild, live) = (true, true, false)
            case .buildLive: (mergeRequest, rebuild, live) = (false, false, true)
            case .buildAndMergeRequestLive: (mergeRequest, rebuild, live) = (true, false, true)
            case .buildWithRebuildLive: (mergeRequest, rebuild, live) = (false, true, true)
            case .buildAndMergeRequestWithRebuildLive: (mergeRequest, rebuild, live) = (true, true, true)
            }
            var actions: [Action] = mergeRequest ? [.openMergeRequest, .openBuild] : [.openBuild]
            if rebuild {
                actions.append(.rebuild)
            }
            if live {
                actions += [.openConsole, .hide]
            }
            return actions
        }
    }

    /// The headline of a finished build without its emoji: the alert window shows the result's SF Symbol before it.
    public struct HeadlineParts: Codable, Hashable, Sendable {
        /// the job's label, like `!1`, or `feature/foo` for a branch job
        public var label: String
        public var number: Int
        /// Jenkins' result as it names it, like `SUCCESS` or `NOT_BUILT`
        public var result: String

        public init(label: String, number: Int, result: String) {
            self.label = label
            self.number = number
            self.result = result
        }

        /// like `!1 #7 SUCCESS`, the number as plain digits whatever the locale
        public var text: String {
            "\(label) #\(String(number)) \(result)"
        }
    }

    /// The links an alert opens.
    public struct Links: Codable, Hashable, Sendable {
        /// the build in Jenkins, like `<job URL>/job/MR-1/7/`
        public var build: URL
        /// the merge request; `nil` for a branch build (ALERT-02)
        public var mergeRequest: URL?
        /// the build's console output, like `<build URL>console`; `nil` for a preview, which offers no live actions
        public var console: URL?

        public init(build: URL, mergeRequest: URL? = nil, console: URL? = nil) {
            self.build = build
            self.mergeRequest = mergeRequest
            self.console = console
        }
    }
}
