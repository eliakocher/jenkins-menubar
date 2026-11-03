import AppKit
import MenubarCore
import SwiftUI
import Testing

@testable import MenubarUI

/// The pane's peek panel beside the real pane content, on an offscreen window: opening the pane while the butler is about
/// to peek crashed the app (2026-11-03, an exception of a window's constraint passes), because the panel's window was
/// changed from inside SwiftUI's update.
@Suite("MenuPeekPane")
@MainActor
struct MenuPeekPaneTests {
    /// A fake model with the team values, so the pane has its area rows, the fun layer at Normal and a real clock.
    @MainActor
    private final class Harness {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "menubar-monitor-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suiteName = "menubar-monitor-tests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let model: AppModel

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suiteName))
            let team = TeamValues(
                jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: "https://gitlab.example.com",
                gitLabProject: "group/project")
            try TeamStore(folder: FileLocations(root: root).applicationSupport, report: { _ in })
                .save(Project(id: .main, team: team))
            model = AppModel(dependencies: .fake(root: root, defaults: defaults, clock: ContinuousClock()))
            var preferences = model.settings.preferences
            preferences.easterEggs = true
            preferences.funLevel = .normal
            model.fun.apply(preferences)
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func offscreenWindow(_ content: NSView? = nil) -> NSPanel {
        let window = NSPanel(
            contentRect: NSRect(x: -9000, y: 200, width: 360, height: 400), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        if let content {
            window.contentView = content
        }
        window.orderBack(nil)
        return window
    }

    private static func spin(_ milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    @Test("FUN-11 opening the pane with a queued peek: he leans out in his panel beside it, the pane keeps its size")
    func openWithQueuedPeek() async throws {
        _ = NSApplication.shared
        let harness = try Harness()
        let model = harness.model
        model.fun.queuePanePeek(at: Date())
        let router = WindowRouter(defaults: harness.defaults) { _ in }
        let window = Self.offscreenWindow(NSHostingView(rootView: MenuPaneView().appEnvironment(model, router: router)))
        defer {
            window.childWindows?.forEach { $0.orderOut(nil) }
            window.orderOut(nil)
        }
        try await Self.spin(300)
        let paneFrame = window.frame
        // He comes out as the pane's overlay claims him a moment after the pane shows (about 0.4 s after; 1.2 s is the limit here, the old retry was 6 s); the pane's own
        // update asks for his panel.
        for _ in 0..<12 where model.fun.playing == nil {
            try await Self.spin(100)
        }
        #expect(model.fun.playing?.owner == FunModel.paneOwner)
        try await Self.spin(300)
        let peek = try #require(window.childWindows?.first as? MenuPeekPanel)
        #expect(peek.isVisible)
        #expect(window.frame == paneFrame)
        // beside the pane, starting on its edge, at its level
        #expect(peek.frame.minX == window.frame.maxX || peek.frame.maxX == window.frame.minX)
        #expect(peek.level == window.level)
        // The figure isn't the window's content view, so SwiftUI never sizes the panel from it.
        #expect(!(peek.contentView is NSHostingView<AnyView>))
        // He goes back, and the panel goes with him.
        for _ in 0..<80 where model.fun.playing != nil {
            try await Self.spin(100)
        }
        #expect(model.fun.playing == nil)
        try await Self.spin(100)
        #expect(window.childWindows?.isEmpty ?? true)
        #expect(!peek.isVisible)
        #expect(window.frame == paneFrame)
    }

    @Test("FUN-11 the peek panel changes only a turn after it was asked for, once for many asks, never inside the asking update")
    func refreshIsDeferred() async throws {
        _ = NSApplication.shared
        let harness = try Harness()
        let fun = harness.model.fun
        fun.queuePanePeek(at: Date())
        #expect(fun.claimPeek(busy: false, edges: [.right], owner: FunModel.paneOwner, surface: .menuPane) != nil)
        let pane = Self.offscreenWindow()
        defer {
            pane.childWindows?.forEach { $0.orderOut(nil) }
            pane.orderOut(nil)
        }
        let controller = MenuPeekPanelController()
        var reads = 0
        for _ in 0..<3 {
            controller.setNeedsRefresh {
                reads += 1
                return (fun, pane, nil)
            }
        }
        // Nothing is touched yet: the ask may come from inside SwiftUI's update, in a window's constraint pass.
        #expect(pane.childWindows?.isEmpty ?? true)
        #expect(reads == 0)
        try await Self.spin(50)
        #expect(reads == 1)
        let peek = try #require(pane.childWindows?.first)
        #expect(peek.isVisible && peek.frame.minX == pane.frame.maxX)
        // a closed pane: the panel goes, again a turn later
        controller.setNeedsRefresh { (fun, nil, nil) }
        #expect(peek.isVisible)
        try await Self.spin(50)
        #expect(!peek.isVisible && (pane.childWindows?.isEmpty ?? true))
    }

    @Test(
        "FUN-11 a pane or a place that can't hold a window skips the peek",
        arguments: [
            (NSRect(x: 0, y: 0, width: 384, height: 560), true),
            (NSRect(x: 0, y: 0, width: 0, height: 560), false),
            (NSRect(x: 0, y: 0, width: 384, height: 0.5), false),
            (NSRect(x: CGFloat.nan, y: 0, width: 384, height: 560), false),
            (NSRect(x: 0, y: CGFloat.infinity, width: 384, height: 560), false),
        ])
    func soundFrames(frame: NSRect, sound: Bool) {
        #expect(MenuPeekPanelController.isSound(frame) == sound)
    }
}
