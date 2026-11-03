import MenubarCore
import SwiftUI

/// What the status icon shows: the butler when nothing is counted, the problem marker, and the four counts, in that
/// order (PIPE-05, `docs/design/status-icon.md`), then the Inbox dot; or whatever Settings → Menu Bar's layout says,
/// in its order (APP-11).
///
/// The stores compute it; ``StatusLabel`` draws it, Settings → Menu Bar's preview and the gallery draw it from samples.
public struct StatusLabelModel: Hashable, Sendable {
    /// Why the problem marker shows.
    public enum ProblemKind: Hashable, Sendable {
        /// a Jenkins problem (JERR)
        case jenkins
        /// the team values are missing (TEAM-03)
        case teamValues
        /// the Mac has no network path (OD-05)
        case offline
    }

    /// One part of the icon, in the order it shows.
    public enum Part: Hashable, Sendable {
        /// the butler, `icons/menubar.png`
        case identity
        case problem
        case count(BuildCounts.Kind, Int)
        /// a small red dot: the Inbox has items that count in its badge (Task 7.03); red in both styles. Never animated.
        case inboxDot
        /// the Inbox's badge as a number, with the tray, when the layout asks for the count (APP-11)
        case inboxCount(Int)
        /// the merge requests that wait for my review, with the eye (APP-11)
        case reviews(Int)
        /// the next date of my committed slot, "freeze 3d"; urgent from the team's warning days on (APP-11)
        case slot(String, urgent: Bool)
    }

    /// The next date of the committed slot, short enough for the menu bar.
    public struct SlotCountdown: Hashable, Sendable {
        /// "freeze 3d", "release today"
        public var text: String
        /// whether it is within the team's warning days of the code freeze, which the color style shows in orange
        public var isUrgent: Bool

        public init(text: String, isUrgent: Bool) {
            self.text = text
            self.isUrgent = isUrgent
        }

        /// Returns the countdown of a slot's dates: the next milestone and the days until it.
        ///
        /// - Parameters:
        ///   - dates: the slot's dates
        ///   - warnDays: the team's warning days before the code freeze
        ///   - today: any time of today
        ///   - calendar: the calendar whose days count
        /// - Returns: `nil` once every date is past
        public init?(dates: SlotDates, warnDays: Int, today: Date, calendar: Calendar = .current) {
            guard let (milestone, days) = dates.next(from: today, calendar: calendar) else { return nil }
            let word = switch milestone {
            case .codeFreeze: "freeze"
            case .earlyAccess: "EA"
            case .release: "release"
            }
            text = "\(word) \(days == 0 ? "today" : "\(days)d")"
            isUrgent = milestone == .codeFreeze && days <= warnDays
        }
    }

    /// How the menu bar can draw the parts (`docs/decisions.md`, Task 4.2 and the label fix after it).
    public enum Rendering: Hashable, Sendable {
        /// the butler alone, as an image
        case identity
        /// one image rendered from the parts, symbols and numbers in order: the status button keeps only one image
        /// or one title, and the real menu bar dropped the symbols of a `Text` the probe had shown
        case image
    }

    /// the problem marker's reason; `nil` without one
    public var problem: ProblemKind?
    public var counts: BuildCounts
    public var style: Preferences.IconStyle
    /// the hat the butler wears wherever it shows: the idle icon and the bow (EGG-03, EGG-04)
    public var hat: ButlerHat?
    /// the bow frame of the Konami egg; the butler joins the counts for it (EGG-02)
    public var bow: BowFrame?
    /// the Inbox's badge: the items that count in it, which the red dot or the count shows
    public var inboxCount: Int
    /// the merge requests that wait for my review; read only while the layout shows them
    public var reviewCount: Int
    /// the committed slot's next date; read only while the layout shows it
    public var slot: SlotCountdown?
    /// what shows and in which order (APP-11); the default is the look from before
    public var layout: MenuBarLayout

    /// whether the Inbox has items that count in its badge
    public var hasInboxItems: Bool {
        inboxCount > 0
    }

    public init(problem: ProblemKind? = nil, counts: BuildCounts = BuildCounts(),
                style: Preferences.IconStyle = .monochrome, hat: ButlerHat? = nil, bow: BowFrame? = nil,
                hasInboxItems: Bool = false, inboxCount: Int? = nil, reviewCount: Int = 0, slot: SlotCountdown? = nil,
                layout: MenuBarLayout = MenuBarLayout()) {
        self.inboxCount = inboxCount ?? (hasInboxItems ? 1 : 0)
        self.reviewCount = reviewCount
        self.slot = slot
        self.layout = layout
        self.problem = problem
        self.counts = counts
        self.style = style
        self.hat = hat
        self.bow = bow
    }

    /// Returns the model for a problem, as the stores report it: only the problems that mark the status icon count,
    /// never a GitLab problem (PIPE-05).
    ///
    /// - Parameters:
    ///   - problem: the Jenkins problem, offline first (`PipelinesStore.problem`)
    ///   - counts: the counts of the builds that show
    ///   - style: the icon style
    ///   - hat: the butler's hat; `nil` for none
    ///   - bow: the bow frame while the Konami egg plays; `nil` otherwise
    ///   - inboxCount: the Inbox's badge
    ///   - reviewCount: the merge requests that wait for my review
    ///   - slot: the committed slot's next date
    ///   - layout: what shows and in which order
    public init(
        problem: Problem?, counts: BuildCounts, style: Preferences.IconStyle, hat: ButlerHat? = nil, bow: BowFrame? = nil,
        inboxCount: Int = 0, reviewCount: Int = 0, slot: SlotCountdown? = nil, layout: MenuBarLayout = MenuBarLayout()
    ) {
        self.init(
            problem: Self.kind(of: problem), counts: counts, style: style, hat: hat, bow: bow, inboxCount: inboxCount,
            reviewCount: reviewCount, slot: slot, layout: layout)
    }

    /// Returns the kind of problem marker a problem shows, if any.
    ///
    /// - Parameter problem: the problem
    /// - Returns: `nil` for none and for problems that leave the icon alone
    public static func kind(of problem: Problem?) -> ProblemKind? {
        guard let problem, problem.marksStatusIcon else {
            return nil
        }
        switch problem {
        case .teamValuesMissing: return .teamValues
        case .offline: return .offline
        default: return .jenkins
        }
    }

    /// The parts in their order: the butler as the layout says (by default only when no build is counted, and while it
    /// bows), then the layout's parts that are on; a count only above 0 unless the layout shows zero counts. The butler
    /// shows whenever nothing else does, so the item is never empty.
    public var parts: [Part] {
        let hidesZero = layout.hidesZeroCounts
        var shown: [Part] = []
        var counted = 0
        for part in layout.parts where part.isOn {
            switch part.part {
            case .problem:
                if problem != nil {
                    shown.append(.problem)
                }
            case .running, .failed, .unstable, .successful:
                guard let kind = part.part.buildKind else { continue }
                let count = Self.count(of: kind, in: counts)
                counted += count
                if count > 0 || !hidesZero {
                    shown.append(.count(kind, count))
                }
            case .inbox:
                switch layout.inboxStyle {
                case .dot where inboxCount > 0:
                    shown.append(.inboxDot)
                case .count where inboxCount > 0 || !hidesZero:
                    shown.append(.inboxCount(inboxCount))
                default:
                    break
                }
            case .reviews:
                if reviewCount > 0 || !hidesZero {
                    shown.append(.reviews(reviewCount))
                }
            case .slot:
                if let slot {
                    shown.append(.slot(slot.text, urgent: slot.isUrgent))
                }
            }
        }
        let butler: Bool
        switch layout.butler {
        case .whenIdle: butler = counted == 0
        case .always: butler = true
        case .never: butler = shown.isEmpty
        }
        return butler || bow != nil || shown.isEmpty ? [.identity] + shown : shown
    }

    /// Returns the count of a build kind.
    static func count(of kind: BuildCounts.Kind, in counts: BuildCounts) -> Int {
        switch kind {
        case .running: counts.running
        case .failed: counts.failed
        case .unstable: counts.unstable
        case .successful: counts.successful
        }
    }

    /// whether the monochrome item has the red Inbox dot: the rest stays the menu bar's tint and only the dot is red, so
    /// the image is the template tinted where it is drawn, with the dot on top
    public var hasRedDotOnTemplate: Bool {
        style == .monochrome && parts.contains(.inboxDot)
    }

    /// how the parts are drawn
    public var rendering: Rendering {
        parts == [.identity] ? .identity : .image
    }

    /// Returns a part's SF Symbol; `nil` for the butler.
    public static func symbol(of part: Part) -> String? {
        switch part {
        case .identity: nil
        case .problem: Marker.problem
        case .inboxDot: nil
        case .inboxCount: MainWindowSection.inbox.systemImage
        case .reviews: "eye"
        case .slot: "calendar"
        case .count(.running, _): BuildState.running.symbol
        case .count(.failed, _): BuildState.failed.symbol
        case .count(.unstable, _): BuildState.unstable.symbol
        case .count(.successful, _): BuildState.successful.symbol
        }
    }

    /// Returns a part's color: only in the color style, only for failed, unstable, successful and the problem
    /// marker. The monochrome style is a template image, which the menu bar tints.
    ///
    /// - Parameter part: the part
    /// - Returns: the color; `nil` for the menu bar's own tint
    public func color(of part: Part) -> Color? {
        // The Inbox dot is red in both styles (the user, 2026-11-03).
        if case .inboxDot = part {
            return .red
        }
        guard style == .color else {
            return nil
        }
        switch part {
        case .problem: return .red
        case .inboxCount: return .red
        case .reviews: return .orange
        case .slot(_, let urgent): return urgent ? .orange : nil
        case .count(.failed, _): return BuildState.failed.color
        case .count(.unstable, _): return BuildState.unstable.color
        case .count(.successful, _): return BuildState.successful.color
        default: return nil
        }
    }
}
