import Foundation
import Testing

@testable import MenubarCore

@Suite("Build")
struct BuildTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private static func running(estimate: TimeInterval?) -> Build {
        Build(job: "MR-1", number: 7, kind: .mine, phase: .running, startedAt: start, estimatedDuration: estimate)
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

    @Test("the time left never goes below zero and the progress is capped at 1, and without an estimate there is neither")
    func remainingAndProgress() {
        let build = Self.running(estimate: 600)

        #expect(build.remaining(at: Self.start.addingTimeInterval(150)) == 450)
        #expect(build.progress(at: Self.start.addingTimeInterval(150)) == 0.25)
        #expect(build.remaining(at: Self.start.addingTimeInterval(900)) == 0)
        #expect(build.progress(at: Self.start.addingTimeInterval(900)) == 1)
        #expect(build.elapsed(at: Self.start.addingTimeInterval(-5)) == 0)

        let noEstimate = Self.running(estimate: nil)
        #expect(noEstimate.remaining(at: Self.start.addingTimeInterval(60)) == nil)
        #expect(noEstimate.progress(at: Self.start.addingTimeInterval(60)) == nil)
    }
}
