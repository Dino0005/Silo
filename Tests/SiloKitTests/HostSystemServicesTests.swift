import Foundation
import Testing
@testable import SiloKit

/// `HostSystemServices` — which Apple XPC services left in an exited non-Steam host's coalition may be
/// stopped. The `lsappinfo` text is verbatim from the God of War measurement of 2026-10-12 (DXMT run), next
/// to the still-running Steam host and an unrelated app.
struct HostSystemServicesTests {
    private let gow = "com.mikael.silo.host.538C9332-8799-4259-8C93-7F8E43B4CBA7"

    private let lsappinfo = """
    97) "Safari" ASN:0x0-0x1d01d0:
        bundleID="com.apple.Safari"
        pid = 1200 token=[sess=100020 pid=1200] type="Foreground" flavor=3 Version="26.0" fileType="APPL" Arch=ARM64
        coalition: 4000  { 1200 1201 }
    98) "God of War" ASN:0x0-0x2a02a0:
        bundleID="com.mikael.silo.host.538C9332-8799-4259-8C93-7F8E43B4CBA7"
        bundle path="/Users/x/Library/Application Support/Silo/HostApps/538C9332-8799-4259-8C93-7F8E43B4CBA7/God of War.app"
        executable path="/Users/x/Library/Application Support/Silo/HostApps/538C9332-8799-4259-8C93-7F8E43B4CBA7/God of War.app/Contents/MacOS/SiloGameHost"
        pid = 34553 token=[sess=100020 pid=34553 uid:501,501,501 g:20,20 pV:69018] type="Foreground" flavor=3 Version=[ NULL ]  fileType="APPL" creator="????" Arch=x86_64 (exited-with-subordinates)
        coalition: 5310  { 34571 34576 34580 34582 }
        launch time =  101 seconds ago, 2026/10/12 21:37:04 ( 1 minutes, 40.8909 seconds ago )
    99) "AutoFill (God of War)" ASN:0x0-0x2a32a3:
        bundleID="com.apple.SafariPlatformSupport.Helper"
        pid = 34576 token=[sess=100020 pid=34576] type="BackgroundOnly" flavor=2 fileType="XPC!" Arch=ARM64 sandboxed
    100) "Steam" ASN:0x0-0x2ae2ae:
        bundleID="com.mikael.silo.host.steam-client"
        pid = 34900 token=[sess=100020 pid=34900] type="Foreground" flavor=3 Version=[ NULL ]  fileType="APPL" Arch=x86_64
        coalition: 5407  { 34900 34925 34927 34928 }
    """

    private let ps = """
    34571     1 /System/Library/PrivateFrameworks/CascadeSets.framework/Versions/A/XPCServices/SetStoreUpdateService.xpc/Contents/MacOS/SetStoreUpdateService
    34576     1 /System/Library/PrivateFrameworks/SafariPlatformSupport.framework/Versions/A/XPCServices/com.apple.SafariPlatformSupport.Helper.xpc/Contents/MacOS/com.apple.SafariPlatformSupport.Helper
    34580     1 /System/Library/Frameworks/ColorSync.framework/Versions/A/XPCServices/com.apple.ColorSyncXPCAgent.xpc/Contents/MacOS/com.apple.ColorSyncXPCAgent
    34582     1 /System/Library/Frameworks/Metal.framework/Versions/A/XPCServices/MTLCompilerService.xpc/Contents/MacOS/MTLCompilerService
    """

    @Test func parsesTheMeasuredRegistrations() {
        let regs = HostSystemServices.parseRegistrations(lsappinfo)
        #expect(regs.count == 4)
        let gowReg = regs.first { $0.bundleID == gow }
        #expect(gowReg?.hasExited == true)
        #expect(gowReg?.coalition == [34571, 34576, 34580, 34582])
        #expect(regs.first { $0.bundleID == "com.mikael.silo.host.steam-client" }?.hasExited == false)
        // An XPC registration without a coalition line parses with an empty one.
        #expect(regs.first { $0.bundleID == "com.apple.SafariPlatformSupport.Helper" }?.coalition == [])
    }

    @Test func theExitedHostsAppleServicesAreTheTargets() {
        let candidates = HostSystemServices.candidatePIDs(
            in: HostSystemServices.parseRegistrations(lsappinfo), bundleID: gow)
        let targets = HostSystemServices.targets(candidates: candidates, processes: HostSystemServices.parsePS(ps))
        #expect(targets == [34571, 34576, 34580, 34582])
    }

    /// A host still running is a game being played: nothing in its coalition is ever a target.
    @Test func aRunningHostYieldsNothing() {
        let running = lsappinfo.replacingOccurrences(of: " (exited-with-subordinates)", with: "")
        let candidates = HostSystemServices.candidatePIDs(
            in: HostSystemServices.parseRegistrations(running), bundleID: gow)
        #expect(candidates.isEmpty)
    }

    /// Only another host's bundle id matches its own registration — Steam's coalition is never touched
    /// when a non-Steam game ends.
    @Test func onlyTheGivenHostsCoalitionIsConsidered() {
        let candidates = HostSystemServices.candidatePIDs(
            in: HostSystemServices.parseRegistrations(lsappinfo), bundleID: gow)
        #expect(!candidates.contains(34927))
        #expect(!candidates.contains(1201))
    }

    /// Wine processes, the game, non-system binaries and anything not spawned by launchd are never stopped,
    /// even if they were (somehow) in the coalition.
    @Test func nothingButLaunchdSpawnedAppleXPCServices() {
        let processes = HostSystemServices.parsePS("""
        10     1 /Users/x/Silo/Runtimes/wine-cx-26.3.0/bin/wine64
        11     1 /Users/x/Library/Application Support/Silo/HostApps/G/God of War.app/Contents/MacOS/SiloGameHost
        12     1 /Applications/Foo.app/Contents/XPCServices/Bar.xpc/Contents/MacOS/Bar
        13   500 /System/Library/Frameworks/Metal.framework/Versions/A/XPCServices/MTLCompilerService.xpc/Contents/MacOS/MTLCompilerService
        14     1 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
        15     1 /System/Library/Frameworks/Metal.framework/Versions/A/XPCServices/MTLCompilerService.xpc/Contents/MacOS/MTLCompilerService
        """)
        #expect(HostSystemServices.targets(candidates: [10, 11, 12, 13, 14, 15], processes: processes) == [15])
    }

    /// A pid that is no longer in the candidate list is ignored even if `ps` reports it.
    @Test func targetsAreAlwaysASubsetOfTheCandidates() {
        let targets = HostSystemServices.targets(candidates: [34582], processes: HostSystemServices.parsePS(ps))
        #expect(targets == [34582])
    }

    @Test func parsesPathsWithSpaces() {
        let p = HostSystemServices.parsePS("  42     1 /System/Library/A B.xpc/Contents/MacOS/A B\n")
        #expect(p == [.init(pid: 42, ppid: 1, path: "/System/Library/A B.xpc/Contents/MacOS/A B")])
    }

    /// The id the post-exit hook matches on is exactly the one the host's Info.plist declares.
    @Test func bundleIdentifierMatchesTheInfoPlist() {
        let id = "538C9332-8799-4259-8C93-7F8E43B4CBA7"
        #expect(GameHostBundle.bundleIdentifier(forID: id) == gow)
        #expect(GameHostBundle(name: "God of War", id: id).infoPlist().contains("<string>\(gow)</string>"))
    }
}
