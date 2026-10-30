import Foundation
import Testing

@testable import MenubarCore

/// The approval rules as the merge request detail lists them (MR-06).
@Suite("Approval rule list")
struct ApprovalRuleListTests {
    private static func person(_ username: String) -> MergeRequest.Person {
        MergeRequest.Person(username: username, name: username.capitalized)
    }

    @Test("MR-06 the rules show once each, open first, with file patterns named")
    func list() {
        let list = ApprovalRuleList([
            .init(name: "*", required: 1, approvedBy: [Self.person("akim")], isSatisfied: true),
            .init(name: "*.ts", required: 1, approvedBy: [Self.person("slee")], isSatisfied: true),
            .init(name: "Backend Review", required: 2, approvedBy: [Self.person("akim")], isSatisfied: false),
            .init(name: "Optional", required: 0, isSatisfied: true),
            // The same pattern in a second CODEOWNERS section: one line, open while either is.
            .init(name: "*.ts", required: 2, approvedBy: [Self.person("slee"), Self.person("cnovak")], isSatisfied: false),
            .init(name: "/docs/", required: 1, isSatisfied: false),
        ])
        #expect(list.lines.map(\.name) == [.files("*.ts"), .named("Backend Review"), .files("/docs/"), .allFiles])
        #expect(list.lines.map(\.name.text) == ["Files matching *.ts", "Backend Review", "Files matching /docs/", "All files"])
        #expect(list.lines.map(\.progress) == ["2 of 2", "1 of 2", "0 of 1", "1 of 1"])
        #expect(list.lines[0].approvedBy.map(\.username) == ["slee", "cnovak"])
        #expect(list.openCount == 3)
    }

    @Test(
        "MR-06 a rule's name is a file pattern only when it looks like one",
        arguments: [
            ("Code Owners", ApprovalRuleList.Name.named("Code Owners")),
            ("Coverage-Check", .named("Coverage-Check")),
            ("v1.0 approvers", .named("v1.0 approvers")),
            ("Package.swift", .files("Package.swift")),
            ("src/app/", .files("src/app/")),
            ("/**/*", .allFiles),
            ("  ", .named("Unnamed rule")),
        ])
    func name(_ name: String, expected: ApprovalRuleList.Name) {
        #expect(ApprovalRuleList.Name(name) == expected)
    }
}
