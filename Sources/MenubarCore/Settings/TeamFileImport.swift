import Foundation

/// A team file from a URL, and what importing it would change (TEAM-02). Nothing here applies anything: the caller
/// shows ``Preview`` and saves only after the user confirmed it, and confirmed every changed server host by name.
///
/// The hosts matter because the tokens follow them: a team file that moved the GitLab URL or the Jenkins job to
/// another host would send the tokens there at the next check. So a host change is never applied silently, the file
/// comes only over https, and the GitLab token goes along only to the GitLab the app already uses, never on a redirect.
public enum TeamFileImport {
    /// the most a team file may weigh; a real one is a few hundred bytes
    public static let maximumSize = 256 * 1024

    /// What importing a team file would change.
    public struct Preview: Hashable, Sendable {
        /// One value that would change.
        public struct Change: Hashable, Sendable {
            public var key: TeamValues.Key
            public var old: String
            public var new: String

            public init(key: TeamValues.Key, old: String, new: String) {
                self.key = key
                self.old = old
                self.new = new
            }
        }

        /// A server whose host would change: the tokens would go to the new one.
        public struct HostChange: Hashable, Sendable {
            /// ``TeamValues/Key/gitLabURL`` or ``TeamValues/Key/jenkinsJobURL``
            public var key: TeamValues.Key
            /// the host now, nil while none is set
            public var old: String?
            /// the host the file sets
            public var new: String

            public init(key: TeamValues.Key, old: String?, new: String) {
                self.key = key
                self.old = old
                self.new = new
            }
        }

        /// the values as the file has them, normalized
        public var incoming: TeamValues
        /// the values that differ, in the order of ``TeamValues/Key``
        public var changes: [Change]
        /// the servers whose host would change from one that is set; each needs the user's explicit confirmation
        public var hostChanges: [HostChange]

        /// Compares the current values with a file's.
        ///
        /// - Parameters:
        ///   - current: the saved team values
        ///   - incoming: the file's values
        public init(current: TeamValues, incoming: TeamValues) {
            let current = current.normalized()
            let incoming = incoming.normalized()
            self.incoming = incoming
            changes = TeamValues.Key.allCases.compactMap { key in
                current[key] == incoming[key] ? nil : Change(key: key, old: current[key], new: incoming[key])
            }
            // A first setup (no host yet) moves no token anywhere; it still shows as an ordinary change.
            hostChanges = [TeamValues.Key.gitLabURL, .jenkinsJobURL].compactMap { key in
                let old = TeamFileImport.host(of: current[key])
                guard let old, let new = TeamFileImport.host(of: incoming[key]), old != new else { return nil }
                return HostChange(key: key, old: old, new: new)
            }
        }

        /// whether applying it needs the user's confirmation of a new host
        public var needsHostConfirmation: Bool {
            !hostChanges.isEmpty
        }

        /// Returns whether the preview may be applied with the hosts the user confirmed.
        ///
        /// - Parameter confirmedHosts: the new hosts the user confirmed, by name
        /// - Returns: true when nothing changes a host, or every new host is confirmed
        public func canApply(confirmedHosts: Set<String>) -> Bool {
            hostChanges.allSatisfy { confirmedHosts.contains($0.new) }
        }
    }

    /// A file that moves a server host can't be imported without the preview and the user's confirmation of the host.
    public struct HostChangeError: Error, Hashable, Sendable, LocalizedError {
        public init() {}

        public var errorDescription: String? {
            "This file changes the GitLab or Jenkins server. Import it in Settings → Team to see what changes first."
        }
    }

    /// Why a team file couldn't be fetched.
    public enum FetchError: Error, Hashable, Sendable, LocalizedError {
        /// not an https URL with a host
        case notHTTPS
        /// the server answered with this status
        case status(Int)
        /// the server redirected; the file isn't followed elsewhere
        case redirected
        /// larger than ``TeamFileImport/maximumSize``
        case tooLarge
        /// no answer, with the reason
        case unreachable(String)
        /// the content isn't a team file
        case teamFile(TeamFileError)

        public var message: String {
            switch self {
            case .notHTTPS: "Enter an https:// link to the team file"
            case .status(401), .status(403): "The server refused the team file: check your GitLab token"
            case .status(404): "There is no team file at that link"
            case .status(let status): "The server answered \(status)"
            case .redirected: "The link redirects elsewhere; use the file's direct link"
            case .tooLarge: "That file is too large to be a team file"
            case .unreachable(let reason): "The team file could not be fetched: \(reason)"
            case .teamFile(let error): error.message
            }
        }

        public var errorDescription: String? { message }
    }

    /// Returns the host of a team value's URL, lowercased, with a port when it has one; nil for no URL.
    ///
    /// - Parameter value: the URL as the team values hold it
    /// - Returns: like `gitlab.example.com` or `ci.example.com:8443`
    public static func host(of value: String) -> String? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
            let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
        else {
            return nil
        }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// Returns the URL to fetch for a link: a GitLab file page (`…/-/blob/<ref>/<path>`) becomes its raw file
    /// (`…/-/raw/<ref>/<path>`); any other https link stays as it is.
    ///
    /// - Parameter link: the link the user pasted
    /// - Returns: the URL, or nil when the link isn't https with a host
    public static func fileURL(for link: URL) -> URL? {
        guard link.scheme?.lowercased() == "https", host(of: link.absoluteString) != nil else { return nil }
        var components = URLComponents(url: link, resolvingAgainstBaseURL: false)
        if let path = components?.path, path.contains("/-/blob/") {
            components?.path = path.replacingOccurrences(of: "/-/blob/", with: "/-/raw/")
        }
        components?.fragment = nil
        return components?.url
    }

    /// Fetches a team file. The GitLab token goes along only when the file is on the GitLab the app uses now, and no
    /// redirect is followed, so the token can't reach another host.
    ///
    /// - Parameters:
    ///   - link: the link, https only
    ///   - gitLabURL: the GitLab URL of the saved team values
    ///   - gitLabToken: the GitLab token, nil for none
    ///   - transport: the transport, usually a `RequestRecorder`
    ///   - timeout: how long the server may take
    /// - Returns: the file's team values
    public static func fetch(
        _ link: URL, gitLabURL: String, gitLabToken: String?, transport: any HTTPTransport,
        timeout: Duration = .seconds(20)
    ) async throws(FetchError) -> TeamValues {
        guard let url = fileURL(for: link) else { throw .notHTTPS }
        var headers: [String: String] = [:]
        if let gitLabToken, !gitLabToken.isEmpty, let ownHost = host(of: gitLabURL),
            gitLabURL.lowercased().hasPrefix("https://"), host(of: url.absoluteString) == ownHost {
            headers["Authorization"] = "Bearer \(gitLabToken)"
        }
        let response: HTTPResponse
        do {
            response = try await transport.send(
                HTTPRequest(url: url, headers: headers, timeout: timeout, followsRedirects: false))
        } catch {
            throw .unreachable(error.localizedDescription)
        }
        if (300..<400).contains(response.status) { throw .redirected }
        guard (200..<300).contains(response.status) else { throw .status(response.status) }
        guard response.body.count <= maximumSize else { throw .tooLarge }
        do {
            return try TeamStore.readTeamFile(data: response.body)
        } catch let error as TeamFileError {
            throw .teamFile(error)
        } catch {
            throw .teamFile(.notATeamFile)
        }
    }

    // MARK: - Share links

    /// Returns the link that opens the import with a preview: `<scheme>://import?url=<https link>`.
    ///
    /// - Parameter fileLink: the team file's https link
    /// - Returns: the link, or nil for a link that isn't https
    public static func shareLink(for fileLink: URL) -> URL? {
        guard fileURL(for: fileLink) != nil else { return nil }
        var components = URLComponents()
        components.scheme = AppIdentity.urlScheme
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "url", value: fileLink.absoluteString)]
        return components.url
    }

    /// Reads the team file's link from an import link of any of the app's schemes. It never applies anything: the
    /// app shows the preview first.
    ///
    /// - Parameter link: like `megamonitor://import?url=https%3A%2F%2F…`
    /// - Returns: the https link, or nil when the link isn't an import link with one
    public static func fileLink(fromShareLink link: URL) -> URL? {
        guard let scheme = link.scheme?.lowercased(), AppIdentity.urlSchemes.contains(scheme),
            link.host(percentEncoded: false)?.lowercased() == "import",
            let value = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "url" })?.value,
            let fileLink = URL(string: value), fileURL(for: fileLink) != nil
        else {
            return nil
        }
        return fileLink
    }
}
