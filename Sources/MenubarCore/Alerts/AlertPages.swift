import Foundation

/// The alerts one alert window holds, to page through (ALERT-03).
///
/// There is one window at a time. An alert that comes while it is open joins it and becomes the page shown; "1 of 3" and
/// the arrows page from the newest alert to the oldest. A dismissed page shows the next older one, the last page shows
/// the one before it, and the window closes once no page is left.
public struct AlertPages: Equatable, Sendable {
    /// One alert of the window, with the note that goes with it.
    public struct Page: Equatable, Identifiable, Sendable {
        public var alert: BuildAlert
        /// whether the alert shows as a window because its banner couldn't, which its footnote says
        public var notificationsOff: Bool

        public var id: UUID { alert.id }

        public init(alert: BuildAlert, notificationsOff: Bool) {
            self.alert = alert
            self.notificationsOff = notificationsOff
        }
    }

    /// the pages, the newest first
    public private(set) var pages: [Page] = []
    /// the shown page's place in ``pages``
    public private(set) var index = 0

    public init() {}

    public var isEmpty: Bool { pages.isEmpty }
    public var count: Int { pages.count }

    /// the page shown; `nil` once none is left
    public var current: Page? {
        pages.indices.contains(index) ? pages[index] : nil
    }

    /// "1 of 3"; the newest alert is the first
    public var position: String {
        "\(index + 1) of \(pages.count)"
    }

    /// whether a newer page is before the shown one
    public var hasPrevious: Bool { index > 0 }
    /// whether an older page is after the shown one
    public var hasNext: Bool { index + 1 < pages.count }

    /// Adds an alert as the newest page, and shows it. An alert already in the window is replaced and shown.
    ///
    /// - Parameters:
    ///   - alert: the alert
    ///   - notificationsOff: whether it shows because its banner couldn't
    public mutating func add(_ alert: BuildAlert, notificationsOff: Bool) {
        pages.removeAll { $0.id == alert.id }
        pages.insert(Page(alert: alert, notificationsOff: notificationsOff), at: 0)
        index = 0
    }

    /// Shows the next newer page; nothing at the first.
    public mutating func previous() {
        if hasPrevious { index -= 1 }
    }

    /// Shows the next older page; nothing at the last.
    public mutating func next() {
        if hasNext { index += 1 }
    }

    /// Removes a page. The one shown is followed by the next older page, or by the one before it when it was the last;
    /// a page removed before the shown one leaves it shown.
    ///
    /// - Parameter id: the alert's id
    public mutating func dismiss(_ id: UUID) {
        guard let removed = pages.firstIndex(where: { $0.id == id }) else {
            return
        }
        pages.remove(at: removed)
        if removed < index {
            index -= 1
        }
        index = max(0, min(index, pages.count - 1))
    }

    /// Removes every page.
    public mutating func dismissAll() {
        pages = []
        index = 0
    }
}
