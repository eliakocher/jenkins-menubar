import AppKit
import SwiftUI

/// The settings window. The menu opens it with `open -n … --args --settings <pane>`, so every click starts a new
/// instance of the app: that one hands the pane to an instance that already shows the window, and quits.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
	private static let showPane = Notification.Name("local.jenkins-menubar.settings.show")

	private let window: NSWindow
	private let navigation = Navigation()

	/// Shows the window at the pane, or nil when another instance shows it already.
	static func show(pane: String) -> SettingsWindow? {
		let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
			// Instances that post banners stay in the background; only the one with the window is a regular app.
			.filter { $0 != NSRunningApplication.current && $0.activationPolicy == .regular }
		if let other = others.first {
			DistributedNotificationCenter.default().postNotificationName(showPane, object: pane, userInfo: nil, deliverImmediately: true)
			NSApp.yieldActivation(to: other)
			other.activate(options: .activateAllWindows)
			return nil
		}
		return SettingsWindow(pane: pane)
	}

	private init(pane: String) {
		// The app lives in <tool>/notifier, the plugin in <tool>/plugins.
		let tool = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
		let model = SettingsModel(plugin: Plugin(script: tool.appendingPathComponent("plugins/jenkins.30s.sh")))
		window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
			styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		super.init()
		navigation.pane = Pane(rawValue: pane) ?? .jenkins

		window.title = "Jenkins menubar"
		window.toolbarStyle = .unified
		window.contentMinSize = NSSize(width: 640, height: 420)
		window.contentViewController = NSHostingController(rootView: SettingsView(model: model, navigation: navigation))
		window.setContentSize(NSSize(width: 780, height: 580))
		window.setFrameAutosaveName("Settings")
		if !window.setFrameUsingName("Settings") {
			window.center()
		}
		window.delegate = self
		window.isReleasedWhenClosed = false

		NSApp.setActivationPolicy(.regular)
		NSApp.mainMenu = Self.mainMenu()
		NSApp.activate()
		window.makeKeyAndOrderFront(nil)

		DistributedNotificationCenter.default().addObserver(forName: Self.showPane, object: nil, queue: .main) { [weak self] notification in
			let pane = notification.object as? String
			MainActor.assumeIsolated {
				self?.bringToFront(pane: pane)
			}
		}
	}

	private func bringToFront(pane: String?) {
		if let pane = pane.flatMap(Pane.init(rawValue:)) {
			navigation.pane = pane
		}
		NSApp.activate()
		window.makeKeyAndOrderFront(nil)
	}

	func windowWillClose(_ notification: Notification) {
		NSApp.terminate(nil)
	}

	/// Without an Edit menu, ⌘V does not paste into the token fields.
	private static func mainMenu() -> NSMenu {
		let main = NSMenu()
		func add(_ menu: NSMenu) {
			let item = NSMenuItem()
			item.submenu = menu
			main.addItem(item)
		}

		let app = NSMenu()
		app.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
		app.addItem(.separator())
		app.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		add(app)

		let edit = NSMenu(title: "Edit")
		edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
		edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
		edit.addItem(.separator())
		edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
		edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
		edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
		edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
		add(edit)

		return main
	}
}
