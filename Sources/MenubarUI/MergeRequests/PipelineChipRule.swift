import MenubarCore
import SwiftUI

/// Which chip tells the merge request's pipeline state in its header (MR-14). In this setup GitLab's pipeline is Jenkins
/// reporting back, so the GitLab pipeline and the Jenkins build say the same thing, in words that can differ ("failed",
/// "Unstable"): the header shows one chip for it, never both.
enum MergeRequestPipelineChip: Hashable, Sendable {
    /// the Jenkins build's chip, which shows the build in Pipelines; `help` is its tooltip, with GitLab's pipeline state
    /// when that is another word
    case jenkins(help: String)
    /// the GitLab pipeline's chip, for a merge request whose Jenkins build the app doesn't know
    case gitLab
    /// "No pipeline"
    case none
    /// no chip: the status badge already says what the pipeline does ("Pipeline failed", "Pipeline running")
    case hidden

    /// Returns the chip to show.
    ///
    /// - Parameter model: the merge request's detail
    /// - Returns: the Jenkins chip when the build is known, else the GitLab pipeline's, else "No pipeline"; the GitLab
    ///   pipeline's chip stays away while the badge says it
    static func of(_ model: MergeRequestDetailModel) -> MergeRequestPipelineChip {
        if let build = model.jenkinsBuild {
            return .jenkins(help: jenkinsHelp(build, gitLab: model.pipeline))
        }
        guard model.pipeline != nil else { return .none }
        return statusNamesPipeline(model.status.text) ? .hidden : .gitLab
    }

    /// Returns whether a status badge's text is about the pipeline: "Pipeline failed", also after "Review requested · ".
    static func statusNamesPipeline(_ text: String) -> Bool {
        MergeRequestStatus.textNamesPipeline(text)
    }

    /// "Show build #4 in Pipelines", and "GitLab's pipeline: failed" when GitLab says another word than the build does.
    static func jenkinsHelp(_ build: MergeRequestDetailModel.JenkinsBuildFact, gitLab: MergeRequestDetailModel.PipelineFact?) -> String {
        var help = "Show build #\(String(build.number)) in Pipelines"
        if let gitLab, !build.state.matches(gitLabWord: gitLab.word) {
            help += " (GitLab's pipeline: \(gitLab.word))"
        }
        return help
    }
}

extension BuildState {
    /// Whether GitLab's pipeline word is this state in GitLab's words; an unstable build has no word of its own there.
    func matches(gitLabWord word: String) -> Bool {
        switch self {
        case .running: word == "running"
        case .successful: word == "success"
        case .failed: word == "failed"
        case .aborted: word == "canceled"
        case .unstable, .other: false
        }
    }
}
