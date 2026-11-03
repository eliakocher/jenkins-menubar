import Foundation

// What the stored GitLab token may write, and what a refused write says about it.
//
// GitLab's GraphQL mutations need the `api` scope; a token with `read_api` reads and gets "The resource that you are
// attempting to access does not exist or you don't have permission to perform this action" from every mutation (the
// answer the user's own Mark Done got, 2026-11-03). Every write of the app shares this one place: the scopes are asked
// from `GET /api/v4/personal_access_tokens/self` (docs.gitlab.com/api/personal_access_tokens, checked 2026-11-03: it
// returns the token's `scopes`; what it answers for a token that isn't a personal access token isn't documented, so any
// failure counts as "not known" and blames nothing on the token's scope).

/// Asks GitLab once per token which scopes it has, and keeps the answer in memory: never on disk and never in a log.
public actor WriteAccessProbe {
    /// what the last answer said; ``WriteAccess/unknown`` before the first, and when GitLab didn't say
    public private(set) var access: WriteAccess = .unknown
    private var fingerprint: String?

    public init() {}

    /// Returns what the stored token may do, asking GitLab unless the same token was answered before.
    ///
    /// - Parameter services: where the token and the GitLab URL come from
    /// - Returns: ``WriteAccess/allowed``, ``WriteAccess/readOnly``, or ``WriteAccess/unknown`` without a token, without
    ///   the team values, or when GitLab didn't say (a 404 for a token that isn't a personal access token)
    func check(_ services: GitLabServices) async -> WriteAccess {
        guard let token = try? await services.tokens.token(.gitlab), !token.isEmpty else {
            access = .unknown
            fingerprint = nil
            return .unknown
        }
        let current = GitLabUser.fingerprint(of: token)
        if current == fingerprint, access != .unknown {
            return access
        }
        guard let client = try? await services.session().get().client, let scopes = try? await client.tokenScopes() else {
            // A token GitLab can't describe isn't blamed; a changed token forgets the old answer.
            if current != fingerprint {
                access = .unknown
                fingerprint = current
            }
            return access
        }
        access = WriteAccess(scopes: scopes)
        fingerprint = current
        return access
    }
}

extension WriteAccess {
    /// "Read-only token: Mark Done, Snooze in GitLab, Merge, Re-request Review and comments need the api scope"
    public static let readOnlyNote =
        "Read-only token: Mark Done, Snooze in GitLab, Merge, Re-request Review and comments need the api scope"

    /// Returns the note Settings → Accounts shows under the GitLab account.
    ///
    /// - Parameter access: what the token's scopes say
    /// - Returns: ``readOnlyNote`` for a token known to only read; `nil` for one with `api` and for one that says nothing,
    ///   which isn't blamed
    public static func note(for access: WriteAccess) -> String? {
        access == .readOnly ? readOnlyNote : nil
    }
}

extension GitLabError {
    /// Whether GitLab refused with "does not exist or you don't have permission", which is also what a mutation gets from
    /// a token without the `api` scope.
    var namesPermissionRefusal: Bool {
        guard case .graphQLErrors(let messages) = problem else {
            return false
        }
        return messages.contains {
            $0.localizedCaseInsensitiveContains("does not exist or you don't have permission")
                || $0.localizedCaseInsensitiveContains("does not exist or you don’t have permission")
        }
    }

    /// Whether the refusal can be a token that can't write: the permission refusal, or an answer that names the scope.
    var canBeMissingScope: Bool {
        if case .missingScope = problem {
            return true
        }
        if namesPermissionRefusal {
            return true
        }
        if case .graphQLErrors(let messages) = problem {
            return messages.contains { $0.localizedCaseInsensitiveContains("scope") }
        }
        return false
    }
}

extension GitLabServices {
    /// Whether a refused write is the token's fault: the refusal can be a missing scope, and the token isn't known to
    /// have `api`. GitLab is asked for the scopes then (once per token).
    ///
    /// - Parameter error: the refusal
    /// - Returns: `true` for a token that is read-only, or may be
    func tokenIsToBlame(for error: GitLabError) async -> Bool {
        guard error.canBeMissingScope else {
            return false
        }
        return await writeAccessProbe.check(self) != .allowed
    }

    /// Returns the problem to show for a refused write: ``Problem/readOnlyToken(action:)`` when the token is to blame,
    /// GitLab's own words otherwise.
    ///
    /// - Parameters:
    ///   - error: the refusal
    ///   - action: the write's name, like "Mark Done"
    func problem(for error: GitLabError, action: String) async -> Problem {
        await tokenIsToBlame(for: error) ? .readOnlyToken(action: action) : error.problem
    }
}
