import MenubarCore
import Observation
import SwiftUI

/// What the alert window holds: the alerts to page through (ALERT-03). The window's view reads it; the app adds an alert
/// when one comes and removes a page when it is dismissed.
@MainActor
@Observable
public final class AlertPanelModel {
    public var pages = AlertPages()

    public init() {}
}

/// The alert window's content: the shown page as a ``BuildAlertView``, with the pager above its butler and Dismiss All
/// next to Dismiss while the window holds more than one alert (ALERT-03).
///
/// The page is as tall as its content, so the height changes from page to page; `onSizeChange` tells the window, which
/// keeps its top left corner where it is.
public struct BuildAlertPanelView: View {
    let model: AlertPanelModel
    let rebuildWithChanges: (@MainActor (BuildAlert) -> Void)?
    let perform: @MainActor (BuildAlert, AlertContent.Action) -> Void
    let dismissAll: @MainActor () -> Void
    let onSizeChange: @MainActor (CGSize) -> Void

    /// - Parameters:
    ///   - model: the alerts
    ///   - rebuildWithChanges: opens the sheet of "Rebuild with Changes…" for the page's build and dismisses the page
    ///   - perform: runs a button's action for an alert; the window then dismisses the page
    ///   - dismissAll: closes the window
    ///   - onSizeChange: the content's size, when it changed
    public init(
        model: AlertPanelModel, rebuildWithChanges: (@MainActor (BuildAlert) -> Void)?,
        perform: @escaping @MainActor (BuildAlert, AlertContent.Action) -> Void,
        dismissAll: @escaping @MainActor () -> Void, onSizeChange: @escaping @MainActor (CGSize) -> Void
    ) {
        self.model = model
        self.rebuildWithChanges = rebuildWithChanges
        self.perform = perform
        self.dismissAll = dismissAll
        self.onSizeChange = onSizeChange
    }

    public var body: some View {
        if let page = model.pages.current {
            let alert = page.alert
            BuildAlertView(
                alert: alert, notificationsOff: page.notificationsOff, pager: pager,
                rebuildWithChanges: rebuildWithChanges.map { open in { open(alert) } }
            ) { action in
                perform(alert, action)
            }
            .id(alert.id)
            .onGeometryChange(for: CGSize.self, of: \.size) { onSizeChange($0) }
            // Pinned to the top: while the window changes its height, the page doesn't slide.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var pager: AlertPager? {
        guard model.pages.count > 1 else {
            return nil
        }
        let model = model
        return AlertPager(
            position: model.pages.position, hasPrevious: model.pages.hasPrevious, hasNext: model.pages.hasNext,
            previous: { model.pages.previous() }, next: { model.pages.next() }, dismissAll: dismissAll)
    }
}
