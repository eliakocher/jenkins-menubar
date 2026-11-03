import Foundation

extension AppModel {
    /// Hands the fun layer what it reads of the app: my running builds, Haiku for the daily batch, the status icon's nod and
    /// the sample alerts of Settings → General → Surprise Me.
    func connectFun() {
        fun.runningBuilds = { [weak self] in
            self?.projects.stores.flatMap { $0.state.builds.filter { $0.isRunning && $0.kind == .mine } } ?? []
        }
        fun.askBatch = { [ai] date in await ai.funBatch(on: date) }
        fun.nod = { [weak self] in
            guard let self else { return }
            self.eggs.nod(reduceMotion: self.fun.reduceMotion())
        }
        fun.showSample = { [weak self] line, celebration, success in
            guard let self, var alert = BuildAlert.preview(success ? .success : .failure, team: self.settings.primaryTeam)
            else {
                return false
            }
            alert.content.eggLine = line
            alert.content.celebration = celebration
            alert.content.funLevel = self.fun.level
            let announcer = AlertAnnouncer(effects: self.dependencies.effects, log: self.log)
            let preferences = self.settings.preferences
            Task { await announcer.announce(alert, preferences: preferences) }
            return true
        }
        mergeRequestDetails.merge.onMerged = { [weak self] mergeRequest in
            self?.fun.merged(reference: mergeRequest.reference)
        }
    }
}
