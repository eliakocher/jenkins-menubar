import MenubarCore
import SwiftUI

/// What the status icon shows: the butler when nothing is counted, the problem marker, and the four counts, in that
/// order (PIPE-05, `docs/design/status-icon.md`).
///
/// The stores compute it; ``StatusLabel`` draws it, and the gallery draws it from fixtures.
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

    public init(problem: ProblemKind? = nil, counts: BuildCounts = BuildCounts(),
                style: Preferences.IconStyle = .monochrome, hat: ButlerHat? = nil, bow: BowFrame? = nil) {
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
    public init(
        problem: Problem?, counts: BuildCounts, style: Preferences.IconStyle, hat: ButlerHat? = nil, bow: BowFrame? = nil
    ) {
        self.init(problem: Self.kind(of: problem), counts: counts, style: style, hat: hat, bow: bow)
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

    /// the parts in their order: the butler only when nothing is counted, or while it bows; a count only above 0
    public var parts: [Part] {
        var parts: [Part] = []
        if counts.isEmpty || bow != nil {
            parts.append(.identity)
        }
        if problem != nil {
            parts.append(.problem)
        }
        parts += counts.shown.map { Part.count($0.kind, $0.count) }
        return parts
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
        guard style == .color else {
            return nil
        }
        switch part {
        case .problem: return .red
        case .count(.failed, _): return BuildState.failed.color
        case .count(.unstable, _): return BuildState.unstable.color
        case .count(.successful, _): return BuildState.successful.color
        default: return nil
        }
    }
}
