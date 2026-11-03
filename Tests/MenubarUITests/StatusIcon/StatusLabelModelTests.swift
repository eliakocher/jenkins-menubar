import MenubarCore
import SwiftUI
import Testing

@testable import MenubarUI

/// The model behind the status label (Task 4.9).
@Suite("StatusLabelModel")
struct StatusLabelModelTests {
    @Test("PIPE-05 counts running failed unstable and successful builds in that order")
    func countsInOrder() {
        let model = StatusLabelModel(counts: BuildCounts(running: 2, failed: 1, unstable: 1, successful: 3))
        #expect(model.parts == [.count(.running, 2), .count(.failed, 1), .count(.unstable, 1), .count(.successful, 3)])
        // A count of 0 is left out, and large counts are exact.
        #expect(StatusLabelModel(counts: BuildCounts(running: 12, successful: 1000)).parts == [.count(.running, 12), .count(.successful, 1000)])
    }

    @Test("PIPE-05 GitLab problems leave the icon alone")
    func gitLabProblems() {
        for problem in [Problem.rejectedToken(.gitLab), .unreachable(.gitLab), .missingScope, .workItemsFailed(status: 502)] {
            #expect(StatusLabelModel.kind(of: problem) == nil)
        }
        #expect(StatusLabelModel.kind(of: .unreachable(.jenkins)) == .jenkins)
        #expect(StatusLabelModel.kind(of: .noToken(.jenkins)) == .jenkins)
        #expect(StatusLabelModel.kind(of: .teamValuesMissing) == .teamValues)
        #expect(StatusLabelModel.kind(of: .offline) == .offline)
        #expect(StatusLabelModel.kind(of: nil) == nil)
    }
}

/// The red dot of the Inbox (Task 7.03, INBOX-09).
@Suite("StatusLabelModel Inbox dot")
struct StatusLabelInboxDotTests {
    @Test("INBOX-09 the menu bar shows a red dot, never a number, while the Inbox has items that count")
    func dot() {
        // Alone it joins the butler; with counts it comes last.
        let idle = StatusLabelModel(hasInboxItems: true)
        #expect(idle.parts == [.identity, .inboxDot])
        #expect(idle.rendering == .image)
        let busy = StatusLabelModel(counts: BuildCounts(failed: 1), hasInboxItems: true)
        #expect(busy.parts == [.count(.failed, 1), .inboxDot])
        // Nothing in the Inbox: the butler alone, as before.
        #expect(StatusLabelModel().parts == [.identity])
        #expect(StatusLabelModel().rendering == .identity)
        #expect(StatusLabelModel.symbol(of: .inboxDot) == nil)
    }
}
