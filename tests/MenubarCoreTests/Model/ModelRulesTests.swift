import Foundation
import Testing

@testable import MenubarCore

@Suite("Model rules")
struct ModelRulesTests {
    @Test("problems have the texts of FEATURES.md, and only GitLab problems leave the status icon alone")
    func problems() {
        #expect(Problem.noToken(.jenkins).message == "No Jenkins token: add it in Settings → Accounts")
        #expect(Problem.rejectedToken(.jenkins).message == "Jenkins rejected the token")
        #expect(Problem.rejectedToken(.gitLab).message
            == "GitLab rejected the token (expired, or without the api scope?)")
        #expect(Problem.unknownJob.message == "Jenkins does not know the job: check the job URL in Team")
        #expect(Problem.unreachable(.jenkins).message == "Jenkins unreachable (VPN?)")
        #expect(Problem.unreachable(.gitLab).message == "GitLab unreachable")
        #expect(Problem.httpStatus(.jenkins, status: 500).message == "Jenkins answered with HTTP 500")
        #expect(Problem.httpStatus(.gitLab, status: 502).message == "GitLab answered with HTTP 502")
        #expect(Problem.graphQLErrors(messages: ["Field 'x' doesn't exist", "other"]).message == "Field 'x' doesn't exist")
        #expect(Problem.teamValuesMissing.message == "Fill in the team settings: your Jenkins job and GitLab project")

        #expect(Problem.unreachable(.jenkins).marksStatusIcon)
        #expect(Problem.slow.marksStatusIcon)
        #expect(Problem.teamValuesMissing.marksStatusIcon)
        #expect(Problem.teamValuesMissing.server == nil)
        #expect(!Problem.unreachable(.gitLab).marksStatusIcon)
        #expect(!Problem.missingScope.marksStatusIcon)
        #expect(!Problem.graphQLErrors(messages: []).marksStatusIcon)
    }

    @Test("team values are trimmed and the URLs lose their trailing slash")
    func normalizedTeamValues() {
        let values = TeamValues(jenkinsJobURL: " https://jenkins.example.com/job/a%20b/job/c%252Fd// ",
                                gitLabURL: "https://gitlab.example.com/\n", gitLabProject: " g/p ",
                                committedLabel: " committed ", slotLabelPrefix: "slot:: ", ignoredMergeRequestPrefix: "\t[cascade]")
            .normalized()

        #expect(values == TeamValues(jenkinsJobURL: "https://jenkins.example.com/job/a%20b/job/c%252Fd",
                                     gitLabURL: "https://gitlab.example.com", gitLabProject: "g/p",
                                     committedLabel: "committed", slotLabelPrefix: "slot::", ignoredMergeRequestPrefix: "[cascade]"))
        #expect(values.jenkinsJob?.absoluteString == "https://jenkins.example.com/job/a%20b/job/c%252Fd")
    }

    @Test("missing team values are the required ones left empty, and only web URLs count as URLs")
    func missingTeamValues() {
        #expect(TeamValues().missing == [.jenkinsJobURL, .gitLabURL, .gitLabProject])
        #expect(TeamValues(jenkinsJobURL: "x", gitLabURL: "y", gitLabProject: "z").missing.isEmpty)
        #expect(TeamValues(jenkinsJobURL: "ftp://jenkins.example.com").jenkinsJob == nil)
        #expect(TeamValues(jenkinsJobURL: "jenkins.example.com/job/x").jenkinsJob == nil)
        #expect(TeamValues(gitLabURL: "HTTPS://gitlab.example.com").gitLab != nil)
    }

    @Test("my review state is unreviewed when I'm not a reviewer")
    func reviewState() {
        let mergeRequest = MergeRequest(
            iid: 1, title: "t", webURL: URL(string: "https://gitlab.example.com/g/p/-/merge_requests/1")!, reference: "g/p!1",
            author: MergeRequest.Person(username: "jdoe", name: "Jane"),
            reviewers: [MergeRequest.Reviewer(username: "me", reviewState: .approved, approved: true)],
            updatedAt: Date(), roles: [.reviewRequested])

        #expect(mergeRequest.reviewState(of: "me") == .approved)
        #expect(mergeRequest.reviewState(of: "someone") == .unreviewed)
        #expect([MergeRequest.ReviewState.unreviewed, .reviewStarted, .unapproved].allSatisfy { $0.isPending })
        #expect(![MergeRequest.ReviewState.approved, .reviewed, .requestedChanges].contains { $0.isPending })
    }

    @Test("a work item has its iid, knows an epic, and finds its slot")
    func workItems() {
        let url = URL(string: "https://gitlab.example.com/g/p/-/issues/12")!
        let item = WorkItem(reference: "g/p#12", title: "t", webURL: url,
                            labels: [Label(title: "type::bug"), Label(title: "slot::Q1"), Label(title: "slot::Q2")],
                            updatedAt: Date())

        #expect(item.iid == "12")
        #expect(!item.isEpic)
        #expect(WorkItem(reference: "g&3", title: "t", webURL: url, type: .epic, updatedAt: Date()).isEpic)
        #expect(WorkItem(reference: "g&3", title: "t", webURL: url, updatedAt: Date()).iid == "3")
        #expect(item.slot(prefix: "slot::") == "Q1")
        #expect(item.slot(prefix: "") == nil)
        #expect(item.slot(prefix: "due::") == nil)
    }
}
