import Foundation

/// UNCHARTED: Legacy of Thieves Collection crashed every time it was quit from its own menu: it releases some of its
/// D3D12 resources one time too many, and its cleanup loop then touches a texture that is already gone (measured
/// 2026-11-22 with Silo's d3d12-relog experiment: last Release from `u4.exe+0x18b25d5`, the crash 375 ms later in
/// the loop at `u4.exe+0x15fa756`; ~180 such extra Releases happen while playing too). D3DMetal's own reference
/// counting matches Windows (probed), so the extra Release is the game's.
///
/// The fix is Silo's own `d3d12.dll` proxy (`Proxy/uncharted-quit-fix`) in the game's folder: it keeps each resource
/// alive for two seconds after the game's last Release and makes a Release in that window harmless. The launch adds
/// `d3d12=n,b` and `SILO_REAL_D3D12` for it (`LaunchOrchestrator.makePlan`), and the proxy reaches D3DMetal through
/// the copy `GraphicsLinker` keeps beside it in the runtime (`realModuleName`).
///
/// `sync` runs before every launch of the game (`LaunchOrchestrator.launchInBottle`): with the option on and GPTK it
/// puts the proxy in place (or refreshes it after a Silo update); off, or under DXMT, it takes it away. It never
/// touches a `d3d12.dll` that isn't Silo's. Verified on device 2026-11-22 (GPTK 4 beta 3, macOS Steam): no crash at
/// the menu quit.
public struct UnchartedFix: Sendable {
    public static let appID = 1_659_420
    /// The collection's executables: Uncharted 4 and The Lost Legacy, and the `-l` builds each hands over to on a
    /// Mac. All four live in the one game folder the proxy goes into.
    static let executableNames: Set<String> = ["u4.exe", "u4-l.exe", "tll.exe", "tll-l.exe"]
    static let proxyName = "d3d12.dll"
    /// The name D3DMetal's `d3d12.dll` is also kept under in the runtime, for the proxy (it can't load a second
    /// module named `d3d12.dll`).
    public static let realModuleName = "d3dm_d3d12.dll"
    /// How Silo recognises its own proxy (`proxy.c`'s `silo_marker`). Keep in sync.
    static let marker = Data("Silo Uncharted fix d3d12 proxy".utf8)

    /// Silo's proxy, built by `Scripts/build-uncharted-fix.sh` into the resources.
    public static func bundledProxy() -> Data? {
        Bundle.module.url(forResource: "silo-uncharted-fix-d3d12", withExtension: "dll")
            .flatMap { try? Data(contentsOf: $0) }
    }

    private let proxy: Data?

    public init(proxy: Data? = UnchartedFix.bundledProxy()) {
        self.proxy = proxy
    }

    public enum Outcome: Sendable, Equatable {
        /// Not one of the collection's exes: nothing done.
        case notThisGame
        case installed
        case upToDate
        case removed
        case nothingToRemove
        /// Couldn't apply it; the game runs without the fix.
        case failed(String)

        /// Whether the proxy is in the game folder for this launch (the launch then loads it).
        public var isActive: Bool { self == .installed || self == .upToDate }

        /// One line for the launch log; nil when there's nothing worth saying.
        public var logLine: String? {
            switch self {
            case .notThisGame, .nothingToRemove: nil
            case .installed: "Uncharted fix: installed in the game folder"
            case .upToDate: "Uncharted fix: in place"
            case .removed: "Uncharted fix: removed, the game folder is as shipped"
            case .failed(let reason): "Uncharted fix: NOT applied (\(reason))"
            }
        }
    }

    static func isThisGame(_ gameExe: URL) -> Bool {
        executableNames.contains(gameExe.lastPathComponent.lowercased())
    }

    static func isProxy(_ data: Data) -> Bool { data.range(of: marker) != nil }

    /// Bring the game folder in line with `enabled`. Never throws, and never touches a foreign `d3d12.dll`.
    public func sync(gameExe: URL, enabled: Bool) -> Outcome {
        guard Self.isThisGame(gameExe) else { return .notThisGame }
        let fm = FileManager.default
        let dst = gameExe.deletingLastPathComponent().appendingPathComponent(Self.proxyName)
        let existing = fm.contents(atPath: dst.path)
        let ours = existing.map(Self.isProxy) ?? false

        guard enabled else {
            guard ours else { return .nothingToRemove }
            do {
                try fm.removeItem(at: dst)
                return .removed
            } catch {
                return .failed(String(describing: error))
            }
        }
        guard let proxy else { return .failed("proxy missing from Silo's resources") }
        if existing != nil, !ours { return .failed("the game folder has a \(Self.proxyName) that isn't Silo's") }
        if existing == proxy { return .upToDate }
        do {
            try proxy.write(to: dst, options: .atomic)
            return .installed
        } catch {
            return .failed(String(describing: error))
        }
    }
}
