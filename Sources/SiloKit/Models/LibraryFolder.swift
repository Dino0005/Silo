import Foundation

/// A Steam library folder parsed from `libraryfolders.vdf`.
public struct LibraryFolder: Codable, Sendable, Hashable {
    /// Library root (the folder that contains `steamapps/`). For a Windows-style path written by
    /// Steam-under-Wine (e.g. `X:\SteamLibrary`), this is a best-effort/likely-wrong `URL(fileURLWithPath:)`
    /// interpretation — use `rawPath` + `DiscoveryEngine`'s dosdevices resolution for the real host path.
    public let path: URL
    /// The exact string as written in the VDF, before any URL interpretation — the only reliable way to
    /// detect a Windows-style `<letter>:\...` path (backslashes survive verbatim; `URL(fileURLWithPath:)`
    /// does NOT recognize them as separators, so `path` alone can't be un-mangled after the fact).
    public let rawPath: String
    public let label: String?
    /// App IDs parsed from the library's `apps` block. Reserved/not yet consumed: `DiscoveryEngine`
    /// enumerates `steamapps/appmanifest_*.acf` to find installed games instead.
    public let appIDs: [Int]

    public init(path: URL, rawPath: String? = nil, label: String? = nil, appIDs: [Int] = []) {
        self.path = path
        self.rawPath = rawPath ?? path.path
        self.label = label
        self.appIDs = appIDs
    }

    /// The `steamapps` directory inside this library folder.
    public var steamappsURL: URL {
        path.appendingPathComponent("steamapps", isDirectory: true)
    }
}
