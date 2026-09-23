import Foundation

/// Builds the registry import that decides **which executables go to Silo's alt-loader host**.
///
/// Wine's `send_to_cx_loader` (`dlls/ntdll/unix/process.c`) gates the hand-over on two keys under
/// `HKCU\Software\CrossOver`:
/// - **`UseAltLoader`** — a whitelist. If the key **exists**, an exe is handed over only when the key
///   holds a value *named after that exe*; anything not listed is skipped.
/// - `SuppressAltLoader` — a blacklist, consulted only when `UseAltLoader` is absent.
///
/// The whitelist is the one Silo needs, because `CX_ALT_LOADER_SOCKET` is consumed by the **first**
/// process creation in a prefix — on a cold bottle that is `wineboot.exe --init`, which would otherwise
/// adopt the host and leave the game to start normally (measured 2026-09-23).
///
/// ⚠️ **Disabling means DELETING the key, never emptying it.** An existing-but-empty `UseAltLoader`
/// matches nothing, so it would silently exclude *every* executable from the alt loader — the exact
/// state a half-finished `reg delete` left behind during the experiments. `disableReg` therefore emits
/// a key deletion.
///
/// Imported with one `wine regedit /S`, the same way `SteamBottle.applyWineDefaults` applies the
/// default DLL overrides — cheaper and far more reliable than `reg add`, which hung repeatedly in
/// testing. Pure: the builders are strings, the caller does the I/O.
public enum AltLoaderWhitelist: Sendable {
    /// Full registry path of the whitelist key, as `send_to_cx_loader` looks it up.
    static let keyPath = #"HKEY_CURRENT_USER\Software\CrossOver\UseAltLoader"#

    /// The name Wine matches an executable by: the last path component with its extension removed.
    ///
    /// Mirrors the sender's own logic, which takes `argv[1]`, cuts at the last `/` **and** the last `\`
    /// (the value it sees is a Windows path like `C:\windows\system32\notepad.exe`), then truncates at
    /// the final `.`. A name with no extension is used whole; a name that is only an extension
    /// (`.hidden`) keeps its leading dot, because that is what the sender's `strrchr` would leave.
    public static func exeName(for path: String) -> String {
        var name = path
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if let backslash = name.lastIndex(of: #"\"#) { name = String(name[name.index(after: backslash)...]) }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[name.startIndex..<dot])
    }

    /// Registry text that whitelists exactly `exeNames` — nothing else will be handed to the host.
    ///
    /// The key is emitted even when `exeNames` is empty, which is a deliberate footgun guard: callers
    /// wanting "no alt loader at all" must use `disableReg`, not an empty list (see the type's note).
    public static func enableReg(exeNames: [String]) -> String {
        var reg = "REGEDIT4\r\n\r\n[\(keyPath)]\r\n"
        for name in exeNames { reg += "\"\(escaped(name))\"=\"1\"\r\n" }
        return reg
    }

    /// Registry text that removes the whitelist key entirely, restoring Wine's default behaviour
    /// (every exe eligible, subject only to `SuppressAltLoader`). The leading `-` on the key is
    /// REGEDIT4's key-deletion form.
    public static func disableReg() -> String {
        "REGEDIT4\r\n\r\n[-\(keyPath)]\r\n"
    }

    /// Quote a value name for REGEDIT4: backslashes and quotes are doubled/escaped. Exe base names
    /// shouldn't contain either, but a hand-edited game entry might.
    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: #"\"#, with: #"\\"#)
         .replacingOccurrences(of: "\"", with: #"\""#)
    }
}
