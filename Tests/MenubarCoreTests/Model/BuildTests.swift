import Foundation
import Testing

@testable import MenubarCore

@Suite("Build")
struct BuildTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private static func running(estimate: TimeInterval?, stages: [Stage]? = nil) -> Build {
        Build(job: "MR-1", number: 7, kind: .mine, phase: .running, startedAt: start, estimatedDuration: estimate,
              stages: stages)
    }

    @Test("a job's label is !N for an MR and the twice-decoded name for a branch")
    func labels() {
        #expect(Build.label(forJob: "MR-12") == "!12")
        #expect(Build.label(forJob: "feature%252Ffoo") == "feature/foo")
        #expect(Build.label(forJob: "develop") == "develop")
        #expect(Build.label(forJob: "MR-") == "MR-")
        #expect(Build.label(forJob: "MR-1a") == "MR-1a")
    }

    @Test("only MR-<digits> jobs have a merge request iid")
    func mergeRequestIID() {
        #expect(Build.mergeRequestIID(forJob: "MR-12") == 12)
        #expect(Build.mergeRequestIID(forJob: "mr-12") == nil)
        #expect(Build.mergeRequestIID(forJob: "MR-١٢") == nil)
        #expect(Build.mergeRequestIID(forJob: "develop") == nil)
    }

    @Test("the time left never goes below zero and the progress is capped at 1")
    func remainingAndProgress() {
        let build = Self.running(estimate: 600)

        #expect(build.remaining(at: Self.start.addingTimeInterval(150)) == 450)
        #expect(build.progress(at: Self.start.addingTimeInterval(150)) == 0.25)
        #expect(build.remaining(at: Self.start.addingTimeInterval(900)) == 0)
        #expect(build.progress(at: Self.start.addingTimeInterval(900)) == 1)
        #expect(build.elapsed(at: Self.start.addingTimeInterval(-5)) == 0)
    }

    @Test("without an estimate there is no time left and no progress")
    func noEstimate() {
        let build = Self.running(estimate: nil)

        #expect(build.remaining(at: Self.start.addingTimeInterval(60)) == nil)
        #expect(build.progress(at: Self.start.addingTimeInterval(60)) == nil)
    }

    @Test("running and failed stages keep their order, and unknown stages stay unknown")
    func stages() {
        let build = Self.running(estimate: nil, stages: [
            Stage(name: "checkout", status: .success, duration: 3),
            Stage(name: "build", status: .failed, duration: 60),
            Stage(name: "tests", status: .inProgress, duration: 10),
            Stage(name: "lint", status: .failed, duration: 5),
        ])

        #expect(build.runningStages == ["tests"])
        #expect(build.failedStages == ["build", "lint"])
        #expect(Self.running(estimate: nil).failedStages == nil)
        #expect(Self.running(estimate: nil).runningStages.isEmpty)
    }

    @Test("a finished build has its result and the time it finished")
    func finished() {
        let build = Build(job: "MR-1", number: 7, kind: .watched,
                          phase: .finished(result: .failure, duration: 1800), startedAt: Self.start)

        #expect(build.result == .failure)
        #expect(build.finishedAt == Self.start.addingTimeInterval(1800))
        #expect(!build.isRunning)
        #expect(build.id == BuildID(job: "MR-1", number: 7))
        #expect(build.id.description == "MR-1 #7")
        #expect(build.id.label == "!1 #7")
        #expect(Self.running(estimate: nil).result == nil)
        #expect(Self.running(estimate: nil).finishedAt == nil)
    }
}
