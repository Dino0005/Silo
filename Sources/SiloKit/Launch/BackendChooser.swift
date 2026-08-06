import Foundation

/// Resolves a per-game `GraphicsChoice` to a concrete `GraphicsBackend` at launch — the "Automatic" brain.
///
/// **Policy (decided 2026-07-13): GPTK is treated as always the faster/preferred backend, so it is used
/// unless it structurally can't (32-bit — Apple ships no i386 D3DMetal → DXMT) or is proven not to run the
/// game.** DXMT is strictly a fallback, never a co-equal choice — there is no per-title "which is faster"
/// ranking because GPTK is defined to win. GPTK titles that fail to engage are learned reactively
/// (`GameLibraryViewModel` records a `learnedBackend` hint — kept separate from the user's `.auto` so it stays
/// re-evaluable and re-probes GPTK after a runtime upgrade), which `choose` consults for the next launch, so
/// Automatic adapts without a per-title database. DirectX 9 / OpenGL titles need neither backend — they run on
/// Wine's own wined3d/GL under whatever runtime is active.
///
/// `choose` is pure (takes the pre-computed bitness + learned hint); `dxmtMightHelp` reads the import table.
enum BackendChooser {
    /// DLLs whose translation DXMT provides (so a GPTK failure on one of these is worth retrying on DXMT).
    private static let dxmtTranslatable: Set<String> = ["d3d11.dll", "d3d10.dll", "d3d10core.dll", "d3d10_1.dll"]
    /// DLLs no current backend but GPTK can translate — DXMT is pointless for these.
    private static let d3d12: Set<String> = ["d3d12.dll", "d3d12core.dll"]

    /// The backend a launch should use for `choice`, given the game's bitness (from `WindowsExecutable`) and
    /// any reactively-`learned` hint. A user's explicit pin always wins; a 32-bit Automatic game must use
    /// DXMT (GPTK is 64-bit-only), which moots the hint; a 64-bit Automatic game uses the learned hint if one
    /// exists, else GPTK. Pure — the caller supplies bitness and a runtime-validated hint (a stale hint from a
    /// superseded GPTK runtime is passed as `nil` so GPTK is re-probed).
    static func choose(_ choice: GraphicsChoice, is32Bit: Bool, learned: GraphicsBackend? = nil) -> GraphicsBackend {
        if let explicit = choice.explicitBackend { return explicit }   // a user pin always wins
        if is32Bit { return .dxmt }                                    // GPTK is 64-bit-only; learned is moot
        return learned ?? .gptk                                        // 64-bit Automatic: learned hint, else GPTK
    }

    /// Whether reactively switching a GPTK-failed game to DXMT could plausibly help. Fail-**open**: an exe
    /// with no static Direct3D imports (dynamic `LoadLibrary` loaders — common) returns `true` so DXMT still
    /// gets a chance. Only suppresses the switch when we're CONFIDENT DXMT can't help: the exe imports D3D12
    /// (DXMT has no d3d12), or imports D3D9 and NONE of D3D10/11 (DXMT has no d3d9).
    /// Whether `exe` needs Direct3D 12 — the question the DXMT mismatch note asks.
    ///
    /// Two checks, because neither sees what the other does: the import table catches a game that LINKS
    /// d3d12, and the layout check catches Unreal, which loads its RHI with `LoadLibrary` and so appears
    /// in no import table at all.
    static func needsD3D12(exe: URL) -> Bool {
        !dxmtMightHelp(exe: exe) || isUnrealD3D12(exe: exe)
    }

    /// Whether `exe` belongs to an Unreal Engine game shipping the D3D12 renderer — recognised by the
    /// install LAYOUT, because the import table can't see it.
    ///
    /// Unreal loads its RHI modules with `LoadLibrary` at runtime, so `d3d12.dll` appears in neither the
    /// import table nor the delay-import table: `dxmtMightHelp` reads both and still comes back "maybe".
    /// Measured on Fatal Fury, whose log shows dxgi at line 31 and d3d12 only at 219 — long after start-up,
    /// which is what a dynamic load looks like.
    ///
    /// Searched from the DIRECTORIES, never from the executable's name. Both shapes ship in practice: the
    /// shipping binary itself (`<Game>/Binaries/Win64/<Game>-Win64-Shipping.exe`) and a small launcher at
    /// the install root beside `Engine/`. `TEKKEN 8.exe` is the latter, and keying on the `-Win64-Shipping`
    /// suffix missed it while catching every other Unreal title in the same library.
    ///
    /// Deliberately NOT folded into `dxmtMightHelp`: that decides ROUTING for Automatic, where an unknown
    /// profile means "let DXMT try". This only feeds a warning shown for an EXPLICIT DXMT pick, so a false
    /// positive costs a note the user can ignore — not a launch sent down the wrong path.
    static func isUnrealD3D12(exe: URL) -> Bool {
        let fm = FileManager.default
        // Walk up from the executable looking for the engine tree. Four levels covers both shapes: a
        // launcher sits one level below the install root, a shipping binary three.
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<4 {
            // `Engine/Binaries` — NOT `Engine/Binaries/Win64`. Both exist in the wild: Fatal Fury has the
            // Win64 folder, Tekken 8 has only `Engine/Binaries/ThirdParty` and keeps its engine binaries
            // under the project folder instead. Requiring Win64 missed Tekken entirely while catching
            // every other Unreal title in the same library.
            //
            // The engine tree alone is the signal. When UE ships the D3D12 renderer as its own DLL it sits
            // beside these binaries; when it doesn't, the renderer is linked into the shipping binary (the
            // monolithic case, e.g. Fatal Fury) — and UE 4.25+ defaults to D3D12 on Windows either way.
            if fm.fileExists(atPath: dir.appendingPathComponent("Engine/Binaries").path) { return true }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }   // reached the filesystem root
            dir = parent
        }
        return false
    }

    static func dxmtMightHelp(exe: URL) -> Bool {
        let imports = WindowsExecutable.importedDLLs(of: exe)
        if imports.isEmpty { return true }                                  // unknown → let DXMT try
        if !imports.isDisjoint(with: d3d12) { return false }                // needs D3D12 → GPTK only
        let usesD3D1x = !imports.isDisjoint(with: dxmtTranslatable)
        if imports.contains("d3d9.dll"), !usesD3D1x { return false }        // D3D9-only → DXMT can't
        return true
    }
}
