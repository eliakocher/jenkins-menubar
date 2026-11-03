import Foundation

extension AppModel {
    /// Mutes the alerts for an hour, or ends the mute while they are muted (HOT-09): the Mute Alerts hot corner, and
    /// whatever else offers it.
    ///
    /// - Returns: whether the alerts are muted afterwards
    @discardableResult
    public func toggleMuteAlerts() -> Bool {
        alertMute.toggle()
    }

    /// Takes over the old Hot Corners app's settings, once (HOT-08). It runs only when the old app has stored any, and
    /// never over Hot Corners the user has set up here already; either way it is marked done and never runs again.
    func importLegacyHotCorners() {
        let defaults = preferencesStore.userDefaults
        guard !defaults.bool(forKey: HotCornerImport.markerKey),
            let legacy = dependencies.hotCornerSystem.legacyDefaults()
        else {
            return
        }
        defaults.set(true, forKey: HotCornerImport.markerKey)
        guard settings.preferences.hotCorners == HotCornerSettings() else {
            Task { [log] in await log.log(.info, .settings, "Mega Corners: kept the settings here, the old app's are not imported") }
            return
        }
        var preferences = settings.preferences
        preferences.hotCorners = HotCornerImport.settings(from: legacy)
        Task { [log] in await log.log(.info, .settings, "Mega Corners: imported the old Hot Corners app's settings") }
        settings.preferences = preferences
    }
}
