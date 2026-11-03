import MenubarCore
import SwiftUI

/// A click on a stage of the Stages card, waiting for the Console Log card to show where the stage starts (PIPE-12).
///
/// The build detail owns one and puts it in the environment; the Stages card asks, the Console Log card takes the request
/// once: it opens, reads until it has the stage's first line, and scrolls to it.
@Observable @MainActor
final class ConsoleLogStageJump {
    struct Request: Equatable {
        var id = UUID()
        var stage: String
    }

    private(set) var pending: Request?

    /// Asks for a stage's first line; a request that waits is replaced.
    func ask(stage: String) {
        pending = Request(stage: stage)
    }

    /// Takes the waiting request, which then is gone.
    func take() -> String? {
        defer { pending = nil }
        return pending?.stage
    }
}

private struct ConsoleLogStageJumpKey: EnvironmentKey {
    static let defaultValue: ConsoleLogStageJump? = nil
}

extension EnvironmentValues {
    /// the build detail's stage clicks for the Console Log card; `nil` where a page has no such card, as the gallery's
    var consoleLogStageJump: ConsoleLogStageJump? {
        get { self[ConsoleLogStageJumpKey.self] }
        set { self[ConsoleLogStageJumpKey.self] = newValue }
    }
}
