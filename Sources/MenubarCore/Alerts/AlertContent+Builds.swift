import Foundation

extension AlertContent {
    /// Returns the content of the alert for a finished build (ALERT-02).
    ///
    /// - Parameters:
    ///   - build: the build, which has finished
    ///   - failedStages: the build's failed stages, as far as known
    ///   - links: the build and its MR, from ``links(for:jobURL:)``
    /// - Returns: the content; `nil` while the build is running
    public static func finished(_ build: Build, failedStages: [String], links: Links) -> AlertContent? {
        guard case .finished(let result, let duration) = build.phase else {
            return nil
        }
        let kind = ResultKind(result)
        let title = displayTitle(of: build)
        var facts = ["Duration: \(durationText(duration))"]
        if let counts = build.testCounts, counts.failed > 0 {
            facts.append("Failed tests: \(counts.failed) of \(counts.total)")
        }
        if result != .success, !failedStages.isEmpty {
            facts.append("Failed stages: \(failedStages.joined(separator: ", "))")
        }
        return AlertContent(
            result: kind,
            icon: kind.icon,
            headline: "\(kind.symbol) \(build.label) #\(build.number) \(result)",
            title: title,
            facts: facts,
            bannerBody: ([title].compactMap { $0 } + facts).joined(separator: "\n"),
            sound: kind.sound,
            defaultAction: kind == .success && links.mergeRequest != nil ? .openMergeRequest : .openBuild,
            links: links,
            headlineParts: HeadlineParts(label: build.label, number: build.number, result: result.rawValue),
            rebuild: [.failure, .unstable, .aborted].contains(kind) ? build.id : nil,
            hide: build.id
        )
    }

    /// Returns the content of the banner for a running build with a new set of failed stages (ALERT-05).
    ///
    /// The banner offers Open build, Open Console and Hide, and sounds like a failure.
    ///
    /// - Parameters:
    ///   - build: the running build
    ///   - failedStages: all of its failed stages known now, in order
    ///   - buildURL: the build in Jenkins
    /// - Returns: the content
    public static func stageFailed(_ build: Build, failedStages: [String], buildURL: URL) -> AlertContent {
        let title = displayTitle(of: build)
        let stages = failedStages.joined(separator: ", ")
        return AlertContent(
            result: .failure,
            icon: .sad,
            headline: "💥 \(build.label) #\(build.number): stage failed",
            title: title,
            facts: ["Failed stages: \(stages)"],
            bannerBody: ([stages] + [title].compactMap { $0 }).joined(separator: "\n"),
            sound: .basso,
            defaultAction: .openBuild,
            links: Links(build: buildURL, console: buildURL.appending(path: "console")),
            hide: build.id
        )
    }

    /// Returns the links of a build's alert.
    ///
    /// - Parameters:
    ///   - build: the build
    ///   - jobURL: the team's Jenkins multibranch job
    /// - Returns: the build at `<job URL>/job/<job>/<N>/`, and the MR when the build's GitLab link points to one
    public static func links(for build: Build, jobURL: URL) -> Links {
        let page = buildURL(job: build.job, number: build.number, jobURL: jobURL)
        return Links(build: page, mergeRequest: mergeRequestLink(of: build), console: page.appending(path: "console"))
    }

    /// Returns a build's page in Jenkins.
    ///
    /// The job name is already encoded the way Jenkins' URLs have it, so it is joined as text: appending it as a path
    /// would encode its `%` once more.
    ///
    /// - Parameters:
    ///   - job: the job's name as in Jenkins URLs
    ///   - number: the build number
    ///   - jobURL: the team's Jenkins multibranch job
    /// - Returns: `<job URL>/job/<job>/<N>/`
    public static func buildURL(job: String, number: Int, jobURL: URL) -> URL {
        var root = jobURL.absoluteString
        while root.hasSuffix("/") {
            root.removeLast()
        }
        return URL(string: "\(root)/job/\(job)/\(number)/") ?? jobURL
    }

    /// Returns a duration as hours and two-digit minutes, rounded down, like `0h30m` or `4h12m` (PIPE-02).
    ///
    /// - Parameter seconds: the duration; below 0 counts as 0
    /// - Returns: the text
    public static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let minutes = total % 3600 / 60
        return "\(total / 3600)h\(minutes < 10 ? "0" : "")\(minutes)m"
    }

    /// The build's title, unless it is missing or only repeats the job's name.
    static func displayTitle(of build: Build) -> String? {
        guard let title = build.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
            title != build.job, title != build.label
        else { return nil }
        return title
    }

    /// The MR of a build, which only a GitLab link to a merge request gives; a branch build has none.
    private static func mergeRequestLink(of build: Build) -> URL? {
        guard let url = build.gitLabURL, url.absoluteString.contains("/merge_requests/") else {
            return nil
        }
        return url
    }
}

extension BuildAlert {
    /// The two sample alerts that Settings previews (ALERT-07).
    public enum PreviewSample: String, Codable, Hashable, Sendable, CaseIterable {
        case success
        case failure
    }

    /// Returns a sample alert for Settings → General → Preview (ALERT-07).
    ///
    /// It links to the job as the build and to the project's MR list as the MR, like the old tool's `--test`.
    ///
    /// - Parameters:
    ///   - sample: the success or the failure sample
    ///   - team: the team values, for the links
    ///   - id: the alert's id
    /// - Returns: the alert; `nil` while the team's Jenkins job URL isn't set, since the alert would link nowhere
    public static func preview(_ sample: PreviewSample, team: TeamValues, id: UUID = UUID()) -> BuildAlert? {
        guard let jobURL = team.jenkinsJob else {
            return nil
        }
        var mergeRequests: URL?
        if let gitLab = team.gitLab, !team.gitLabProject.isEmpty {
            mergeRequests = URL(string: "\(gitLab.absoluteString)/\(team.gitLabProject)/-/merge_requests")
        }
        let build: Build
        switch sample {
        case .success:
            build = Build(
                job: "MR-123", number: 2, title: "This is what a finished build looks like.", gitLabURL: mergeRequests,
                kind: .mine, phase: .finished(result: .success, duration: 4 * 3600 + 12 * 60), startedAt: Date())
        case .failure:
            build = Build(
                job: "MR-123", number: 2, title: "This is what a failed build looks like.", gitLabURL: mergeRequests,
                kind: .mine, phase: .finished(result: .failure, duration: 2 * 3600 + 31 * 60), startedAt: Date(),
                stages: [Stage(name: "integration-tests", status: .failed, duration: 0)],
                testCounts: TestCounts(failed: 3, total: 1200))
        }
        let links = AlertContent.Links(build: jobURL, mergeRequest: mergeRequests)
        guard var content = AlertContent.finished(build, failedStages: build.failedStages ?? [], links: links) else {
            return nil
        }
        // The sample build is made up: Rebuild would start a real job (PIPE-09), and Open Console and Hide would act
        // on a build that doesn't exist.
        content.rebuild = nil
        content.hide = nil
        return BuildAlert(id: id, kind: .preview, build: build, content: content)
    }

    /// how the Activity log marks the alert's result (ALERT-08): `ok:SUCCESS`, `warning:UNSTABLE`, `failed:FAILURE`,
    /// `neutral:ABORTED` or `neutral:<other>`; `failed:FAILED` for a stage banner
    public var outcome: ActivityEntry.Outcome {
        if kind == .stageFailed {
            return .failed("FAILED")
        }
        let result = build.result?.rawValue ?? ""
        switch content.result {
        case .success: return .ok(result)
        case .unstable: return .warning(result)
        case .failure: return .failed(result)
        case .aborted, .other: return .neutral(result)
        }
    }
}
