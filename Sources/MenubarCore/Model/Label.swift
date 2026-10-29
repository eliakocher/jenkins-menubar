import Foundation

/// A GitLab label. Its title is plain text everywhere: never markup, a command, a format string or a link (WI-04).
public struct Label: Codable, Hashable, Identifiable, Sendable {
    /// the title, like `uStatus::InProgress`; scoped labels have `::`
    public var title: String
    /// GitLab's background color, like `#428BCA`; `nil` when not known
    public var color: String?

    public init(title: String, color: String? = nil) {
        self.title = title
        self.color = color
    }

    public var id: String { title }
}
