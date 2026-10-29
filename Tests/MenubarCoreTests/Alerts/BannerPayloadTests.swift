import Foundation
import Testing

@testable import MenubarCore

@Suite("BannerPayload")
struct BannerPayloadTests {
    private static let jobURL = URL(string: "https://jenkins.example.com/job/project")!
    private static let buildURL = URL(string: "https://jenkins.example.com/job/project/job/MR-1/7/")!
    private static let mergeRequest = URL(string: "https://gitlab.example.com/group/project/-/merge_requests/1")!

    private static func content(_ result: BuildResult, gitLabURL: URL? = mergeRequest) throws -> AlertContent {
        let build = Build(
            job: "MR-1", number: 7, title: "Fix the login", gitLabURL: gitLabURL, kind: .mine,
            phase: .finished(result: result, duration: 1800), startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        return try #require(
            AlertContent.finished(build, failedStages: [], links: AlertContent.links(for: build, jobURL: jobURL)))
    }

    /// Sends the payload through a user info of the kind UserNotifications hands back.
    private static func roundTrip(_ payload: BannerPayload) throws -> BannerPayload {
        let userInfo: [AnyHashable: Any] = payload.userInfo.reduce(into: [:]) { $0[$1.key] = $1.value }
        return try #require(BannerPayload(userInfo: userInfo))
    }

    @Test("PROJ-03 a banner's Hide and Rebuild keep their project; an older banner's belong to the primary one")
    func keepsTheProject() throws {
        let client = ProjectID(rawValue: "p-client")!
        let content = try Self.content(.failure)
        var payload = BannerPayload(content: content)
        payload.hide = payload.hide.map { BuildID(job: $0.job, number: $0.number, project: client) }
        payload.rebuild = payload.rebuild.map { BuildID(job: $0.job, number: $0.number, project: client) }

        let back = try Self.roundTrip(payload)
        #expect(back.hide?.project == client)
        #expect(back.rebuild?.project == client)

        var older = payload.userInfo
        older["project"] = nil
        let old = try #require(BannerPayload(userInfo: older.reduce(into: [AnyHashable: Any]()) { $0[$1.key] = $1.value }))
        #expect(old.hide == BuildID(job: "MR-1", number: 7))
        #expect(old.hide?.project == .main)
        // A build id stored before several projects reads as the primary project's.
        let decoded = try JSONDecoder().decode(BuildID.self, from: Data(#"{"job": "MR-1", "number": 7}"#.utf8))
        #expect(decoded == BuildID(job: "MR-1", number: 7, project: .main))
    }

    @Test("ALERT-08 banner click opens the default link")
    func defaultLink() throws {
        let success = try Self.roundTrip(BannerPayload(content: try Self.content(.success)))
        #expect(success.url(forAction: nil) == Self.mergeRequest)

        let failure = try Self.roundTrip(BannerPayload(content: try Self.content(.failure)))
        #expect(failure.url(forAction: nil) == Self.buildURL)

        let branch = try Self.roundTrip(BannerPayload(content: try Self.content(.success, gitLabURL: nil)))
        #expect(branch.url(forAction: nil) == Self.buildURL)

        let stage = Build(
            job: "MR-1", number: 7, title: "Fix the login", gitLabURL: Self.mergeRequest, kind: .mine,
            phase: .running, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let stageBanner = try Self.roundTrip(
            BannerPayload(content: AlertContent.stageFailed(stage, failedStages: ["build"], buildURL: Self.buildURL)))
        #expect(stageBanner.category == .buildLive)
        #expect(stageBanner.url(forAction: nil) == Self.buildURL)
    }

    @Test("ALERT-08 banner actions open the build and the MR")
    func actions() throws {
        let withMR = try Self.roundTrip(BannerPayload(content: try Self.content(.success)))
        #expect(withMR.category == .buildAndMergeRequestLive)
        #expect(BannerPayload.actions(of: withMR.category) == [.openMergeRequest, .openBuild, .openConsole, .hide])
        #expect(withMR.url(forAction: AlertContent.Action.openBuild.rawValue) == Self.buildURL)
        #expect(withMR.url(forAction: AlertContent.Action.openMergeRequest.rawValue) == Self.mergeRequest)
        #expect(withMR.rebuild(forAction: AlertContent.Action.rebuild.rawValue) == nil)

        // A failure's banner has Rebuild after the others, and its payload names the build (PIPE-09).
        let failure = try Self.roundTrip(BannerPayload(content: try Self.content(.failure)))
        #expect(failure.category.rawValue == "build-and-mr-rebuild-live")
        #expect(
            BannerPayload.actions(of: failure.category) == [.openMergeRequest, .openBuild, .rebuild, .openConsole, .hide])
        #expect(failure.rebuild(forAction: AlertContent.Action.rebuild.rawValue) == BuildID(job: "MR-1", number: 7))
        #expect(failure.rebuild(forAction: nil) == nil)
        #expect(failure.url(forAction: AlertContent.Action.rebuild.rawValue) == nil)
        #expect(failure.url(forAction: nil) == Self.buildURL)

        let withoutMR = try Self.roundTrip(BannerPayload(content: try Self.content(.failure, gitLabURL: nil)))
        #expect(withoutMR.category.rawValue == "build-rebuild-live")
        #expect(BannerPayload.actions(of: withoutMR.category) == [.openBuild, .rebuild, .openConsole, .hide])
        #expect(withoutMR.url(forAction: AlertContent.Action.openBuild.rawValue) == Self.buildURL)
        // Not an action of this banner, or none at all.
        #expect(withoutMR.url(forAction: AlertContent.Action.openMergeRequest.rawValue) == nil)
        #expect(withoutMR.url(forAction: AlertContent.Action.dismiss.rawValue) == nil)
        #expect(withoutMR.url(forAction: "com.apple.UNNotificationDismissActionIdentifier") == nil)
    }

    /// Every action of a banner reaches its own handler: a link opens, Rebuild and Hide name the build, and what isn't
    /// an action of the banner does nothing.
    @Test("ALERT-08 a banner's action reaches the right handler")
    func intents() throws {
        let build = BuildID(job: "MR-1", number: 7)
        let failure = try Self.roundTrip(BannerPayload(content: try Self.content(.failure)))
        let console = Self.buildURL.appending(path: "console")
        #expect(failure.intent(forAction: nil) == .open(Self.buildURL))
        #expect(failure.intent(forAction: "openBuild") == .open(Self.buildURL))
        #expect(failure.intent(forAction: "openMergeRequest") == .open(Self.mergeRequest))
        #expect(failure.intent(forAction: "openConsole") == .open(console))
        #expect(failure.intent(forAction: "rebuild") == .rebuild(build))
        #expect(failure.intent(forAction: "hide") == .hide(build))
        #expect(failure.intent(forAction: "dismiss") == nil)
        #expect(failure.intent(forAction: "com.apple.UNNotificationDismissActionIdentifier") == nil)

        // A success has no Rebuild, but still Console and Hide.
        let success = try Self.roundTrip(BannerPayload(content: try Self.content(.success, gitLabURL: nil)))
        #expect(success.intent(forAction: "rebuild") == nil)
        #expect(success.intent(forAction: "openConsole") == .open(console))
        #expect(success.intent(forAction: "hide") == .hide(build))
    }

    @Test("ALERT-07 a preview's banner offers neither Console nor Hide nor Rebuild")
    func previewBanner() throws {
        let team = TeamValues(
            jenkinsJobURL: Self.jobURL.absoluteString, gitLabURL: "https://gitlab.example.com", gitLabProject: "group/project")
        for sample in BuildAlert.PreviewSample.allCases {
            let alert = try #require(BuildAlert.preview(sample, team: team))
            let payload = try Self.roundTrip(BannerPayload(content: alert.content))
            #expect(payload.category == .buildAndMergeRequest)
            for action in ["openConsole", "hide", "rebuild"] {
                #expect(payload.intent(forAction: action) == nil)
            }
        }
    }

    @Test("ALERT-08 a banner without a payload opens nothing")
    func foreignUserInfo() {
        #expect(BannerPayload(userInfo: [:]) == nil)
        #expect(BannerPayload(userInfo: ["category": "build", "defaultAction": "openBuild"]) == nil)
        #expect(BannerPayload(userInfo: ["category": "other", "defaultAction": "openBuild", "build": "https://example.com"]) == nil)
    }
}
