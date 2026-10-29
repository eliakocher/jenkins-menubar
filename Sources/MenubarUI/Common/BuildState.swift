import MenubarCore
import SwiftUI

/// The app's build-state vocabulary (`docs/design/status-icon.md`, SF Symbols): one symbol, color and word per
/// meaning, which the status icon, the panel, the alert and the windows share.
public enum BuildState: Hashable, Sendable {
    case running
    /// finished with FAILURE
    case failed
    case unstable
    /// finished with SUCCESS
    case successful
    case aborted
    /// any other result, like NOT_BUILT, as Jenkins names it
    case other(String)

    /// Returns the state of a build.
    ///
    /// - Parameter build: the build
    /// - Returns: running while it runs, otherwise its result
    public init(_ build: Build) {
        guard let result = build.result else {
            self = .running
            return
        }
        self.init(result)
    }

    /// Returns the state of a finished build's result.
    ///
    /// - Parameter result: Jenkins' result
    /// - Returns: the state
    public init(_ result: BuildResult) {
        switch result {
        case .success: self = .successful
        case .failure: self = .failed
        case .unstable: self = .unstable
        case .aborted: self = .aborted
        default: self = .other(result.rawValue)
        }
    }

    /// the SF Symbol's name
    public var symbol: String {
        switch self {
        case .running: "hourglass"
        case .failed: "xmark.circle.fill"
        case .unstable: "exclamationmark.triangle"
        case .successful: "checkmark.circle"
        case .aborted: "stop.circle"
        case .other: "questionmark.circle"
        }
    }

    /// the symbol's color in rows and the alert, and in the status icon's color style; `nil` for the label color
    /// (template-tinted in the menu bar)
    public var color: Color? {
        switch self {
        case .running: nil
        case .failed: .red
        case .unstable: .orange
        case .successful: .green
        case .aborted, .other: .secondary
        }
    }

    /// the result as Jenkins writes it, like `FAILURE`, which the rows and the alert show; `nil` while running
    public var resultText: String? {
        switch self {
        case .running: nil
        case .failed: BuildResult.failure.rawValue
        case .unstable: BuildResult.unstable.rawValue
        case .successful: BuildResult.success.rawValue
        case .aborted: BuildResult.aborted.rawValue
        case .other(let result): result
        }
    }
}

/// The two markers of the status icon and the problem rows.
enum Marker {
    /// the problem marker: Jenkins problems, missing team values, offline; also a problem row's symbol
    static let problem = "exclamationmark.circle"
    /// the update marker (APP-05)
    static let update = "arrow.down.circle"
}

extension View {
    /// Colors a symbol with a vocabulary color, or leaves it in the label color.
    func tint(_ color: Color?) -> some View {
        foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
    }
}
