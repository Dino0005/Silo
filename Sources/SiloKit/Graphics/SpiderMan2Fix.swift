import CShaderFix
import Foundation

/// Marvel's Spider-Man 2 on M1–M4 Macs: characters in a T-pose, missing heads, a broken symbiote. D3DMetal backs a
/// typed buffer view with a Metal texture buffer, capped at 2^28 elements; past that, reads return 0 and writes are
/// lost, silently. The game reads and writes its 2 GB character mesh pool through typed views of ~536M elements.
///
/// The fix is macprotips' SpiderMan2Fix (public domain): the wide views are created raw, and the four shaders that
/// use them are swapped for copies whose accesses are raw. Silo carries it on its own `amd_ags_x64.dll`
/// (`Proxy/sm2-tpose-fix`), which takes the place of the game's (renamed `amd_ags_x64_real.dll`, every export
/// forwarded to it) — no DLL override needed, so it works under Silo's `d3d12=b` launches from the library and
/// from macOS Steam alike. Plus vkd3d-proton's missing barrier after the game's volumetric fog copy.
///
/// The shaders are game data, so they never ship: `sync` rebuilds them from the user's own `Spider-Man2.exe` with
/// Microsoft's DXC (`DXCTools`, downloaded once), and accepts each only if it hashes to the one macprotips verified.
/// It runs before every launch of the game (`LaunchOrchestrator.launchInBottle`): it installs, refreshes after a
/// game update (new build → shaders rebuilt; a restored original DLL → moved aside again), or, with the option off
/// or under DXMT, puts the game folder back as it was. Verified on device 2026-11-22 (M3 Pro, GPTK, Metal 3).
public struct SpiderMan2Fix: Sendable {
    public static let appID = 2_651_280
    public static let executableName = "Spider-Man2.exe"
    static let agsName = "amd_ags_x64.dll"
    static let realAGSName = "amd_ags_x64_real.dll"
    static let settingsName = "silo-sm2-fix.ini"
    static let logName = "silo-sm2-fix.log"
    /// How Silo recognises its own carrier (`carrier.c`'s `silo_marker`). Keep in sync.
    static let marker = Data("Silo Spider-Man 2 fix carrier".utf8)

    /// One of the game's shaders that read (T-pose) or write (symbiote) the pool through a typed view: the view
    /// that becomes raw, and the hash of the rewritten shader macprotips verified (their `ShaderBuilder.swift`).
    struct PoolShader: Sendable, Equatable {
        let source: UInt64
        let uav: Bool
        let space: Int32
        let register: Int32
        let result: UInt64
        let name: String
        var fileName: String { Self.fileName(source) }
        static func fileName(_ hash: UInt64) -> String { "silo-sm2-pool-\(hex(hash)).dxil" }
    }

    static let shaders: [PoolShader] = [
        PoolShader(source: 0x3d50_acdb_571d_ce22, uav: false, space: 0, register: 1, result: 0x589e_d5a9_fddc_545f,
                   name: "CS_ModelSkinning"),
        PoolShader(source: 0x1490_2794_dd71_34e4, uav: false, space: 0, register: 0, result: 0xee43_4fbf_42f2_4d08,
                   name: "vertex morph"),
        PoolShader(source: 0x9538_ca33_c087_a84c, uav: true, space: 0, register: 1, result: 0xce7b_2801_15b2_aa10,
                   name: "CS_AnimSplineMeshGenIndices"),
        PoolShader(source: 0x125a_4957_ab64_d24d, uav: true, space: 0, register: 1, result: 0xb84c_589e_5ae4_b5c5,
                   name: "CS_AnimSplineMeshGenIndicesFinalize"),
    ]

    /// Silo's carrier, built by `Scripts/build-sm2-fix.sh` into the resources.
    public static func bundledCarrier() -> Data? {
        Bundle.module.url(forResource: "silo-sm2-fix-amd_ags_x64", withExtension: "dll")
            .flatMap { try? Data(contentsOf: $0) }
    }

    /// Rebuilds the fix's shaders from the game's exe: file name → contents.
    public typealias ShaderSource = @Sendable (_ gameExe: URL) async throws -> [String: Data]

    private let carrier: Data?
    private let buildShaders: ShaderSource

    public init(carrier: Data? = SpiderMan2Fix.bundledCarrier(), buildShaders: @escaping ShaderSource) {
        self.carrier = carrier
        self.buildShaders = buildShaders
    }

    /// The real thing: DXC from this repo's `dxc-*` release, then `ShaderBuilder`. `paths` nil = `AppPaths.standard()`,
    /// resolved only when shaders are actually built.
    public init(paths: AppPaths?, runner: ProcessRunning) {
        self.init { exe in
            let tools = try await DXCTools(paths: paths ?? .standard(), runner: runner).ensure()
            return try await ShaderBuilder(tools: tools, runner: runner).build(fromGame: exe)
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// Not Spider-Man 2's exe: nothing done.
        case notThisGame
        case installed
        case upToDate
        case removed
        case nothingToRemove
        /// Couldn't apply it; the folder is as the game shipped it (the game runs without the fix).
        case failed(String)

        /// One line for the launch log; nil when there's nothing worth saying.
        public var logLine: String? {
            switch self {
            case .notThisGame, .nothingToRemove: nil
            case .installed: "Spider-Man 2 fix: installed in the game folder"
            case .upToDate: "Spider-Man 2 fix: in place"
            case .removed: "Spider-Man 2 fix: removed, the game folder is as shipped"
            case .failed(let reason): "Spider-Man 2 fix: NOT applied (\(reason))"
            }
        }
    }

    /// Bring the game folder in line with `enabled`. Never throws: a failure leaves the game's own DLL in place.
    public func sync(gameExe: URL, enabled: Bool) async -> Outcome {
        guard gameExe.lastPathComponent.caseInsensitiveCompare(Self.executableName) == .orderedSame else {
            return .notThisGame
        }
        let dir = gameExe.deletingLastPathComponent()
        guard enabled else { return remove(from: dir) }
        guard let carrier else { return .failed("carrier missing from Silo's resources") }
        guard let build = Self.gameBuild(ofExecutableAt: gameExe) else { return .failed("can't read \(Self.executableName)") }

        var changed = false
        // 1. The shaders, for this exact build. Done first: until the DLLs are swapped the folder is untouched.
        if !shadersCurrent(in: dir, build: build) {
            do {
                let files = try await buildShaders(gameExe)
                for (name, data) in files { try data.write(to: dir.appendingPathComponent(name), options: .atomic) }
                try Data(Self.settings(build: build).utf8)
                    .write(to: dir.appendingPathComponent(Self.settingsName), options: .atomic)
                changed = true
            } catch {
                _ = remove(from: dir)
                return .failed(String(describing: error))
            }
        }

        // 2. The game's own DLL moves aside (a fresh one — first time, or Steam restored it — replaces the old copy).
        let fm = FileManager.default
        let ags = dir.appendingPathComponent(Self.agsName)
        let real = dir.appendingPathComponent(Self.realAGSName)
        do {
            if let current = try? Data(contentsOf: ags), !Self.isCarrier(current) {
                if fm.fileExists(atPath: real.path) { try fm.removeItem(at: real) }
                try fm.moveItem(at: ags, to: real)
                changed = true
            }
            guard fm.fileExists(atPath: real.path) else {
                _ = remove(from: dir)
                return .failed("the game's \(Self.agsName) is missing")
            }
            // 3. The carrier in its place.
            if (try? Data(contentsOf: ags)) != carrier {
                try carrier.write(to: ags, options: .atomic)
                changed = true
            }
        } catch {
            _ = remove(from: dir)
            return .failed(String(describing: error))
        }
        return changed ? .installed : .upToDate
    }

    /// The game folder as the game shipped it: its own DLL back, Silo's files gone.
    func remove(from dir: URL) -> Outcome {
        let fm = FileManager.default
        let ags = dir.appendingPathComponent(Self.agsName)
        let real = dir.appendingPathComponent(Self.realAGSName)
        var changed = false
        var problem: String?
        let ours = (try? Data(contentsOf: ags)).map(Self.isCarrier)
        do {
            if fm.fileExists(atPath: real.path) {
                if ours != false {
                    // Our carrier (or nothing) in front: the original goes back.
                    if ours == true { try fm.removeItem(at: ags) }
                    try fm.moveItem(at: real, to: ags)
                } else {
                    // Steam already put a fresh original back: the old copy is stale.
                    try fm.removeItem(at: real)
                }
                changed = true
            } else if ours == true {
                problem = "the game's \(Self.agsName) is missing: verify the game's files in Steam"
            }
        } catch {
            problem = String(describing: error)
        }
        let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in files where name == Self.settingsName || name == Self.logName
            || (name.hasPrefix("silo-sm2-pool-") && name.hasSuffix(".dxil")) {
            if (try? fm.removeItem(at: dir.appendingPathComponent(name))) != nil { changed = true }
        }
        if let problem { return .failed(problem) }
        return changed ? .removed : .nothingToRemove
    }

    private func shadersCurrent(in dir: URL, build: String) -> Bool {
        guard let text = try? String(contentsOf: dir.appendingPathComponent(Self.settingsName), encoding: .utf8),
              Self.settingsBuild(text) == build else { return false }
        return Self.shaders.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.fileName).path)
        }
    }

    // MARK: - Pure pieces

    static func isCarrier(_ data: Data) -> Bool { data.range(of: marker) != nil }

    /// The game build the carrier checks: PE timestamp and SizeOfImage, `%08x-%08x` (`carrier.c`'s `game_build`).
    static func gameBuild(peHeader data: Data) -> String? {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> UInt32? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        guard bytes.count >= 0x40, bytes[0] == 0x4d, bytes[1] == 0x5a, let pe = u32(0x3c).map(Int.init),
              u32(pe) == 0x0000_4550,                        // "PE\0\0"
              let stamp = u32(pe + 8), let image = u32(pe + 24 + 56) else { return nil }
        return hex32(stamp) + "-" + hex32(image)
    }

    static func gameBuild(ofExecutableAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4096)).flatMap { gameBuild(peHeader: $0) }
    }

    /// `silo-sm2-fix.ini`, as `carrier.c`'s `read_settings` reads it.
    static func settings(build: String) -> String {
        """
        # Silo's Spider-Man 2 fix (macprotips' SpiderMan2Fix). Written by Silo; removed when the fix is off.
        game_build = \(build)
        shaders = \(shaders.map { hex($0.source) }.joined(separator: " "))
        fog_barrier = 1

        """
    }

    static func settingsBuild(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("game_build") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            return line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

private func hex(_ value: UInt64) -> String {
    let digits = String(value, radix: 16)
    return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
}

private func hex32(_ value: UInt32) -> String {
    let digits = String(value, radix: 16)
    return String(repeating: "0", count: max(0, 8 - digits.count)) + digits
}

/// Microsoft's DirectXShaderCompiler tools (dxc, dxa, dxv) for the Spider-Man 2 fix, from this repo's release
/// `dxc-<first 8 hex of Versions.dxcCommit>` (built by build-dxc.yml), installed once under `Runtimes/`.
public struct DXCTools: Sendable {
    let paths: AppPaths
    let runner: ProcessRunning
    let repo: String
    let commit: String

    public init(paths: AppPaths, runner: ProcessRunning, repo: String = Versions.githubRepo,
                commit: String = Versions.dxcCommit) {
        self.paths = paths
        self.runner = runner
        self.repo = repo
        self.commit = commit
    }

    var tag: String { "dxc-" + commit.prefix(8) }
    var installDir: URL { paths.runtimesDir.appendingPathComponent(tag, isDirectory: true) }
    /// The archive holds one `dxc/` folder: `bin/{dxc,dxa,dxv}`, `lib/libdxcompiler.dylib`, `COMMIT`, `licenses/`.
    var binDir: URL { installDir.appendingPathComponent("dxc/bin", isDirectory: true) }
    var downloadURL: URL { URL(string: "https://github.com/\(repo)/releases/download/\(tag)/dxc.tar.xz")! }

    var isInstalled: Bool {
        let fm = FileManager.default
        let commitFile = installDir.appendingPathComponent("dxc/COMMIT")
        return ["dxc", "dxa", "dxv"].allSatisfy { fm.isExecutableFile(atPath: binDir.appendingPathComponent($0).path) }
            && (try? String(contentsOf: commitFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == commit
    }

    /// The tools' folder, downloading them first if needed (digest mandatory, like every runtime from this repo).
    public func ensure() async throws -> URL {
        if isInstalled { return binDir }
        try await RuntimeManager(paths: paths, runner: runner).install(name: tag, from: downloadURL, requireDigest: true)
        guard isInstalled else { throw ShaderBuilder.Failure.toolsMissing }
        return binDir
    }
}

/// Rebuilds the fix's shaders from the game's exe: find each original by hash, disassemble (`dxc -dumpbin`),
/// rewrite its typed pool access into raw access (macprotips' `CShaderFix`), reassemble (`dxa`), validate and sign
/// (`dxv`), and keep the result only if it hashes to the shader macprotips verified in the game.
public struct ShaderBuilder: Sendable {
    let tools: URL
    let runner: ProcessRunning

    public init(tools: URL, runner: ProcessRunning) {
        self.tools = tools
        self.runner = runner
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case toolsMissing
        case cantReadGame
        /// The game's exe doesn't hold this shader: a game update changed it, the fix doesn't cover this build.
        case shaderNotFound(String)
        case toolFailed(String, String)
        case rewriteFailed(String, String)
        case unexpectedResult(String)

        public var description: String {
            switch self {
            case .toolsMissing: "the shader tools couldn't be downloaded"
            case .cantReadGame: "can't read \(SpiderMan2Fix.executableName)"
            case .shaderNotFound(let name): "this game version isn't supported yet (\(name) not found)"
            case .toolFailed(let tool, let output): "\(tool) failed: \(output.suffix(300))"
            case .rewriteFailed(let name, let reason): "rewriting \(name) failed: \(reason)"
            case .unexpectedResult(let name): "the rebuilt \(name) isn't the verified one"
            }
        }
    }

    public func build(fromGame exe: URL) async throws -> [String: Data] {
        guard let data = try? Data(contentsOf: exe, options: .alwaysMapped) else { throw Failure.cantReadGame }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("silo-sm2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var files: [String: Data] = [:]
        for shader in SpiderMan2Fix.shaders {
            guard let original = Self.container(shader.source, in: data) else { throw Failure.shaderNotFound(shader.name) }
            let result = try await rewrite(original, shader: shader, work: work)
            guard Self.hash(result) == shader.result else { throw Failure.unexpectedResult(shader.name) }
            files[shader.fileName] = result
        }
        return files
    }

    private func rewrite(_ container: Data, shader: SpiderMan2Fix.PoolShader, work: URL) async throws -> Data {
        let original = work.appendingPathComponent("original.dxil")
        let listing = work.appendingPathComponent("original.ll")
        let edited = work.appendingPathComponent("edited.ll")
        let assembled = work.appendingPathComponent("assembled.dxil")
        let signed = work.appendingPathComponent("signed.dxil")
        try container.write(to: original)
        try await tool("dxc", ["-dumpbin", original.path, "-Fc", listing.path])
        guard let text = try? String(contentsOf: listing, encoding: .utf8) else {
            throw Failure.rewriteFailed(shader.name, "no disassembly")
        }
        var message = [CChar](repeating: 0, count: 256)
        let size = message.count
        let rewritten = shader.uav
            ? sf_typed_to_raw_uav(text, shader.space, shader.register, nil, nil, nil, &message, size)
            : sf_typed_to_raw(text, shader.space, shader.register, nil, nil, &message, size)
        guard let rewritten else {
            throw Failure.rewriteFailed(shader.name, String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                                                            as: UTF8.self))
        }
        defer { free(rewritten) }
        guard let named = sf_name_values(rewritten) else { throw Failure.rewriteFailed(shader.name, "out of memory") }
        defer { free(named) }
        try String(cString: named).write(to: edited, atomically: true, encoding: .utf8)
        try await tool("dxa", ["-o", assembled.path, edited.path])
        try await tool("dxv", [assembled.path, "-o", signed.path])
        return try Data(contentsOf: signed)
    }

    private func tool(_ name: String, _ arguments: [String]) async throws {
        let result = try await runner.run(executable: tools.appendingPathComponent(name), arguments: arguments,
                                          environment: [:], currentDirectory: nil)
        guard result.succeeded else { throw Failure.toolFailed(name, result.stderrString + result.stdoutString) }
    }

    /// 64-bit FNV-1 of a DXBC container, the hash the carrier and vkd3d-proton use.
    static func hash(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { sf_shader_hash($0.baseAddress, $0.count) }
    }

    /// The DXBC container with this hash inside `data` (the game's exe).
    static func container(_ hash: UInt64, in data: Data) -> Data? {
        data.withUnsafeBytes { raw -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var offset = 0, size = 0
            guard sf_find_container(base, raw.count, hash, &offset, &size) != 0 else { return nil }
            return Data(bytes: base + offset, count: size)
        }
    }
}
