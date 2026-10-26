import AppKit
import UserNotifications

// Usage: notifier --title T [--subtitle S] [--body B] [--build URL] [--mr URL] [--default build|mr]
final class Notifier: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
	let options: [String: String]

	init(arguments: [String]) {
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
		guard let title = options["title"] else {
			quit(after: 10)
			return
		}
		// An unanswered permission prompt never calls back.
		DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(1) }
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

	private func quit(after seconds: Double) {
		DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
	}
}

let app = NSApplication.shared
let notifier = Notifier(arguments: Array(CommandLine.arguments.dropFirst()))
app.delegate = notifier
app.setActivationPolicy(.accessory)
app.run()
