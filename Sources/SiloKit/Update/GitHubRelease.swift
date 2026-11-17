import Foundation

/// A GitHub release as returned by `/repos/{owner}/{repo}/releases/latest`.
/// Decode with `keyDecodingStrategy = .convertFromSnakeCase`.
public struct GitHubRelease: Codable, Sendable, Equatable {
    public let tagName: String
    public let name: String?
    public let assets: [Asset]
    /// The release's notes as written on GitHub (Markdown — for Silo's own releases, `RELEASE_NOTES.md`).
    public let body: String?
    /// The release's page on GitHub.
    public let htmlUrl: URL?

    public init(tagName: String, name: String?, assets: [Asset], body: String? = nil, htmlUrl: URL? = nil) {
        self.tagName = tagName
        self.name = name
        self.assets = assets
        self.body = body
        self.htmlUrl = htmlUrl
    }

    public struct Asset: Codable, Sendable, Equatable {
        public let name: String
        public let browserDownloadUrl: URL
    }

    /// Version with any leading `v` stripped (e.g. `v0.2.0` → `0.2.0`).
    public var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }
}

extension URLRequest {
    /// A GitHub API request with the headers GitHub requires (it returns 403 with no User-Agent).
    static func github(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Silo/\(Silo.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }
}
