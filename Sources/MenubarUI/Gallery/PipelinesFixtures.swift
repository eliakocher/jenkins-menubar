#if DEBUG
import Foundation
import MenubarCore

/// The failed tests of the gallery's builds: made up, with the shapes of Jenkins' reports.
extension FailedTestsFixtures {
    private static func test(
        _ className: String, _ name: String, _ message: String?, regression: Bool = false
    ) -> FailedTest {
        FailedTest(className: className, name: name, status: regression ? .regression : .failed, message: message)
    }

    /// the tests of !16 #3 and !9 #11, and one test for any other build
    static let standard = FailedTestsFixtures(
        states: [
            BuildID(job: "MR-16", number: 3): .loaded([
                test("com.example.export.ExportRetryTest", "retriesAfterATimeout", "expected: <3> but was: <1>", regression: true),
                test("com.example.export.ExportRetryTest", "givesUpAfterTheLastRetry", "Expected exception of type ExportFailedException"),
                test("com.example.export.ExportSchedulerTest", "runsEveryNightAtTwo", nil),
            ]),
            BuildID(job: "MR-9", number: 11): .loaded([
                test("com.example.i18n.DatePickerLabelsTest", "usesTheGermanMonthNames", "expected: <März> but was: <Maerz>"),
                test("com.example.i18n.DatePickerLabelsTest", "usesTheFrenchWeekdays", "expected: <lundi> but was: <Lundi>"),
            ]),
        ],
        fallback: .loaded([test("com.example.cart.CartServiceTest", "addsAnItem", "expected: <2> but was: <1>")]))

    /// the tests of !24 #6: 14, with a regression, a missing message and a long one
    static let manyTests = FailedTestsFixtures(
        states: [
            BuildID(job: "MR-24", number: 6): .loaded([
                test("com.example.cart.CartTotalsTest", "addsTheVatToTheSubtotal()", "expected: <119.00> but was: <119.01>", regression: true),
                test("com.example.cart.CartTotalsTest", "roundsHalfUp()", "expected: <0.05> but was: <0.04>", regression: true),
                test("com.example.cart.CartTotalsTest", "appliesTheCouponBeforeVat()", "expected: <80.00> but was: <84.00>"),
                test("com.example.cart.DiscountRulesTest", "stacksNoMoreThanTwoCoupons", "Expected size: 2 but was: 3 in: [WINTER, WELCOME, FRIEND]"),
                test("com.example.cart.DiscountRulesTest", "ignoresAnExpiredCoupon", "expected: <false> but was: <true>"),
                test("com.example.cart.CurrencyFormatTest", "showsTwoDecimals", nil),
                test("com.example.cart.CurrencyFormatTest", "groupsThousandsWithAnApostrophe", "expected: <1'234.50> but was: <1,234.50>"),
                test(
                    "com.example.checkout.OrderSummaryTest", "listsTheItemsInTheOrderOfTheCart",
                    "java.lang.AssertionError: Expecting actual: [\"Lamp\", \"Desk\", \"Chair\"] to contain exactly (and in same order): "
                        + "[\"Desk\", \"Lamp\", \"Chair\"] but there were differences at index 0 and index 1 of the lists"),
                test("com.example.checkout.OrderSummaryTest", "showsTheShippingCost", "expected: <4.90> but was: <0.00>"),
                test("com.example.checkout.OrderSummaryTest", "showsTheDeliveryWindow", "expected: <Tue 3 Nov> but was: <Wed 4 Nov>"),
                test("com.example.checkout.PaymentFormTest", "rejectsAnExpiredCard", "Expected exception of type CardExpiredException"),
                test("com.example.checkout.PaymentFormTest", "masksTheCardNumber", "expected: <**** 4242> but was: <4242>"),
                test("", "orphan test without a class", "NullPointerException"),
                test("com.example.cart.CartStorageTest", "survivesARestart", "expected: <3> but was: <0>"),
            ])
        ],
        expanded: false)
}

/// The builds of `docs/design/pipelines.md`, States: made up, with full stage lists for the detail.
extension Fixtures {
    /// Returns stages from names, statuses and minutes.
    func stages(_ stages: [(String, Stage.Status, Double)]) -> [Stage] {
        stages.map { Stage(name: $0.0, status: $0.1, duration: $0.2 * 60) }
    }

    /// A build of an MR job with everything set.
    func pipelineBuild(
        _ job: String, _ number: Int, _ title: String?, phase: BuildPhase, startedMinutesAgo: Double,
        estimateMinutes: Double? = nil, stages: [Stage]?, tests: TestCounts? = nil, kind: JobKind = .mine,
        author: String? = nil
    ) -> Build {
        var build = running(job, number, title, startedMinutesAgo: startedMinutesAgo, estimateMinutes: estimateMinutes,
                            kind: kind, author: author)
        build.phase = phase
        build.stages = stages
        build.testCounts = tests
        return build
    }

    /// !12 #7, running since 10:37 with an estimate of 0h25m: the bar at 20 %, tests running
    var runningBuild: Build {
        pipelineBuild(
            "MR-12", 7, "Fix the login redirect after a timeout", phase: .running, startedMinutesAgo: 5, estimateMinutes: 25,
            stages: stages([("checkout", .success, 0.5), ("build", .success, 2), ("tests", .inProgress, 2.5)]))
    }

    /// !16 #3, FAILURE: tests and deploy failed, publish not run, 3 of 1200 tests failed
    var failedBuild: Build {
        pipelineBuild(
            "MR-16", 3, "Add a retry to the export job", phase: .finished(result: .failure, duration: 12 * 60),
            startedMinutesAgo: 42,
            stages: stages([
                ("checkout", .success, 0.5), ("build", .success, 4), ("tests", .failed, 6), ("deploy", .failed, 1.5),
                ("publish", .notExecuted, 0),
            ]),
            tests: TestCounts(failed: 3, total: 1200))
    }

    /// !9 #11, UNSTABLE: the tests stage unstable, 2 of 850 tests failed
    var unstableBuild: Build {
        pipelineBuild(
            "MR-9", 11, "Update the date picker translations", phase: .finished(result: .unstable, duration: 15 * 60),
            startedMinutesAgo: 135,
            stages: stages([
                ("checkout", .success, 0.5), ("build", .success, 3), ("tests", .unstable, 9), ("deploy", .success, 1.5),
                ("publish", .success, 1),
            ]),
            tests: TestCounts(failed: 2, total: 850))
    }

    /// feature/foo #3, SUCCESS: a branch job without a title, so the row shows the branch
    var successfulBranchBuild: Build {
        pipelineBuild(
            "feature%252Ffoo", 3, nil, phase: .finished(result: .success, duration: 9 * 60), startedMinutesAgo: 309,
            stages: nil, tests: TestCounts(failed: 0, total: 1200))
    }

    /// watched !14 #3 by Sam Lee, running
    var watchedBuild: Build {
        pipelineBuild(
            "MR-14", 3, "Rework the color tokens", phase: .running, startedMinutesAgo: 3, estimateMinutes: 20,
            stages: stages([("checkout", .success, 0.5), ("build", .inProgress, 2.5)]), kind: .watched, author: "Sam Lee")
    }

    /// !2, watched and not checked yet (WATCH-06)
    var waitingJob: WatchedJob {
        WatchedJob(job: "MR-2", label: "!2", added: minutesAgo(1))
    }

    /// !24 #6, FAILURE: 14 of 900 tests failed, so the Failed Tests section is cut after 10
    var failedTestsBuild: Build {
        pipelineBuild(
            "MR-24", 6, "Rework the cart totals", phase: .finished(result: .failure, duration: 14 * 60), startedMinutesAgo: 25,
            stages: stages([("checkout", .success, 0.5), ("build", .success, 4), ("tests", .failed, 8), ("deploy", .notExecuted, 0)]),
            tests: TestCounts(failed: 14, total: 900))
    }

    /// my three builds of the running state, newest started first: running, FAILURE, UNSTABLE
    var pipelineBuilds: [Build] {
        [runningBuild, failedBuild, unstableBuild]
    }

    /// Returns the Pipelines data of a state.
    ///
    /// - Parameters:
    ///   - mine: my builds that show; sorted here, newest started first (PIPE-08)
    ///   - watched: the watched builds that show
    ///   - waiting: the watched jobs not checked yet
    func pipelines(
        problem: Problem? = nil, hasLoaded: Bool = true, isChecking: Bool = false, lastChecked: Bool = true,
        mine: [Build]? = nil, watched: [Build]? = nil, waiting: [WatchedJob] = [], emptyState: PipelinesEmptyState? = nil,
        hiddenCount: Int = 0, mergeRequests: PanelData.MergeRequests? = nil, workItems: PanelData.WorkItems? = nil,
        update: UpdateState = .upToDate, team: TeamValues? = nil
    ) -> PipelinesData {
        let newestFirst: ([Build]) -> [Build] = { $0.sorted { $0.startedAt > $1.startedAt } }
        return PipelinesData(
            panel: panel(
                problem: problem, hasLoaded: hasLoaded, isChecking: isChecking, lastChecked: lastChecked,
                mine: newestFirst(mine ?? pipelineBuilds), watched: newestFirst(watched ?? [watchedBuild]),
                emptyState: emptyState, hiddenCount: hiddenCount, mergeRequests: mergeRequests, workItems: workItems,
                update: update, team: team),
            waiting: waiting)
    }

    /// `pipelines.many-items`: 12 builds of mine (5 running), 6 watched, 2 waiting; a FAILURE with 24 stages
    var manyPipelines: PipelinesData {
        let titles = [
            "Fix the login redirect after a timeout", "Add a retry to the export job", "Update the date picker translations",
            "Speed up the search index rebuild", "Migrate the settings storage", "Clean up the old report exporter",
            "Try the new linter rules", "Show the build number in the alert", "Cache the label colors per project",
            "Move the settings import to the new format", "Remove the old onboarding page",
        ]
        let mine = titles.enumerated().map { index, title in
            let number = 30 - index
            if index < 5 {
                return pipelineBuild(
                    "MR-\(number)", 2 + index, title, phase: .running, startedMinutesAgo: Double(2 + index * 3),
                    estimateMinutes: 25, stages: stages([("checkout", .success, 0.5), ("build", .inProgress, 2)]))
            }
            let result: BuildResult = index % 3 == 0 ? .failure : (index % 3 == 1 ? .success : .unstable)
            return pipelineBuild(
                "MR-\(number)", 2 + index, title, phase: .finished(result: result, duration: 10 * 60),
                startedMinutesAgo: Double(30 + index * 25), stages: nil, tests: TestCounts(failed: 1, total: 400))
        }
        let watched = (0..<6).map { index in
            pipelineBuild(
                "MR-\(40 + index)", 1 + index, "Watched change number \(String(index + 1)) for the export dialog",
                phase: index < 2 ? .running : .finished(result: .success, duration: 8 * 60),
                startedMinutesAgo: Double(4 + index * 40), estimateMinutes: 20, stages: [], kind: .watched,
                author: "Sam Lee")
        }
        let waiting = [waitingJob, WatchedJob(job: "MR-3", label: "!3", added: minutesAgo(0.5))]
        return pipelines(mine: mine + [manyStagesBuild], watched: watched, waiting: waiting, hiddenCount: 2)
    }

    /// !5 #9, FAILURE with 24 stages, so the detail scrolls
    var manyStagesBuild: Build {
        let names = [
            "checkout", "lint", "build", "unit tests", "integration tests", "ui tests", "package", "sign", "notarize",
            "upload", "deploy staging", "smoke staging", "approval", "deploy production", "smoke production", "publish",
            "docs", "changelog", "tag", "announce", "cleanup", "metrics", "archive", "report",
        ]
        let list = names.enumerated().map { index, name -> (String, Stage.Status, Double) in
            switch index {
            case ..<5: (name, .success, 1.5)
            case 5: (name, .failed, 6)
            default: (name, .notExecuted, 0)
            }
        }
        return pipelineBuild(
            "MR-5", 9, "Run the UI tests on every merge request", phase: .finished(result: .failure, duration: 20 * 60),
            startedMinutesAgo: 70, stages: stages(list), tests: TestCounts(failed: 7, total: 2400))
    }

    /// `pipelines.long-titles`: 200-character titles, a long branch, long stage names and a long author
    var longPipelines: PipelinesData {
        let branch = pipelineBuild(
            "feature%252Fa-very-long-branch-name-for-the-search-index-rework", 12, nil,
            phase: .finished(result: .failure, duration: 14 * 60), startedMinutesAgo: 50,
            stages: stages([("checkout", .success, 0.5), ("build the search index with the new tokenizer", .failed, 9)]))
        let mine = pipelineBuild(
            "MR-12", 7, longTitle, phase: .running, startedMinutesAgo: 5, estimateMinutes: 25,
            stages: stages([("checkout", .success, 0.5), ("run the integration tests against the staging database", .inProgress, 3)]))
        let watched = pipelineBuild(
            "MR-14", 3, longTitle, phase: .finished(result: .failure, duration: 18 * 60), startedMinutesAgo: 40,
            stages: stages([
                ("checkout", .success, 0.5), ("compile the documentation site with every localization", .success, 6),
                ("verify the screenshots of every localization against the reference images", .failed, 9),
            ]),
            tests: TestCounts(failed: 12, total: 3400), kind: .watched, author: "Maximiliane Konstanze Müller-Lüdenscheidt")
        return pipelines(mine: [mine, branch], watched: [watched])
    }
}
#endif
