import Foundation
import MenubarCore
import SwiftUI
import Testing

@testable import MenubarUI

/// The two lines of an opened item's sidebar row (WIN-06).
@Suite("Opened item rows")
@MainActor
struct OpenedItemRowDetailsTests {
    private static let url = URL(string: "https://gitlab.example.com/g/p/-/x")!

    private func item(_ kind: OpenedItem.Kind, _ iid: Int, _ title: String?, job: String? = nil) -> OpenedItem {
        OpenedItem(kind: kind, project: "g/p", iid: iid, webURL: Self.url, title: title, openedAt: Date(), job: job)
    }

    @Test("WIN-06 a row's chips: a merge request's number and the work item its title began with, a work item's number, a build's number and its MR")
    func chips() {
        let mergeRequest = OpenedItemRowDetails.make(item: item(.mergeRequest, 12, "#77 Add the target"))
        #expect(mergeRequest.title == "Add the target")
        #expect(mergeRequest.chips == [.mergeRequest(text: "!12", help: nil), .workItem(text: "#77", help: nil)])

        let workItem = OpenedItemRowDetails.make(item: item(.workItem, 5, "Fix the dialog"))
        #expect(workItem.title == "Fix the dialog")
        #expect(workItem.chips == [.workItem(text: "#5", help: nil)])

        let build = OpenedItemRowDetails.make(item: item(.build, 3, "Fix the dialog", job: "MR-12"))
        #expect(build.chips == [.build(text: "#3"), .mergeRequest(text: "!12", help: nil)])
        let branchBuild = OpenedItemRowDetails.make(item: item(.build, 3, nil, job: "release%252F2.4"))
        #expect(branchBuild.chips == [.build(text: "#3")])
    }
}
