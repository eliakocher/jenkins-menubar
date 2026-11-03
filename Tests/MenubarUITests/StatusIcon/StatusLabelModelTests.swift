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

/// The item's parts from Settings → Menu Bar (APP-11).
@Suite("StatusLabelModel layout")
struct StatusLabelLayoutTests {
    @Test("APP-11 the item's parts follow the layout: order, switches, zero counts, the butler and the Inbox count")
    func partsFollowLayout() {
        let counts = BuildCounts(running: 1, failed: 2)
        let slot = StatusLabelModel.SlotCountdown(text: "freeze 3d", isUrgent: true)
        // The default layout is the old look, and the new parts stay off.
        #expect(StatusLabelModel(problem: .jenkins, counts: counts, hasInboxItems: true, reviewCount: 3, slot: slot).parts
            == [.problem, .count(.running, 1), .count(.failed, 2), .inboxDot])

        // Reordered, with the failed count and the problem off, the Inbox as a count, reviews and the slot on.
        var layout = MenuBarLayout()
        layout.moveParts(from: [5], to: 0)
        layout.setPart(.failed, isOn: false)
        layout.setPart(.problem, isOn: false)
        layout.setPart(.reviews, isOn: true)
        layout.setPart(.slot, isOn: true)
        layout.inboxStyle = .count
        let model = StatusLabelModel(
            problem: .jenkins, counts: counts, inboxCount: 4, reviewCount: 3, slot: slot, layout: layout)
        #expect(model.parts == [.inboxCount(4), .count(.running, 1), .reviews(3), .slot("freeze 3d", urgent: true)])

        // Zero counts show when asked; the butler shows while no build is counted, as before.
        layout.hidesZeroCounts = false
        #expect(StatusLabelModel(layout: layout).parts
            == [.identity, .inboxCount(0), .count(.running, 0), .count(.unstable, 0), .count(.successful, 0), .reviews(0)])
        // A count that is off doesn't count: the butler stays while only failed builds are there.
        layout.hidesZeroCounts = true
        #expect(StatusLabelModel(counts: BuildCounts(failed: 2), layout: layout).parts == [.identity])

        // Always the butler, or never unless nothing else shows, so the item is never empty.
        layout.butler = .always
        #expect(StatusLabelModel(counts: counts, layout: layout).parts == [.identity, .count(.running, 1)])
        layout.butler = .never
        #expect(StatusLabelModel(inboxCount: 2, layout: layout).parts == [.inboxCount(2)])
        #expect(StatusLabelModel(layout: layout).parts == [.identity])
        #expect(StatusLabelModel(layout: layout).rendering == .identity)

        // The slot's short countdown: the next milestone, urgent within the warning days of the code freeze.
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17))!
        let day = { (offset: Int) in calendar.date(byAdding: .day, value: offset, to: today)! }
        let dates = SlotDates(release: day(27), codeFreeze: day(3), earlyAccess: day(13))
        #expect(StatusLabelModel.SlotCountdown(dates: dates, warnDays: 3, today: today, calendar: calendar)
            == StatusLabelModel.SlotCountdown(text: "freeze 3d", isUrgent: true))
        #expect(StatusLabelModel.SlotCountdown(dates: dates, warnDays: 3, today: day(13), calendar: calendar)?.text == "EA today")
        #expect(StatusLabelModel.SlotCountdown(dates: dates, warnDays: 3, today: day(28), calendar: calendar) == nil)
    }

    @Test("APP-11 the Inbox dot is red in both styles; on a monochrome item only the dot is")
    func redDot() {
        let mono = StatusLabelModel(counts: BuildCounts(failed: 1), hasInboxItems: true)
        #expect(mono.color(of: .inboxDot) == .red)
        #expect(mono.hasRedDotOnTemplate)
        // The rest keeps the menu bar's tint.
        #expect(mono.color(of: .count(.failed, 1)) == nil)
        #expect(mono.color(of: .problem) == nil)
        let color = StatusLabelModel(counts: BuildCounts(failed: 1), style: .color, hasInboxItems: true)
        #expect(color.color(of: .inboxDot) == .red)
        #expect(!color.hasRedDotOnTemplate)
        // Without the dot, or with the Inbox as a count, the monochrome item is a plain template.
        #expect(!StatusLabelModel(counts: BuildCounts(failed: 1)).hasRedDotOnTemplate)
        var layout = MenuBarLayout()
        layout.inboxStyle = .count
        #expect(!StatusLabelModel(inboxCount: 3, layout: layout).hasRedDotOnTemplate)
    }
}
