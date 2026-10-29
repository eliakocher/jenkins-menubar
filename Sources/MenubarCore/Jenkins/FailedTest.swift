import Foundation

/// A test of a build's test report that failed, with the start of its error message (PIPE-03).
public struct FailedTest: Hashable, Sendable {
    /// How a failed test counts in Jenkins' test report. Any other status, such as PASSED, SKIPPED or FIXED, isn't a
    /// failure.
    public enum Status: String, Hashable, Sendable {
        /// failing, as in the build before
        case failed = "FAILED"
        /// failing, and passing in the build before
        case regression = "REGRESSION"
    }

    /// the test class with its package, like `com.example.cart.CartServiceTest`; empty when the report has none
    public var className: String
    /// the test method, like `addsAnItem` (JUnit 5 keeps the parentheses)
    public var name: String
    public var status: Status
    /// the first lines of the error message, see ``preview(of:)``; `nil` when the report has none
    public var message: String?

    public init(className: String, name: String, status: Status, message: String? = nil) {
        self.className = className
        self.name = name
        self.status = status
        self.message = message
    }

    /// the class without its package, like `CartServiceTest`; empty when the report has no class
    public var shortClassName: String {
        className.split(separator: ".", omittingEmptySubsequences: true).last.map(String.init) ?? ""
    }

    /// the most lines of an error message kept
    static let previewLines = 2
    /// the most characters of a kept line; a longer one ends with an ellipsis
    static let previewLineLength = 240

    /// Returns the first lines of an error message: at most ``previewLines`` of the non-empty ones, trimmed and cut at
    /// ``previewLineLength``, so a stack trace in the message doesn't fill the detail.
    ///
    /// - Parameter details: Jenkins' `errorDetails`
    /// - Returns: the lines, joined by a line break; `nil` when there is no text
    static func preview(of details: String?) -> String? {
        let lines = (details ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(previewLines)
            .map { $0.count > previewLineLength ? String($0.prefix(previewLineLength)) + "…" : $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
