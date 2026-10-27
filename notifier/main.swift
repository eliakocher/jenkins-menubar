import AppKit
import UserNotifications

// Usage: notifier --title T [--subtitle S] [--body B] [--build URL] [--mr URL] [--default build|mr]
//        notifier --settings [jenkins|gitlab|accounts|team]    the settings window, at that pane
//        open jenkins-menubar://settings/<pane>                the same, the way the menu opens it
final class Notifier: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
	let options: [String: String]
	let settingsPane: String?
	private var settingsWindow: SettingsWindow?

	init(arguments: [String]) {
		settingsPane = arguments.first == "--settings" ? (arguments.dropFirst().first ?? "jenkins") : nil
		var options: [String: String] = [:]
		var index = 0
		while index + 1 < arguments.count {
			options[String(arguments[index].drop(while: { $0 == "-" }))] = arguments[index + 1]
			index += 2
		}
		self.options = options
	}

	func applicationWillFinishLaunching(_ notification: Notification) {
		// macOS relaunches the app without arguments to deliver a click, so the delegate must exist before launch ends.
		UNUserNotificationCenter.current().delegate = self
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		if let settingsPane {
			settingsWindow = MainActor.assumeIsolated { SettingsWindow.show(pane: settingsPane) }
			if settingsWindow == nil {
				quit(after: 0)
			}
			return
		}
		guard let title = options["title"] else {
			quit(after: 10)
			return
		}
		// An unanswered permission prompt never calls back.
		DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
			if self.settingsWindow == nil {
				exit(1)
			}
		}
		let center = UNUserNotificationCenter.current()
		center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
			guard granted else {
				FileHandle.standardError.write("notifications are not allowed for this app\n".data(using: .utf8)!)
				exit(1)
			}
			let content = UNMutableNotificationContent()
			content.title = title
			content.subtitle = self.options["subtitle"] ?? ""
			content.body = self.options["body"] ?? ""
			content.userInfo = ["build": self.options["build"] ?? "", "mr": self.options["mr"] ?? "", "default": self.options["default"] ?? "build"]
			content.categoryIdentifier = self.options["mr"] == nil ? "build" : "build-and-mr"
			center.setNotificationCategories(self.categories())
			center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
				if let error {
					FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
					exit(1)
				}
				self.quit(after: 1)
			}
		}
	}

	/// The menu opens the settings with jenkins-menubar://settings/<pane>: macOS brings an app that SwiftBar opens a URL
	/// with to the front, but not one that SwiftBar's background `open -n` starts. macOS hands the URL to a running instance
	/// (maybe one that is about to quit after its banner) or starts one without arguments.
	func application(_ application: NSApplication, open urls: [URL]) {
		guard let url = urls.first(where: { $0.scheme == "jenkins-menubar" && $0.host == "settings" }) else { return }
		let pane = url.pathComponents.dropFirst().first ?? "jenkins"
		MainActor.assumeIsolated {
			if let settingsWindow {
				settingsWindow.bringToFront(pane: pane)
			} else {
				settingsWindow = SettingsWindow.show(pane: pane)
				if settingsWindow == nil {
					quit(after: 0)
				}
			}
		}
	}

	func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
		let info = response.notification.request.content.userInfo
		let key: String?
		switch response.actionIdentifier {
		case "open-build": key = "build"
		case "open-mr": key = "mr"
		case UNNotificationDefaultActionIdentifier: key = info["default"] as? String
		default: key = nil
		}
		if let key, let link = info[key] as? String, let url = URL(string: link), !link.isEmpty {
			NSWorkspace.shared.open(url)
		}
		completionHandler()
		quit(after: 0.5)
	}

	func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
		completionHandler([.banner, .list])
	}

	private func categories() -> Set<UNNotificationCategory> {
		let openBuild = UNNotificationAction(identifier: "open-build", title: "Open build")
		let openMergeRequest = UNNotificationAction(identifier: "open-mr", title: "Open MR")
		return [
			UNNotificationCategory(identifier: "build", actions: [openBuild], intentIdentifiers: []),
			UNNotificationCategory(identifier: "build-and-mr", actions: [openMergeRequest, openBuild], intentIdentifiers: []),
		]
	}

	/// An instance with the settings window stays until the window closes: macOS may hand it a banner click, and a URL may
	/// open the window in an instance that was about to quit.
	private func quit(after seconds: Double) {
		DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
			if self.settingsWindow == nil {
				NSApp.terminate(nil)
			}
		}
	}
}

let app = NSApplication.shared
let notifier = Notifier(arguments: Array(CommandLine.arguments.dropFirst()))
app.delegate = notifier
app.setActivationPolicy(.accessory)
app.run()
