import Testing
@testable import SiloKit

@Suite("The guard restarts Steam (Silo) after a client update")
struct SteamUpdateRestartTests {
    /// `bootstrap_log.txt` around the 2026-11-14 08:36 update, as Steam wrote it (localized lines in Italian).
    let updateSession = """
    [2026-11-14 08:36:33] Startup - updater built Nov  6 2026 12:39:18
    [2026-11-14 08:36:33] Startup - Steam Client launched with: '/Users/x/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx'
    [2026-11-14 08:36:33] uninstalled manifest found in /Users/x/package/steam_client_signed-2_osx (1).
    [2026-11-14 08:36:33] Found pending update
    [2026-11-14 08:36:33] Installazione dell'aggiornamento...
    [2026-11-14 08:36:38] Pulitura...
    [2026-11-14 08:36:38] Aggiornamento completato, avvio di Steam...
    [2026-11-14 08:36:38] Shutdown

    """

    @Test("A session that installed a pending update and shut down is reported once, by its first start line")
    func updateThenShutdown() {
        let earlier = """
        [2026-11-13 08:11:08] Startup - updater built Oct 14 2026 13:47:20
        [2026-11-13 08:11:08] Verification complete
        [2026-11-13 08:11:57] Shutdown

        """
        #expect(NativeSteamGuard.sessionEndedForUpdate(bootstrapLog: earlier + updateSession)
                == "[2026-11-14 08:36:33] Startup - updater built Nov  6 2026 12:39:18")
    }

    @Test("A normal quit, a session still running and the session after the restart are not an update")
    func otherSessionEnds() {
        let normalQuit = """
        [2026-11-13 08:11:08] Startup - updater built Oct 14 2026 13:47:20
        [2026-11-13 08:11:08] Startup - Steam Client launched with: 'steam_osx'
        [2026-11-13 08:11:10] Download skipped: /steam_client_osx version 1794424036, installed version 1794424036
        [2026-11-13 08:11:57] Shutdown
        """
        #expect(NativeSteamGuard.sessionEndedForUpdate(bootstrapLog: normalQuit) == nil)
        let stillRunning = updateSession.replacingOccurrences(of: "[2026-11-14 08:36:38] Shutdown\n", with: "")
        #expect(NativeSteamGuard.sessionEndedForUpdate(bootstrapLog: stillRunning) == nil)
        let restarted = updateSession + """
        [2026-11-14 08:36:55] Startup - updater built Nov 12 2026 18:00:58
        [2026-11-14 08:36:55] Startup - Steam Client launched with: 'steam_osx'
        [2026-11-14 08:36:55] Verification complete
        """
        #expect(NativeSteamGuard.sessionEndedForUpdate(bootstrapLog: restarted) == nil)
        #expect(NativeSteamGuard.sessionEndedForUpdate(bootstrapLog: "") == nil)
    }
}
