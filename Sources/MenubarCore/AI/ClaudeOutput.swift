import Foundation

/// The tokens an answer used, as `claude` reports them: the input counts the prompt, the cached part included.
public struct ClaudeUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// What one `claude -p --output-format json` run reported (AI-01): the answer, the structured answer when a JSON Schema
/// was given, the tokens, the cost and the time, or the error.
///
/// Measured on 2026-10-29 with Claude Code 2.1.312: one JSON object with `type: "result"`, `subtype` (`success`, or an
/// error like `error_max_budget_usd`), `is_error`, `result` (the text; `null` on an error), `structured_output` (with
/// `--json-schema`), `errors` (on an error), `total_cost_usd`, `duration_ms`, `usage` (`input_tokens`,
/// `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`) and `modelUsage` keyed by the model.
public struct ClaudeRun: Hashable, Sendable {
    /// the answer as text; for a structured answer, its JSON
    public var text: String?
    /// the structured answer's JSON, when a schema was given
    public var structured: Data?
    public var usage: ClaudeUsage
    /// the cost `claude` reports, in US dollars; spent on an error too
    public var costUSD: Double
    /// how long it took, as `claude` measured it
    public var durationMS: Int?
    /// the model that answered, like `claude-opus-5-5`
    public var model: String?
    public var isError: Bool
    /// `success`, or the kind of error, like `error_max_budget_usd`
    public var subtype: String?
    /// the error messages
    public var errors: [String]
    /// `claude`'s exit status, which the engine sets: 0 for an answer, 1 for an error answer
    public var exitStatus: Int32 = 0

    public init(
        text: String? = nil, structured: Data? = nil, usage: ClaudeUsage = ClaudeUsage(), costUSD: Double = 0,
        durationMS: Int? = nil, model: String? = nil, isError: Bool = false, subtype: String? = nil, errors: [String] = []
    ) {
        self.text = text
        self.structured = structured
        self.usage = usage
        self.costUSD = costUSD
        self.durationMS = durationMS
        self.model = model
        self.isError = isError
        self.subtype = subtype
        self.errors = errors
    }

    /// Reads `claude`'s JSON output.
    ///
    /// - Parameter data: stdout of `claude -p --output-format json`
    /// - Returns: the run
    /// - Throws: when stdout isn't that JSON object
    public static func parse(_ data: Data) throws -> ClaudeRun {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let shape = try decoder.decode(Shape.self, from: data)
        guard shape.type == nil || shape.type == "result" else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a result"))
        }
        var structured: Data?
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["structured_output"], !(value is NSNull),
           JSONSerialization.isValidJSONObject(value) {
            structured = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        let usage = shape.usage.map {
            ClaudeUsage(
                inputTokens: ($0.inputTokens ?? 0) + ($0.cacheCreationInputTokens ?? 0) + ($0.cacheReadInputTokens ?? 0),
                outputTokens: $0.outputTokens ?? 0)
        } ?? ClaudeUsage()
        return ClaudeRun(
            text: shape.result, structured: structured, usage: usage, costUSD: shape.totalCostUsd ?? 0,
            durationMS: shape.durationMs, model: shape.modelUsage?.keys.sorted().first,
            isError: shape.isError ?? (shape.subtype.map { $0 != "success" } ?? false), subtype: shape.subtype,
            errors: shape.errors ?? [])
    }

    /// Decodes the structured answer: `structured_output`, else the text when it is that JSON.
    ///
    /// - Parameter type: the answer's type
    /// - Returns: the answer; `nil` when neither holds it
    public func decoded<Answer: Decodable>(_ type: Answer.Type) -> Answer? {
        let decoder = JSONDecoder()
        if let structured, let answer = try? decoder.decode(type, from: structured) {
            return answer
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        // A model may wrap the JSON in a code fence.
        let json = text.drop { $0 != "{" }.reversed().drop { $0 != "}" }.reversed()
        return try? decoder.decode(type, from: Data(String(json).utf8))
    }

    /// the error in a line, for the failure: "Reached maximum budget ($0.01)"
    public var errorMessage: String {
        if let first = errors.first(where: { !$0.isEmpty }) {
            return first
        }
        if let text, !text.isEmpty {
            return String(text.prefix(300))
        }
        return "Claude answered with \(subtype ?? "an error")"
    }

    /// The fields of the output; `claude` names them in snake case.
    private struct Shape: Decodable {
        struct Usage: Decodable {
            var inputTokens: Int?
            var cacheCreationInputTokens: Int?
            var cacheReadInputTokens: Int?
            var outputTokens: Int?
        }

        struct ModelUsage: Decodable {}

        var type: String?
        var subtype: String?
        var isError: Bool?
        var result: String?
        var errors: [String]?
        var totalCostUsd: Double?
        var durationMs: Int?
        var usage: Usage?
        var modelUsage: [String: ModelUsage]?
    }
}

/// "Why Did It Fail?": the likely cause, the fix, and real failure or flaky (AI-02).
public struct BuildExplanation: Codable, Hashable, Sendable {
    /// Claude's verdict on the failure.
    public enum Verdict: String, Codable, Hashable, Sendable {
        case real
        case flaky
        case unclear

        /// "Real failure", "Likely flaky", "Unclear"
        public var title: String {
            switch self {
            case .real: "Real failure"
            case .flaky: "Likely flaky"
            case .unclear: "Real or flaky: unclear"
            }
        }
    }

    public var cause: String
    public var fix: String
    public var verdict: Verdict

    public init(cause: String, fix: String, verdict: Verdict) {
        self.cause = cause
        self.fix = fix
        self.verdict = verdict
    }

    private enum CodingKeys: String, CodingKey {
        case cause, fix, verdict
    }

    // A verdict outside the schema reads as unclear, not as a failed answer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cause = try container.decode(String.self, forKey: .cause)
        fix = try container.decode(String.self, forKey: .fix)
        verdict = (try? container.decode(Verdict.self, forKey: .verdict)) ?? .unclear
    }
}

/// A merge request discussion summarized: what was agreed, and what is open and on whom it waits (AI-03).
public struct ThreadsSummary: Codable, Hashable, Sendable {
    /// One open point and who it waits on.
    public struct OpenPoint: Codable, Hashable, Sendable {
        public var point: String
        public var waitingOn: String

        public init(point: String, waitingOn: String) {
            self.point = point
            self.waitingOn = waitingOn
        }
    }

    public var agreed: [String]
    public var open: [OpenPoint]

    public init(agreed: [String], open: [OpenPoint]) {
        self.agreed = agreed
        self.open = open
    }
}
