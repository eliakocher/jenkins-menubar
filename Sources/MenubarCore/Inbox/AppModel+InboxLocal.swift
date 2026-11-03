import Foundation

extension AISubject {
    /// the use case that answers about this subject, for the Inbox's line
    var useCase: AIUseCase {
        switch self {
        case .build: .explainBuild
        case .mergeRequest: .summarizeThreads
        case .digest: .digest
        case .codeChat: .askAboutCode
        case .workItem: .askAboutItem
        }
    }

    /// a stable text for the subject, for the ids of its entries
    var inboxKey: String {
        switch self {
        case .build(let id): "build:\(id.jobKey)#\(id.number)"
        case .mergeRequest(let reference): "mr:\(reference)"
        case .digest: "digest"
        case .codeChat(let reference): "chat:\(reference)"
        case .workItem(let reference): "item:\(reference)"
        }
    }
}

extension AIUseCase {
    /// the use case in Title Style, as the Inbox's line says it: "Claude answered: Why Did It Fail?"
    var inboxTitle: String {
        switch self {
        case .explainBuild: "Why Did It Fail?"
        case .summarizeThreads: "Summarize Discussion"
        case .digest: "Daily Digest"
        case .openInClaudeCode: "Continue in Claude Code"
        case .askAboutCode: "Question About Code"
        case .askAboutItem: "Question About a Work Item"
        case .coffeeBreak: "Coffee Break"
        }
    }
}

extension AILanding {
    /// the first line of what landed: the verdict, the open points, the digest's summary, the text's first line, or the
    /// reason for a failure
    var inboxExcerpt: String? {
        if let failure {
            return failure
        }
        if let text {
            return text
        }
        guard let answer else {
            return nil
        }
        if let explanation = answer.explanation {
            return "\(explanation.verdict.title): \(explanation.headline)"
        }
        if let summary = answer.summary {
            if let point = summary.open.first {
                return summary.open.count == 1 ? "1 open point: \(point.point)" : "\(summary.open.count) open points, first: \(point.point)"
            }
            return summary.agreed.isEmpty ? "Nothing open" : "Nothing open, \(summary.agreed.count) agreed"
        }
        return answer.digest?.summaryLine ?? answer.text
    }
}

extension AppModel {
    /// Hands the Inbox the things of this app: a Claude answer that landed while its card wasn't on screen (the digest
    /// included), and a finished build that failed or went unstable (Task 7.03).
    func connectInboxLocal() {
        ai.onAnswerLanded = { [weak self] landing in
            self?.addToInbox(landing)
        }
        projects.onFinishedBuilds = { [weak self] alerts in
            self?.addToInbox(finished: alerts)
        }
    }

    /// Adds a landed answer to the Inbox, with a link back to where it is.
    func addToInbox(_ landing: AILanding) {
        let subject = landing.subject
        if subject == .digest {
            // One entry a day: a manual digest and the morning one are the same news.
            inbox.addLocal(
                .digestReady(
                    summary: landing.failure == nil ? landing.inboxExcerpt : nil, url: AppRoute.open(.digest).url, at: landing.at))
            return
        }
        let place = inboxPlace(of: subject)
        inbox.addLocal(
            .claudeAnswered(
                subjectKey: subject.inboxKey, useCase: landing.useCase.inboxTitle, failed: landing.failure != nil,
                title: place.title, reference: place.reference, excerpt: landing.inboxExcerpt, url: place.url, at: landing.at))
    }

    /// Adds the failed and unstable builds of a check to the Inbox, and clears the failed entries of a job whose build
    /// is green now. A muted job's alerts never get here.
    func addToInbox(finished alerts: [BuildAlert]) {
        for alert in alerts where alert.kind == .finished {
            let build = alert.build
            switch alert.content.result {
            case .failure, .unstable:
                inbox.addLocal(
                    .buildFailed(
                        jobKey: build.id.jobKey, number: build.id.number, label: build.id.label,
                        isUnstable: alert.content.result == .unstable, title: build.title, url: alert.content.links.build,
                        at: build.finishedAt ?? dependencies.now()))
            case .success:
                inbox.resolveLocal(kind: .buildFailed, idPrefix: InboxEvent.buildIDPrefix(jobKey: build.id.jobKey))
            case .aborted, .other:
                break
            }
        }
    }

    /// Returns the title, the reference and the link of what an answer is about.
    private func inboxPlace(of subject: AISubject) -> (title: String, reference: String?, url: URL?) {
        let gitLab = team.primaryProject().team.gitLab
        switch subject {
        case .build(let id):
            let build = (projects.myBuilds + projects.watchedBuilds).first { $0.id == id }
            let jobURL = team.project(id.project)?.team.jenkinsJob ?? team.primaryProject().team.jenkinsJob
            let url = jobURL.map { AlertContent.buildURL(job: id.job, number: id.number, jobURL: $0) }
            return (build?.title ?? id.label, id.label, url ?? AppRoute.open(.pipelines).url)
        case .mergeRequest(let reference), .codeChat(let reference):
            let wanted = reference.lowercased()
            let known = mergeRequests.list?.mergeRequests.first { $0.reference.lowercased() == wanted }
                ?? opened.mergeRequests.values.first { $0.reference.lowercased() == wanted }
            let url = known?.webURL ?? gitLab.flatMap { Self.itemURL(of: reference, "merge_requests", on: $0) }
            return (known?.title ?? reference, reference, url ?? AppRoute.open(.mergeRequests).url)
        case .workItem(let reference):
            let wanted = reference.lowercased()
            let known = workItems.lists?.all.first { $0.reference.lowercased() == wanted }
                ?? opened.workItems.values.first { $0.reference.lowercased() == wanted }
            let url = known?.webURL ?? gitLab.flatMap { Self.itemURL(of: reference, "work_items", on: $0) }
            return (known?.displayTitle ?? reference, reference, url ?? AppRoute.open(.workItems).url)
        case .digest:
            return ("Your digest", nil, AppRoute.open(.digest).url)
        }
    }

    /// `group/project!12` on a GitLab → `<GitLab>/group/project/-/merge_requests/12`
    private static func itemURL(of reference: String, _ kind: String, on gitLab: URL) -> URL? {
        guard let sign = reference.lastIndex(where: { $0 == "!" || $0 == "#" }),
            Int(reference[reference.index(after: sign)...]) != nil
        else {
            return nil
        }
        let path = reference[..<sign]
        let number = reference[reference.index(after: sign)...]
        return URL(string: gitLab.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/\(path)/-/\(kind)/\(number)")
    }
}
