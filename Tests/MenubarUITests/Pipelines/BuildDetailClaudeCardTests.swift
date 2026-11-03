import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

/// AI-10: the build detail's Claude card shows for a build of any result, with Why Did It Fail? only on a red one.
@Suite("Build detail Claude card")
@MainActor
struct BuildDetailClaudeCardTests {
    private static let now = Date(timeIntervalSince1970: 1_800_001_000)
    private static let started = Date(timeIntervalSince1970: 1_800_000_000)

    private static func detail(_ phase: BuildPhase) -> BuildDetailModel {
        let build = Build(job: "MR-42", number: 7, title: "Add the item count", kind: .mine, phase: phase, startedAt: started)
        return BuildDetailModel(row: BuildRowModel(build: build, now: now, jobURL: nil), now: now)
    }

    @Test(
        "AI-10 the Claude card shows for green, red, unstable, aborted and running builds; Why Did It Fail? only for red and unstable",
        arguments: [
            (BuildPhase.finished(result: .success, duration: 600), true, false),
            (.finished(result: .failure, duration: 600), true, true),
            (.finished(result: .unstable, duration: 600), true, true),
            (.finished(result: .aborted, duration: 600), true, false),
            (.running, true, false),
        ])
    func cardForEveryBuild(phase: BuildPhase, card: Bool, why: Bool) {
        let model = Self.detail(phase)
        #expect(model.showsClaudeCard == card)
        #expect(model.canExplain == why)
    }

    @Test("AI-10 a waiting job has no build to ask about, so no Claude card")
    func noCardForAWaitingJob() {
        let f = Fixtures()
        let model = BuildDetailModel(job: f.waitingJob.job, data: f.pipelines(waiting: [f.waitingJob]))
        #expect(model?.showsClaudeCard == false)
    }
}
