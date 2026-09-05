import Foundation
@testable import SiloKit

/// Create the files a running `wineserver` leaves for `prefix`, so `WineServerProbe.isLive(prefix:)`
/// reports it live. Creates the prefix dir if needed (so it can be `stat`'d for its dev+inode). Returns a
/// cleanup closure the caller runs to release the lock and remove the dir.
///
/// The `lock` is genuinely HELD, not just created: the probe asks who holds it precisely so that leftover
/// files don't read as a live bottle.
@discardableResult
func makeWineServerSocket(for prefix: URL) throws -> () -> Void {
    let held = try holdWineServerLock(for: prefix)
    return held.release
}

/// The pieces of a fake live server, so a test can drop the LOCK while leaving the files on disk — exactly
/// the state a `kill -9`'d wineserver leaves behind, and the case the probe has to reject.
struct HeldWineServer {
    let dir: URL?
    /// The process holding the lock. It HAS to be a separate one: `F_GETLK` never reports the caller's own
    /// locks — POSIX lets a process re-lock what it already holds — so a lock taken here would read as free
    /// from a probe running in the same test process. It's also the real shape: wineserver doesn't run
    /// inside Silo either.
    let holder: Process?
    /// Closing this is what tells the holder to exit; see `holdWineServerLock`.
    let leash: FileHandle?

    /// Drop the lock without touching the files on disk.
    func unlock() {
        try? leash?.close()
        guard let holder, holder.isRunning else { return }
        holder.terminate()
        holder.waitUntilExit()
    }

    /// Drop the lock and remove the directory.
    func release() { unlock(); if let dir { try? FileManager.default.removeItem(at: dir) } }
}

@discardableResult
func holdWineServerLock(for prefix: URL) throws -> HeldWineServer {
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    guard let dirName = WineServerProbe.serverDirName(for: prefix) else {
        return HeldWineServer(dir: nil, holder: nil, leash: nil)
    }
    let root = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp", isDirectory: true)
    let dir = root.appendingPathComponent(".wine-\(getuid())", isDirectory: true)
        .appendingPathComponent(dirName, isDirectory: true)
    // Sharing this directory with CrossOver is safe for two separate reasons, both measured: its own files
    // are named `bottle-…` while the sweep only ever looks at `server-…`, and the sweep removes only names
    // matching a Silo prefix — the filter added after it was found clearing six CrossOver bottles. A full
    // test run leaves the directory's CrossOver contents exactly as it found them.
    //
    // 0700, the way Wine creates it. Without the attribute this lands at the default 0755, and since the
    // path is the machine's REAL TMPDIR the directory is shared with CrossOver — which refuses to take its
    // lock on a world-readable one and then dies: "The configuration file must be locked first". Running
    // the tests once was enough to break it until the directory was deleted by hand.
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: dir.appendingPathComponent("socket").path, contents: Data())
    let lockPath = dir.appendingPathComponent("lock").path

    // Python's `fcntl.lockf`, NOT Perl's `flock` (a BSD lock — a different lock space `F_GETLK` cannot see;
    // measured: the probe read "free" with a Perl holder running) and NOT `flock(1)` (absent on macOS).
    // `lockf` is the same POSIX fcntl lock wineserver takes. The child announces readiness, then holds
    // until terminated — and the kernel drops the lock when it dies, exactly as it does for a killed
    // wineserver.
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    holder.arguments = ["-c", """
        import fcntl, sys
        handle = open(sys.argv[1], 'a+')
        fcntl.lockf(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print('locked', flush=True)
        sys.stdin.read()
        """, lockPath]
    let ready = Pipe()
    let leash = Pipe()
    holder.standardOutput = ready
    // Not a timed sleep: the child blocks on stdin and exits the moment this pipe closes — when the test
    // releases it, when it forgets to, and even if the test process is killed. `swift test` waits for its
    // descendants, so a sleeping holder left behind by one missed cleanup hung the whole suite.
    holder.standardInput = leash
    try holder.run()

    // Wait for the child to confirm the lock is held — probing before that would race it.
    var confirmation = Data()
    while confirmation.isEmpty, holder.isRunning {
        confirmation = ready.fileHandleForReading.availableData
    }
    guard !confirmation.isEmpty else {
        throw NSError(domain: "WineServerFixture", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "the lock holder exited before taking the lock on \(lockPath)"])
    }
    return HeldWineServer(dir: dir, holder: holder, leash: leash.fileHandleForWriting)
}

/// Remove the fake `wineserver` socket for `prefix` (the inverse of `makeWineServerSocket`) — so a test can
/// flip a bottle from live back to dead.
func removeWineServerSocket(for prefix: URL) {
    guard let dirName = WineServerProbe.serverDirName(for: prefix) else { return }
    let root = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp", isDirectory: true)
    let dir = root.appendingPathComponent(".wine-\(getuid())", isDirectory: true)
        .appendingPathComponent(dirName, isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
}
