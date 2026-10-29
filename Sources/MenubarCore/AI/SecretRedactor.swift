import Foundation

/// Takes tokens, cookies, keys and passwords out of a text before it goes to Claude (AI-06). The user's policy
/// (2026-10-29): everything may be sent, code too, except secrets.
///
/// It replaces, in this order:
/// - the app's own tokens, as stored and, for Jenkins, the API token inside the stored `user:token`;
/// - private key blocks;
/// - the values of `Authorization`, `Cookie` and `Set-Cookie` headers;
/// - the password of a URL's `user:password@`;
/// - the value after a name that says it is secret (`password=…`, `"api_key": "…"`, `GITLAB_TOKEN: …`);
/// - tokens by their known shapes: GitLab, GitHub, Slack, Anthropic and OpenAI, AWS, Google, npm, Jenkins API tokens
///   and JWTs.
///
/// Each one becomes ``mark``. It errs on the side of removing: a build log that loses a value it didn't need to is
/// fine; a token that leaves the Mac is not.
public struct SecretRedactor: Sendable {
    /// what a secret is replaced with
    public static let mark = "[redacted]"
    /// the shortest known secret replaced as it is; shorter ones would match ordinary words
    static let shortestKnownSecret = 8

    private let knownSecrets: [String]

    /// - Parameter knownSecrets: secrets to remove wherever they appear, like the stored tokens
    public init(knownSecrets: [String] = []) {
        var secrets: [String] = []
        for secret in knownSecrets {
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            secrets.append(trimmed)
            // A Jenkins token is stored as base64 of `user:api-token`: the API token alone is secret too.
            if let data = Data(base64Encoded: trimmed), let decoded = String(data: data, encoding: .utf8),
               let colon = decoded.firstIndex(of: ":") {
                secrets.append(decoded)
                secrets.append(String(decoded[decoded.index(after: colon)...]))
            }
        }
        // The longest first, so a secret that contains another goes whole.
        self.knownSecrets = Set(secrets.filter { $0.count >= Self.shortestKnownSecret })
            .sorted { $0.count > $1.count }
    }

    /// Returns the text without its secrets.
    ///
    /// - Parameter text: the text to send
    /// - Returns: the text, each secret replaced with ``mark``
    public func redact(_ text: String) -> String {
        var text = text
        for secret in knownSecrets {
            text = text.replacingOccurrences(of: secret, with: Self.mark)
        }
        for rule in Self.rules {
            let range = NSRange(text.startIndex..., in: text)
            text = rule.expression.stringByReplacingMatches(in: text, range: range, withTemplate: rule.template)
        }
        return text
    }

    private struct Rule: @unchecked Sendable {
        // NSRegularExpression is immutable and documented as thread-safe.
        let expression: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String = SecretRedactor.mark, options: NSRegularExpression.Options = []) {
            // The patterns are fixed: a broken one is a programming error that the tests catch.
            expression = try! NSRegularExpression(pattern: pattern, options: options)
            self.template = template
        }
    }

    private static let markTemplate = NSRegularExpression.escapedTemplate(for: mark)

    private static let rules: [Rule] = [
        // A private key, whole.
        Rule(
            #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)"#,
            "[redacted private key]"),
        // Authorization: Bearer …, Basic …, or a bare value; also `-H "Authorization: …"` and `authorization=…`.
        Rule(
            #"(?i)\b((?:proxy-)?authorization["']?\s*[:=]\s*["']?)(?:(bearer|basic|token|negotiate|digest)\s+)?[^\s"',;]+"#,
            "$1$2 \(markTemplate)"),
        // Cookie and Set-Cookie headers, to the end of the line.
        Rule(#"(?im)\b((?:set-)?cookie["']?\s*:\s*)[^\r\n]+"#, "$1\(markTemplate)"),
        // https://user:password@host
        Rule(#"(?i)\b([a-z][a-z0-9+.\-]*://[^/\s:@]+:)[^/\s@]+@"#, "$1\(markTemplate)@"),
        // A value after a name that says it is secret: `password=…`, `"apiKey": "…"`, `MY_TOKEN: …`. The name may have
        // a short ending (`secretKey`, `token_value`), not a long one, so `PasswordValidatorTest.rejects: …` stays.
        Rule(
            #"(?i)\b([a-z0-9_.\-]*(?:password|passwd|passphrase|secret|token|api[_\-]?key|access[_\-]?key|private[_\-]?key|credentials?)(?:[_\-.]?[a-z0-9]{1,8})?["']?\s*[:=]\s*["']?)([^\s"',;&<>]{4,})"#,
            "$1\(markTemplate)"),
        // A command line option: `--password hunter22`, `-Dsonar.token abc…`.
        Rule(
            #"(?i)(\s--?[a-z0-9.\-]*(?:password|passwd|token|secret|api-?key)[a-z0-9.\-]*\s+["']?)([^\s"']{4,})"#,
            "$1\(markTemplate)"),
        // Tokens by their shapes.
        Rule(#"\bgl[a-z]{1,6}-[A-Za-z0-9_\-]{16,}"#),
        Rule(#"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})"#),
        Rule(#"\bxox[abprse]-[A-Za-z0-9\-]{10,}"#),
        Rule(#"\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{20,}"#),
        Rule(#"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#),
        Rule(#"\bAIza[0-9A-Za-z_\-]{35}"#),
        Rule(#"\bnpm_[A-Za-z0-9]{36}\b"#),
        // Jenkins API tokens: 34 hex digits starting with 11. A commit hash has 40, so it stays.
        Rule(#"\b11[0-9a-f]{32}\b"#),
        Rule(#"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#),
    ]
}
