#if DEBUG
import MenubarCore
import SwiftUI

extension Fixtures {
    /// the events of the big panel's gallery: the coffee break, a review request, a mention with Claude's line, a failed build
    var panelEvents: [String: InboxEvent] {
        let alex = MergeRequest.Person(username: "akim", name: "Alex Kim")
        let sam = MergeRequest.Person(username: "slee", name: "Sam Lee")
        let path = "group/subgroup/project"
        return [
            "coffee": .coffeeBreak(line: "Warm cups, cold pipelines, that's the plan.", at: now),
            "review": InboxEvent(
                id: "todo|1", kind: .reviewRequested, source: .todo, todoID: "gid://gitlab/Todo/1", title: "Add a retry to the export job",
                reference: "\(path)!210", targetURL: URL(string: "https://gitlab.example.com/\(path)/-/merge_requests/210"),
                projectPath: path, actor: alex, occurredAt: now),
            "mention": InboxEvent(
                id: "todo|2", kind: .mentioned, source: .todo, todoID: "gid://gitlab/Todo/2",
                title: "Rework the color tokens so the badges, the panel and the main window share one source of truth",
                reference: "\(path)#31", targetURL: URL(string: "https://gitlab.example.com/\(path)/-/work_items/31"),
                projectPath: path, actor: sam, occurredAt: now, excerpt: "@jdoe the dark values need your eye before we lock the slot."),
            "build": .buildFailed(
                jobKey: "main|MR-16", number: 3, label: "!210 #3", isUnstable: false, title: "Add a retry to the export job",
                url: URL(string: "https://jenkins.example.com/job/project/job/MR-16/3/")!, at: now),
            "claude": .claudeAnswered(
                subjectKey: "mr:\(path)!204", useCase: "Why Did It Fail?", failed: false, title: "Fix the login redirect after a timeout",
                reference: "\(path)!204", excerpt: "The redirect loops because the session cookie is rewritten before the check.",
                url: URL(string: "https://gitlab.example.com/\(path)/-/merge_requests/204"), at: now),
        ]
    }
}

/// The big panel as the window shows it: the glass is the window's, so the gallery draws one: a wallpaper and a material
/// clipped to the panel's corners.
private struct PanelGalleryView: View {
    let events: [InboxEvent]
    var shown = 0
    /// a Done GitLab refused, shown on the first event's page
    var refusal: Problem?

    var body: some View {
        let model = InboxEventPanelModel()
        for event in events.reversed() {
            model.pages.add(event)
        }
        if let refusal, let id = model.pages.current?.id {
            model.refusals[id] = refusal
        }
        for _ in 0..<shown {
            model.pages.next()
        }
        return ZStack {
            LinearGradient(
                colors: [Color(red: 0.86, green: 0.88, blue: 0.93), Color(red: 0.97, green: 0.93, blue: 0.88)], startPoint: .topLeading,
                endPoint: .bottomTrailing)
            InboxEventPanelView(model: model, perform: { _, _ in }, dismissAll: {}, onSizeChange: { _ in })
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: BuildAlertView.cornerRadius, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: BuildAlertView.cornerRadius, style: .continuous))
                .padding(.horizontal, 30)
        }
    }
}

/// Settings → Notifications' Inbox sections, with a few kinds on a panel or a banner.
private struct InboxSettingsGalleryView: View {
    var rules = InboxNotificationRules()
    var buildAlertStyle = Preferences.AlertStyle.window
    var permission: NotificationPermission? = .allowed

    var body: some View {
        Form {
            InboxNotificationsSection(
                rules: .constant(rules), buildAlertStyle: .constant(buildAlertStyle), permission: permission, actions: .none)
        }
        .formStyle(.grouped)
        .settingsPaneFrame(estimate: 1000)
    }
}

extension GalleryCatalog {
    /// The big panel's pages (INBOX-14), and Settings → Notifications' delivery pickers and group order (INBOX-14, INBOX-15).
    static var inboxDeliveryEntries: [GalleryEntry] {
        var picked = InboxNotificationRules()
        picked.set(.bigPanel, for: .coffeeBreak)
        picked.set(.desktopNotification, for: .reviewRequested)
        picked.set(.desktopNotification, for: .mentioned)
        var reordered = picked
        reordered.setGroupOrder([.myToDos, .builds, .coffee, .claude, .mentions, .reviewRequests, .assigned, .other])
        return [
            GalleryEntry(screen: "inbox-panel", state: "coffee", size: CGSize(width: 380, height: 290)) { f in
                PanelGalleryView(events: [f.panelEvents["coffee"]!])
            },
            GalleryEntry(screen: "inbox-panel", state: "review-requested", size: CGSize(width: 380, height: 340)) { f in
                PanelGalleryView(events: [f.panelEvents["review"]!])
            },
            GalleryEntry(screen: "inbox-panel", state: "mention", size: CGSize(width: 380, height: 400)) { f in
                PanelGalleryView(events: [f.panelEvents["mention"]!])
            },
            GalleryEntry(screen: "inbox-panel", state: "claude", size: CGSize(width: 380, height: 400)) { f in
                PanelGalleryView(events: [f.panelEvents["claude"]!])
            },
            GalleryEntry(screen: "inbox-panel", state: "done-refused", size: CGSize(width: 380, height: 440)) { f in
                PanelGalleryView(events: [f.panelEvents["review"]!], refusal: .readOnlyToken(action: "Mark Done"))
            },
            GalleryEntry(screen: "inbox-panel", state: "paged", size: CGSize(width: 380, height: 440)) { f in
                PanelGalleryView(events: [f.panelEvents["coffee"]!, f.panelEvents["review"]!, f.panelEvents["build"]!], shown: 1)
            },
            GalleryEntry(screen: "settings-inbox", state: "delivery", size: CGSize(width: SettingsMetrics.width, height: 1000)) { _ in
                InboxSettingsGalleryView(rules: picked)
            },
            GalleryEntry(screen: "settings-inbox", state: "order-changed", size: CGSize(width: SettingsMetrics.width, height: 1000)) { _ in
                InboxSettingsGalleryView(rules: reordered)
            },
            GalleryEntry(screen: "settings-inbox", state: "banners-off", size: CGSize(width: SettingsMetrics.width, height: 1000)) { _ in
                InboxSettingsGalleryView(rules: picked, buildAlertStyle: .banner, permission: .off)
            },
        ]
    }
}
#endif
