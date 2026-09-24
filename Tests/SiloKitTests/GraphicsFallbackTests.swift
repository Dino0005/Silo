import Foundation
import Testing
@testable import SiloKit

@Suite("GraphicsFallback")
struct GraphicsFallbackTests {

    // Real signatures captured from a live broken launch (GPTK didn't engage → wined3d).
    @Test("flags a D3DMetal dlopen failure as fallback")
    func dlopenFailure() {
        let log = """
        msync: up and running.
        Assertion failed: (GFXTHandle && "Failed to dlopen D3DMetal"), function D3DRMDispatch_Init_block_invoke, file shared.mm, line 1629.
        """
        #expect(GraphicsFallback.classify(log) == .fallback)
    }

    @Test("flags a wined3d feature-level failure as fallback")
    func featureLevelFailure() {
        let log = "fixme:winediag:wined3d_select_feature_level None of the requested D3D feature levels is supported on this GPU with the current shader backend."
        #expect(GraphicsFallback.classify(log) == .fallback)
    }

    @Test("flags wined3d driving d3d1x (the definitive 'GPTK didn't engage' signal)")
    func vulkanRenderer() {
        // Real line from Overcooked! 2 (legacy D3D10 path → wined3d, not GPTK).
        let log = "05c4:err:winediag:wined3d_adapter_create Using the Vulkan renderer for d3d10/11 applications."
        #expect(GraphicsFallback.classify(log) == .fallback)
    }

    @Test("detection is case-insensitive")
    func caseInsensitive() {
        #expect(GraphicsFallback.classify("FAILED TO DLOPEN D3DMETAL") == .fallback)
    }

    @Test("a healthy GPTK launch (or a d3d9/OpenGL game) is NOT flagged")
    func healthyNotFlagged() {
        let log = """
        msync: up and running.
        GPU Apple M4 Pro (Apple)
        OpenGL 2.1 Metal - 90.5
        == application started
        """
        #expect(GraphicsFallback.classify(log) == .unknown)
    }

    @Test("empty / unrelated-noise log is unknown")
    func unknownOnNoise() {
        #expect(GraphicsFallback.classify("") == .unknown)
        #expect(GraphicsFallback.classify("fixme:keyboard:NtUserActivateKeyboardLayout not supported") == .unknown)
    }

    @Test("a DXMT launch that fell back to wined3d is flagged via the backend-agnostic signals")
    func dxmtFallbackDetected() {
        let log = "05c4:err:winediag:wined3d_adapter_create Using the Vulkan renderer for d3d10/11 applications."
        #expect(GraphicsFallback.classify(log, backend: .dxmt) == .fallback)
    }

    @Test("a DXMT launch that created its Metal device is POSITIVELY confirmed as engaged")
    func dxmtEngagedConfirmed() {
        let log = """
        msync: up and running.
        trace:module:load_builtin_dll Loaded L"C:\\\\windows\\\\system32\\\\winemetal.dll"
        DXMT: created Metal device "Apple M4 Pro"
        == application started
        """
        #expect(GraphicsFallback.classify(log, backend: .dxmt) == .engaged)
    }

    @Test("positive engagement WINS over a later stray wined3d line (no false fallback)")
    func engagedBeatsStrayFallbackLine() {
        let log = """
        DXMT: created Metal device "Apple M4 Pro"
        05c4:err:winediag:wined3d_adapter_create Using the Vulkan renderer for d3d10/11 applications.
        """
        #expect(GraphicsFallback.classify(log, backend: .dxmt) == .engaged)
    }

    @Test("GPTK/D3DMetal success is SILENT — no engagement signature, so a healthy GPTK launch is .unknown")
    func gptkHasNoEngagementSignal() {
        // The same DXMT device line means nothing under GPTK (GPTK has no positive signature) → not .engaged.
        #expect(GraphicsFallback.classify(#"DXMT: created Metal device "Apple M4 Pro""#, backend: .gptk) == .unknown)
    }

    @MainActor
    @Test("the monitor releases its kqueue watch after the observation window on a healthy launch (no fd leak)")
    func monitorReleasesWatchAfterWindow() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let log = try tmp.write("game.log", "loading assets… all good, no fallback here\n")
        let monitor = GraphicsFallbackMonitor()
        monitor.observationWindow = .milliseconds(40)
        var fired = false
        monitor.start(url: log, backend: .gptk) { fired = true }
        #expect(monitor.isObserving)               // armed — no fallback signature in the log yet
        // Poll for the autoStop task to release the fd (bounded; avoids a fixed-sleep flake under load).
        for _ in 0..<200 where monitor.isObserving { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!monitor.isObserving)              // auto-released the fd once the window elapsed
        #expect(!fired)                            // a healthy launch never fires the fallback callback
    }

    /// The hang of 2026-09-24: a game logging through wine's trace channels writes continuously, the
    /// kqueue source fires per write, and every event used to enqueue a 64 KB case-insensitive scan on the
    /// main actor. The queue grew without bound and Silo spun at 98 % CPU. The scan now runs off the main
    /// actor, coalesced — so the main actor must stay responsive under a flood of writes.
    @MainActor
    @Test("a chatty log does not saturate the main actor")
    func monitorKeepsTheMainActorResponsiveUnderAFloodOfWrites() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let log = try tmp.write("game.log", "starting…\n")
        let monitor = GraphicsFallbackMonitor()
        monitor.start(url: log, backend: .gptk) { }
        defer { monitor.stop() }

        let writer = Task.detached {
            guard let h = try? FileHandle(forWritingTo: log) else { return }
            h.seekToEndOfFile()
            let line = Data("00e8:trace:loaddll:build_module Loaded builtin module\n".utf8)
            for _ in 0..<3000 { h.write(line) }
            try? h.close()
        }

        // A main-actor round trip during the flood: with the old code this waited on thousands of queued
        // scans. The bound is generous on purpose — the failure it guards against was 17 minutes long.
        let started = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(50))
        let elapsed = ContinuousClock.now - started
        await writer.value
        #expect(elapsed < .seconds(2))
    }

    /// Coalescing must not cost detection: a fallback line written after a burst of noise is still caught.
    @MainActor
    @Test("a fallback written after a burst of noise is still detected")
    func monitorStillCatchesAFallbackAfterNoise() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let log = try tmp.write("game.log", "starting…\n")
        let monitor = GraphicsFallbackMonitor()
        let fired = LockedBox(false)
        monitor.start(url: log, backend: .gptk) { fired.set(true) }
        defer { monitor.stop() }

        let h = try FileHandle(forWritingTo: log)
        h.seekToEndOfFile()
        for _ in 0..<200 { h.write(Data("00e8:trace:loaddll:build_module Loaded builtin\n".utf8)) }
        h.write(Data("""
            05c4:err:winediag:wined3d_adapter_create Using the Vulkan renderer for d3d10/11 applications.
            """.utf8))
        try? h.close()

        for _ in 0..<400 where !fired.value { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fired.value)
    }

    @MainActor
    @Test("a confirmed-engaged DXMT launch tears the watch down without firing a false fallback")
    func monitorStopsOnEngagedWithoutFiring() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let log = try tmp.write("game.log", #"DXMT: created Metal device "Apple M4 Pro"\#n"#)
        let monitor = GraphicsFallbackMonitor()
        var fired = false
        monitor.start(url: log, backend: .dxmt) { fired = true }
        #expect(!monitor.isObserving)              // the immediate tail check saw engagement → torn down
        #expect(!fired)                            // engaged is NOT a fallback — the callback never fires
        // A later stray wined3d line must not resurrect a fallback (the watch is already gone).
        let h = try FileHandle(forWritingTo: log); h.seekToEndOfFile()
        h.write(Data("05c4:err:winediag:wined3d_adapter_create Using the Vulkan renderer for d3d10/11 applications.".utf8))
        try? h.close()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!fired)
    }
}
