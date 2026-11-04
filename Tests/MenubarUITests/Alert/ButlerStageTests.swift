import AppKit
import Foundation
import MenubarCore
import SwiftUI
import Testing

@testable import MenubarUI

/// The butler's stage (ALERT-03, INBOX-14): the pop-ups' butler is 128 pt, and the page takes its own height, so no art or
/// sky is cut off and no page is padded to match another.
@Suite("ButlerStage")
@MainActor
struct ButlerStageTests {
    /// the bundled butler art, read from the repository's `icons` folder
    private static func alertArt() throws -> [(name: String, image: NSImage)] {
        let icons = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "icons", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(atPath: icons.path)
            .filter { ($0.hasPrefix("happy") || $0.hasPrefix("sad") || $0.hasPrefix("caught") || $0.hasPrefix("mixed")) && $0.hasSuffix(".png") }
        return files.compactMap { file in
            NSImage(contentsOf: icons.appending(path: file)).map { (file, $0) }
        }
    }

    @Test("ALERT-03 the butler's box is 128 pt, and the stage is as tall as his art, with the sky's headroom only under a sky")
    func stageIsAsTallAsTheArt() throws {
        #expect(ButlerStage<EmptyView, EmptyView>.artBox == 128)
        let plain = CGSize(width: 128, height: 128)
        #expect(ButlerStage<EmptyView, EmptyView>.height(of: plain, hasSky: false) == 128)
        #expect(ButlerStage<EmptyView, EmptyView>.height(of: plain, hasSky: true) == 128 + SadWeatherSky.headroom)
        let art = try Self.alertArt()
        #expect(art.count >= 8)
        let tallest = AppImages.tallestAlertArtHeight(box: ButlerStage<EmptyView, EmptyView>.artBox)
        for (name, image) in art {
            let size = AppImages.alertSize(of: image, box: ButlerStage<EmptyView, EmptyView>.artBox)
            #expect(size.height <= tallest, "\(name)")
            // a stage's width is the page's 280 pt, 300 for the sky
            #expect(size.width <= 280, "\(name)")
        }
    }

    @Test("ALERT-03 no butler is ever distorted: the size keeps the art's proportions, whatever its kind")
    func artKeepsItsProportions() throws {
        let box = ButlerStage<EmptyView, EmptyView>.artBox
        for (name, image) in try Self.alertArt() {
            let pixels = try #require(image.representations.first)
            let size = AppImages.alertSize(of: image, box: box)
            #expect(abs(size.width / size.height - CGFloat(pixels.pixelsWide) / CGFloat(pixels.pixelsHigh)) < 0.002, "\(name)")
        }
        // the mixed art is about as tall as the plain butler's box times the factor, not squeezed into the box
        let mixed = try #require(try Self.alertArt().first { $0.name == "mixed.png" }, "icons/mixed.png").image
        #expect(abs(AppImages.alertSize(of: mixed, box: box).height - box * AppImages.mixedHeightFactor) < 0.5)
    }

    @Test("ALERT-03 the mixed butler wears the season's art: halloween, santa, carnival and easter have their own, the rest the plain one, then the caught butler")
    func mixedArtNames() {
        let expected: [(ButlerHat?, [String])] = [
            (.witch, ["mixed-halloween", "mixed", "caught"]), (.santa, ["mixed-santa", "mixed", "caught"]),
            (.carnival, ["mixed-carnival", "mixed", "caught"]), (.easter, ["mixed-easter", "mixed", "caught"]),
            (.party, ["mixed", "caught"]), (.newYear, ["mixed", "caught"]), (nil, ["mixed", "caught"]),
        ]
        for (hat, names) in expected {
            #expect(AppImages.mixedArtNames(hat: hat) == names, "\(String(describing: hat))")
        }
    }

    @Test("INBOX-14 the coffee break's pop-up has one button, On My Way; every other event keeps Show, Done, Snooze and Dismiss")
    func popUpButtons() {
        let coffee = InboxEvent.coffeeBreak(line: "Warm cups.", at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(InboxEventView.buttons(for: coffee) == [.done])
        #expect(InboxDeliveryAction.done.panelTitle(for: .coffeeBreak) == "On My Way ☕")
        let review = InboxEvent(
            id: "todo|1", kind: .reviewRequested, source: .todo, title: "Add a retry", reference: "group/project!210",
            targetURL: URL(string: "https://gitlab.example.com/group/project/-/merge_requests/210"),
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(InboxEventView.buttons(for: review) == [.show, .done, .snooze, .dismiss])
    }

    @Test("ALERT-03 the summary's list shows at most six rows, each one line high, and scrolls beyond")
    func summaryListHeight() throws {
        let alerts = Fixtures().pagedAlerts
        // ten items; a new id each, since an item that comes again replaces its earlier one
        let items = (alerts + alerts).map {
            AlertWindowItem(alert: BuildAlert(kind: $0.kind, build: $0.build, content: $0.content), notificationsOff: false)
        }
        func height(_ count: Int) throws -> CGFloat {
            let summary = try #require(AlertSummary.make(Array(items.prefix(count))))
            return ceil(NSHostingView(rootView: AlertSummaryView(summary: summary, openItem: { _ in }, openInbox: {}, dismissAll: {})).fittingSize.height)
        }
        #expect(try height(3) + 3 * AlertSummaryView.rowHeight == height(6))
        // beyond six, half a row of the seventh shows, and more rows change nothing
        #expect(try abs(height(7) - height(6) - AlertSummaryView.rowHeight / 2) <= 1)
        #expect(try height(10) == height(7))
    }
}
