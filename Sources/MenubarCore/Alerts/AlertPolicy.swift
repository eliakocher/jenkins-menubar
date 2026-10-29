import Foundation

/// What the alerts remember of a followed job's last build from one check to the next.
///
/// A check keeps one per job it followed, from ``AlertPolicy/states(after:previous:)``, and the next check's alerts
/// compare against them.
public struct AlertState: Codable, Hashable, Sendable {
    /// the number of the job's last build
    public var number: Int
    public var isRunning: Bool
    /// the build's failed stages last known; empty when none are known (ALERT-05)
    public var failedStages: [String]

    public init(number: Int, isRunning: Bool, failedStages: [String] = []) {
        self.number = number
        self.isRunning = isRunning
        self.failedStages = failedStages
    }
}

extension CacheFile where Value == [String: AlertState] {
    /// the alert states per job after the last check, which the next check's alerts compare against
    public static var alertStates: CacheFile { CacheFile("alert-states") }
}

/// Decides which alerts a check fires, by comparing the builds it found with what the previous check knew.
///
/// - A finished build alerts once: when the previous check saw it running (ALERT-01), or when it started after the
///   previous check, which knew the job with an earlier build.
/// - A job the previous check didn't know never alerts, so a build already finished when first seen stays quiet, and so
///   does the first check after the start.
/// - A running build that a newer one replaced gets no alert; the newer one is followed (ALERT-06).
/// - A running build whose failed stages differ from those last known for its number gets a stage banner (ALERT-05).
public struct AlertPolicy: Sendable {
    /// the team's Jenkins multibranch job, which the alerts link into
    public var jobURL: URL

    public init(jobURL: URL) {
        self.jobURL = jobURL
    }

    /// Returns the alerts of a check.
    ///
    /// - Parameters:
    ///   - previous: the alert states after the previous check, per job; from ``states(after:previous:)``
    ///   - current: the last build of each followed job, as this check found it; a job Jenkins didn't answer for keeps
    ///     its earlier build
    ///   - lastCheck: when the previous check started; `nil` before the first check since the start, which never alerts
    ///   - preferences: whether stage banners are on
    /// - Returns: the alerts, in the order of `current`
    public func alerts(
        previous: [String: AlertState],
        current: [Build],
        lastCheck: Date?,
        preferences: Preferences
    ) -> [BuildAlert] {
        guard let lastCheck else {
            return []
        }
        var alerts: [BuildAlert] = []
        for build in current {
            guard let known = previous[build.job], build.number >= known.number else {
                continue
            }
            let failedStages = Self.failedStages(of: build, known: known)
            let isSame = build.number == known.number
            if !build.isRunning {
                // A build that started after the previous check finished between the two; one that started before
                // could only come from an earlier build state that Jenkins didn't refresh, and is old news.
                let finishedSinceLastCheck = isSame ? known.isRunning : build.startedAt > lastCheck
                if finishedSinceLastCheck,
                    let content = AlertContent.finished(
                        build, failedStages: failedStages, links: AlertContent.links(for: build, jobURL: jobURL))
                {
                    alerts.append(BuildAlert(kind: .finished, build: build, content: content))
                }
            } else if preferences.stageAlerts, !failedStages.isEmpty,
                failedStages != (isSame ? known.failedStages : [])
            {
                let content = AlertContent.stageFailed(
                    build, failedStages: failedStages,
                    buildURL: AlertContent.buildURL(job: build.job, number: build.number, jobURL: jobURL))
                alerts.append(BuildAlert(kind: .stageFailed, build: build, content: content))
            }
        }
        return alerts
    }

    /// Returns the alert states to keep after a check, for the next check to compare against.
    ///
    /// - Parameters:
    ///   - current: the last build of each followed job, as this check found it
    ///   - previous: the alert states after the previous check
    /// - Returns: one state per job in `current`; a job that is gone is forgotten
    public static func states(after current: [Build], previous: [String: AlertState]) -> [String: AlertState] {
        var states: [String: AlertState] = [:]
        for build in current {
            states[build.job] = AlertState(
                number: build.number, isRunning: build.isRunning,
                failedStages: failedStages(of: build, known: previous[build.job]))
        }
        return states
    }

    /// The build's failed stages: as found now, or, when the stages request failed, as last known for the same build
    /// number, so a stage banner isn't repeated once the request works again (PIPE-04). A new build number starts with
    /// none known.
    private static func failedStages(of build: Build, known: AlertState?) -> [String] {
        if let failed = build.failedStages {
            return failed
        }
        guard let known, known.number == build.number else {
            return []
        }
        return known.failedStages
    }
}
