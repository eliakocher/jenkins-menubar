import AppKit
import MenubarCore
import SwiftUI
import Testing

@testable import MenubarUI

/// The alert window's size when its content changes (ALERT-03): once the user saw the butler's hat cut off and a band of empty
/// glass below (2026-11-04), because the window was resized from inside SwiftUI's update pass. The window now takes the
/// content's size a main turn later, keeps its top edge, and its glass and hosted view fill it. A pop-up, a summary and a
/// summary with one more row each have their own height.
@Suite("AlertPanelFit")
@MainActor
struct AlertPanelFitTests {
    @Test("ALERT-03 a new height keeps the top left corner and grows or shrinks downward")
    func frameKeepsTopLeft() {
        let frame = NSRect(x: 100, y: 500, width: 320, height: 400)
        let taller = AlertPanel.frame(keepingTopLeftOf: frame, forSize: NSSize(width: 320, height: 450))
        #expect(taller == NSRect(x: 100, y: 450, width: 320, height: 450))
        #expect(taller.maxY == frame.maxY)
        let shorter = AlertPanel.frame(keepingTopLeftOf: frame, forSize: NSSize(width: 320, height: 330))
        #expect(shorter == NSRect(x: 100, y: 570, width: 320, height: 330))
        #expect(shorter.maxY == frame.maxY)
    }

    /// the real panel and window view of the alert window, as `AlertPanels` builds them, on an offscreen window
    @MainActor
    private struct Window {
        let panel: AlertPanel
        let hosting: NSHostingView<AlertWindowView>
        let model: AlertWindowModel
        let alerts: [BuildAlert]

        init() {
            let model = AlertWindowModel()
            var alerts = Fixtures().pagedAlerts
            // Halloween's tall art and the sky on some, the plain butler on the others
            alerts[0].content.hat = .witch
            alerts[0].content.weather = .storm
            alerts[0].content.funLevel = .party
            alerts[2].content.hat = .witch
            alerts[2].content.weather = .drizzle
            alerts[2].content.funLevel = .party
            let panel = AlertPanel(title: "test")
            let view = AlertWindowView(
                model: model, rebuildWithChanges: { _ in }, perform: { _, _ in }, performEvent: { _, _ in }, openItem: { _ in },
                openInbox: {}, dismissAll: {}, onSizeChange: { [weak panel] size in panel?.fit(to: size) })
            let hosting = NSHostingView(rootView: view)
            hosting.safeAreaRegions = []
            panel.setContent(hosting)
            panel.setFrameTopLeftPoint(NSPoint(x: -9000, y: 900))
            panel.orderBack(nil)
            self.model = model
            self.panel = panel
            self.hosting = hosting
            self.alerts = alerts
        }

        func add(_ index: Int) {
            model.items.add(AlertWindowItem(alert: alerts[index], notificationsOff: false))
        }

        /// Lets the run loop turn, so SwiftUI's update and the window's deferred change have happened.
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(300))
            hosting.layoutSubtreeIfNeeded()
        }
    }

    @Test("ALERT-03 the window follows its content as alerts come and go: its height is the content's, the top stays, the glass fills it")
    func windowFollowsContent() async throws {
        _ = NSApplication.shared
        let window = Window()
        defer { window.panel.close() }
        window.add(0)
        try await window.settle()
        let top = window.panel.frame.maxY
        var heights: [CGFloat] = []
        func check() throws {
            let glass = try #require(window.panel.contentView)
            let content = window.hosting.fittingSize
            heights.append(content.height)
            #expect(window.panel.frame.maxY == top)
            #expect(window.panel.frame.height == content.height)
            #expect(glass.frame == NSRect(origin: .zero, size: window.panel.frame.size))
            #expect(window.hosting.frame == glass.bounds)
        }
        try check()
        // a second alert makes the summary, more rows grow it, and dismissing back to one is a pop-up again
        for index in 1..<5 {
            window.add(index)
            try await window.settle()
            try check()
        }
        for alert in window.alerts.dropFirst(1) {
            window.model.items.dismiss(AlertWindowItem(alert: alert, notificationsOff: false).id)
            try await window.settle()
            try check()
        }
        // the pop-up, the summary of two and the summary of five are three different heights
        #expect(Set(heights).count >= 3)
        #expect(heights.first == heights.last)
    }

    @Test("ALERT-03 the window's frame doesn't change inside the call that reports the new size, only a main turn later")
    func fitIsDeferred() async throws {
        _ = NSApplication.shared
        let window = Window()
        defer { window.panel.close() }
        try await window.settle()
        let before = window.panel.frame
        window.panel.fit(to: CGSize(width: before.width, height: before.height + 60))
        window.panel.fit(to: CGSize(width: before.width, height: before.height + 80))
        #expect(window.panel.frame == before)
        try await Task.sleep(for: .milliseconds(100))
        // the newest size wins, with the top edge kept
        #expect(window.panel.frame.height == before.height + 80)
        #expect(window.panel.frame.maxY == before.maxY)
    }
}
