import Foundation
import Testing
@testable import SiloKit

@Suite("SteamReadiness")
struct SteamReadinessTests {

    /// A representative Wine `user.reg` snippet: Steam's ActiveProcess section with a live pid.
    private let withPid = """
    [Software\\Valve\\Steam\\ActiveProcess] 1700000000
    #time=1d000000
    "pid"=dword:0000007b
    "SteamClientDll"="C:\\Program Files (x86)\\Steam\\steamclient.dll"
    "Universe"="Public"
    """

    @Test("ready when ActiveProcess carries a non-zero pid")
    func ready() { #expect(SteamReadiness.hasActivePid(withPid)) }

    @Test("not ready when the pid is zero (Steam registered but not running)")
    func zeroPid() {
        #expect(!SteamReadiness.hasActivePid(
            withPid.replacingOccurrences(of: "dword:0000007b", with: "dword:00000000")))
    }

    @Test("not ready with no ActiveProcess section at all")
    func noSection() {
        #expect(!SteamReadiness.hasActivePid("[Software\\Valve\\Steam] 1\n\"x\"=\"y\"\n"))
    }

    @Test("a pid under a DIFFERENT section is not counted (section-scoped)")
    func wrongSection() {
        #expect(!SteamReadiness.hasActivePid("[Software\\Other\\App] 1\n\"pid\"=dword:0000007b\n"))
    }

    @Test("isReady reads the prefix's user.reg")
    func isReadyFromPrefix() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = try tmp.makeDir("bottle")
        #expect(!SteamReadiness.isReady(prefix: prefix))            // no user.reg yet → not ready
        try withPid.write(to: SteamReadiness.userReg(prefix: prefix), atomically: true, encoding: .utf8)
        #expect(SteamReadiness.isReady(prefix: prefix))             // pid present → ready
    }

    // MARK: - Signed in (pid + ActiveUser) — what a game needs

    /// The section as the dev box's bottle had it once Steam had finished starting (2026-09-28).
    private let signedIn = """
    [Software\\Valve\\Steam\\ActiveProcess] 1790620320
    "ActiveUser"=dword:6ff8a909
    "pid"=dword:000000e0
    "SteamClientDll"="C:\\Program Files (x86)\\Steam\\steamclient.dll"
    """

    @Test("signed in when ActiveProcess carries both a pid and an ActiveUser")
    func signedInBoth() { #expect(SteamReadiness.hasSignedInUser(signedIn)) }

    @Test("a pid without ActiveUser is running but NOT signed in — the window a game must not launch into")
    func pidWithoutUser() {
        let starting = signedIn.replacingOccurrences(of: "dword:6ff8a909", with: "dword:00000000")
        #expect(SteamReadiness.hasActivePid(starting))       // the client process is up…
        #expect(!SteamReadiness.hasSignedInUser(starting))   // …but sign-in hasn't finished
        // No ActiveUser line at all reads the same as zero.
        #expect(!SteamReadiness.hasSignedInUser(withPid))
    }

    @Test("an ActiveUser left over without a pid is not signed in")
    func userWithoutPid() {
        #expect(!SteamReadiness.hasSignedInUser(
            signedIn.replacingOccurrences(of: "dword:000000e0", with: "dword:00000000")))
    }

    @Test("an ActiveUser under a different section is not counted")
    func userInWrongSection() {
        let text = withPid + "\n[Software\\Valve\\Steam] 1\n\"ActiveUser\"=dword:6ff8a909\n"
        #expect(!SteamReadiness.hasSignedInUser(text))
    }

    @Test("isSignedIn reads the prefix's user.reg")
    func isSignedInFromPrefix() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = try tmp.makeDir("bottle")
        #expect(!SteamReadiness.isSignedIn(prefix: prefix))         // no user.reg yet
        try withPid.write(to: SteamReadiness.userReg(prefix: prefix), atomically: true, encoding: .utf8)
        #expect(!SteamReadiness.isSignedIn(prefix: prefix))         // pid only
        try signedIn.write(to: SteamReadiness.userReg(prefix: prefix), atomically: true, encoding: .utf8)
        #expect(SteamReadiness.isSignedIn(prefix: prefix))          // pid + ActiveUser
    }
}
