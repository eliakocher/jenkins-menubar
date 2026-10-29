import Foundation

extension JenkinsClient {
    /// Returns a job's last finished builds with the commit each started from, newest first (PIPE-10).
    ///
    /// One request with a `tree`: the number, result and the git `BuildData` actions of the job's recent builds. A running
    /// build is left out, and so is one without a result yet.
    ///
    /// The commit is the `marked` revision of the git `BuildData`: the commit that started the build (an MR's head
    /// commit). A job that merges the target branch into the MR before building checks out a new merge commit at each
    /// run, with a new time, so the checked-out `revision` differs between two runs of the same change while `marked`
    /// doesn't. The `revision` stands in when the answer has no `marked`. A build can carry several `BuildData` actions
    /// (a shared library's checkout adds one); the one whose remote URL contains `repository` wins, else the first.
    ///
    /// - Parameters:
    ///   - job: the job's name as in Jenkins URLs
    ///   - repository: the GitLab project's path, like `group/project`, to tell the job's repository from a library's; empty
    ///     when unknown
    ///   - limit: how many builds Jenkins lists, running ones included
    /// - Returns: the finished builds
    public func recentBuilds(job: String, repository: String = "", limit: Int = 12) async throws -> [RecentBuild] {
        // `buildsByBranchName` is a map, and it isn't certain whether the tree names its values directly or through
        // `*`; both are asked, and whichever the server follows answers.
        let marked = "buildNumber,marked[SHA1]"
        let data = "remoteUrls,lastBuiltRevision[SHA1],buildsByBranchName[\(marked),*[\(marked)]]"
        let tree = "builds[number,result,building,actions[\(data)]]{0,\(limit)}"
        let answer: HistoryAnswer = try await get(
            "/job/\(Self.safe(job))/api/json?tree=" + Self.encodeTree(tree),
            timeout: timeouts.jenkins, notFound: .gone, timedOut: .unreachable(.jenkins))
        return (answer.builds ?? []).compactMap { build in
            guard let number = build.number, number > 0, build.building != true, let result = build.result else {
                return nil
            }
            return RecentBuild(
                number: number, result: BuildResult(rawValue: result), commit: build.commit(inRepository: repository))
        }
    }

    private static func encodeTree(_ tree: String) -> String {
        tree.replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D")
            .replacingOccurrences(of: "{", with: "%7B").replacingOccurrences(of: "}", with: "%7D")
    }
}

/// A value that reads as `nil` when it has another shape, so one odd action doesn't fail the whole list.
private struct Lenient<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

private struct HistoryAnswer: Decodable {
    struct Revision: Decodable {
        var SHA1: String?
    }

    struct BuildEntry: Decodable {
        var buildNumber: Int?
        var marked: Lenient<Revision>?
    }

    struct BuildData: Decodable {
        var remoteUrls: Lenient<[String]>?
        var lastBuiltRevision: Lenient<Revision>?
        var buildsByBranchName: Lenient<[String: Lenient<BuildEntry>]>?
    }

    struct Build: Decodable {
        var number: Int?
        var result: String?
        var building: Bool?
        var actions: [Lenient<BuildData>?]?

        func commit(inRepository repository: String) -> String? {
            let all = (actions ?? []).compactMap { $0?.value }.filter {
                $0.lastBuiltRevision?.value?.SHA1 != nil || $0.buildsByBranchName?.value != nil
            }
            let needle = repository.lowercased()
            let data =
                (needle.isEmpty
                    ? nil
                    : all.first { ($0.remoteUrls?.value ?? []).contains { $0.lowercased().contains(needle) } }) ?? all.first
            guard let data else { return nil }
            let own = (data.buildsByBranchName?.value ?? [:]).values.compactMap(\.value).first {
                $0.buildNumber == number && $0.marked?.value?.SHA1 != nil
            }
            return own?.marked?.value?.SHA1 ?? data.lastBuiltRevision?.value?.SHA1
        }
    }

    var builds: [Build]?
}
