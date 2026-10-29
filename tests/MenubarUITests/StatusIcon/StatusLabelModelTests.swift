import MenubarCore
import SwiftUI
import Testing

@testable import MenubarUI

/// The model behind the status label (Task 4.9).
@Suite("StatusLabelModel")
struct StatusLabelModelTests {
    @Test("PIPE-05 idle shows the template image")
    func idle() {
        let model = StatusLabelModel()
        #expect(model.parts == [.identity])
        #expect(model.rendering == .identity)
    }

    @Test("PIPE-05 counts running failed unstable and successful builds in that order")
    func countsInOrder() {
        let model = StatusLabelModel(counts: BuildCounts(running: 2, failed: 1, unstable: 1, successful: 3))
        #expect(model.parts == [.count(.running, 2), .count(.failed, 1), .count(.unstable, 1), .count(.successful, 3)])
        #expect(model.rendering == .image)
        #expect(model.parts.compactMap(StatusLabelModel.symbol(of:)) == [
            "hourglass", "xmark.circle.fill", "exclamationmark.triangle", "checkmark.circle",
        ])
        // A count of 0 is left out, and large counts are exact.
        #expect(StatusLabelModel(counts: BuildCounts(running: 12, successful: 1000)).parts == [.count(.running, 12), .count(.successful, 1000)])
    }

    @Test("PIPE-05 problem marker shows with and without counts")
    func problemMarker() {
        let alone = StatusLabelModel(problem: .jenkins)
        #expect(alone.parts == [.identity, .problem])
        // The butler leads markers without counts.
        #expect(alone.rendering == .image)

        let withCounts = StatusLabelModel(problem: .offline, counts: BuildCounts(running: 1, failed: 1))
        #expect(withCounts.parts == [.problem, .count(.running, 1), .count(.failed, 1)])
        #expect(withCounts.rendering == .image)

        #expect(StatusLabelModel(problem: .teamValues).parts == [.identity, .problem])
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

    @Test("PIPE-05 color style uses colored symbols")
    func colorStyle() {
        let counts = BuildCounts(running: 2, failed: 1, unstable: 1, successful: 3)
        let color = StatusLabelModel(problem: .jenkins, counts: counts, style: .color)
        #expect(color.color(of: .problem) == .red)
        #expect(color.color(of: .count(.failed, 1)) == .red)
        #expect(color.color(of: .count(.unstable, 1)) == .orange)
        #expect(color.color(of: .count(.successful, 3)) == .green)
        // Running and the numbers keep the label color.
        #expect(color.color(of: .count(.running, 2)) == nil)

        // Monochrome tints everything.
        let monochrome = StatusLabelModel(problem: .jenkins, counts: counts, style: .monochrome)
        #expect(monochrome.parts.allSatisfy { monochrome.color(of: $0) == nil })
        // The problem marker is red without counts too.
        let markers = StatusLabelModel(problem: .jenkins, style: .color)
        #expect(markers.color(of: .problem) == .red)
    }
}
