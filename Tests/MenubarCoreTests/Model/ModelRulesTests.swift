import Foundation
import Testing

@testable import MenubarCore

@Suite("Model rules")
struct ModelRulesTests {
    @Test("only Jenkins and team problems mark the status icon, GitLab problems leave it alone")
    func problems() {
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
}
