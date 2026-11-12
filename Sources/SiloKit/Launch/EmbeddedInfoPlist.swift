import Foundation

/// Rewrites the `Info.plist` a Mach-O executable carries in its `__TEXT,__info_plist` section.
///
/// Wine's loader embeds CrossOver's (`com.codeweavers.CrossOver.wineloader`, no app category). A game process running
/// Silo's game-app loader gets its name and icon from the game app, but macOS's Game Mode follows the executable's
/// own embedded plist: with CrossOver's there, SOULCALIBUR VI ran full screen from macOS Steam with no Game Mode and
/// no Command-Esc (2026-11-12). So the game app's private copy of the loader embeds the game's identity, the games
/// category and `LSSupportsGameMode` — the approach of NotProton's PR #90 Game Mode fixes (sn0wst0rm, 8946aab /
/// d77e605); this is Silo's own code. Pure: bytes in, bytes out; the caller re-signs the file.
public enum EmbeddedInfoPlist {
    public enum Failure: Error, Equatable {
        case notMachO64
        case noSection
        case unreadablePlist
        case doesNotFit(needed: Int, available: Int)
    }

    /// Keys of the original plist that stay (Wine promotes an `LSUIElement` agent to a regular app itself).
    static let keptKeys: Set<String> = [
        "CFBundleAllowMixedLocalizations", "CFBundleDevelopmentRegion", "CFBundleInfoDictionaryVersion",
        "CFBundleShortVersionString", "CFBundleVersion", "LSUIElement",
    ]

    /// The game's entries for the loader's plist.
    public static func gameEntries(identifier: String, name: String) -> [String: Any] {
        ["CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundleExecutable": GameAppLoader.loaderName,
         "CFBundlePackageType": "APPL", "NSPrincipalClass": "WineApplication", "NSHighResolutionCapable": true,
         "LSApplicationCategoryType": GameHostBundle.gamesCategory, "LSSupportsGameMode": true]
    }

    /// Where the section's bytes are and where its 64-bit size field sits.
    struct Section: Equatable {
        let contents: Range<Int>
        let sizeFieldOffset: Int
    }

    /// The `__TEXT,__info_plist` section of a thin 64-bit Mach-O.
    static func section(in data: Data) throws -> Section {
        func u32(_ at: Int) -> UInt32 {
            data.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        func u64(_ at: Int) -> UInt64 {
            data.subdata(in: at..<at + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        }
        func name(_ at: Int) -> String {
            String(decoding: data.subdata(in: at..<at + 16).prefix { $0 != 0 }, as: UTF8.self)
        }
        guard data.count >= 32, u32(0) == 0xfeed_facf else { throw Failure.notMachO64 }
        let commands = Int(u32(16))
        var offset = 32
        for _ in 0..<commands {
            guard offset + 8 <= data.count else { throw Failure.notMachO64 }
            let command = u32(offset), size = Int(u32(offset + 4))
            if command == 0x19, name(offset + 8) == "__TEXT" {   // LC_SEGMENT_64
                let sections = Int(u32(offset + 64))
                for index in 0..<sections {
                    let s = offset + 72 + index * 80
                    guard s + 80 <= data.count else { throw Failure.notMachO64 }
                    if name(s) == "__info_plist" {
                        let start = Int(u32(s + 48)), length = Int(u64(s + 40))
                        guard start + length <= data.count else { throw Failure.notMachO64 }
                        return Section(contents: start..<start + length, sizeFieldOffset: s + 40)
                    }
                }
            }
            guard size > 0 else { throw Failure.notMachO64 }
            offset += size
        }
        throw Failure.noSection
    }

    /// `data` with its embedded plist replaced by the kept keys of the old one plus `entries`, as a binary plist
    /// padded to the section's size (the section never grows; the size field records the new length).
    public static func rewrite(_ data: Data, entries: [String: Any]) throws -> Data {
        let section = try section(in: data)
        var bytes = data.subdata(in: section.contents)
        if !bytes.starts(with: Array("bplist00".utf8)) {
            while let last = bytes.last, last == 0 || last == 0x20 || last == 0x0a { bytes.removeLast() }
        }
        guard let old = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
        else { throw Failure.unreadablePlist }
        let merged = old.filter { keptKeys.contains($0.key) }.merging(entries) { _, new in new }
        let plist = try PropertyListSerialization.data(fromPropertyList: merged, format: .binary, options: 0)
        guard plist.count <= section.contents.count else {
            throw Failure.doesNotFit(needed: plist.count, available: section.contents.count)
        }
        var out = data
        out.replaceSubrange(section.contents,
                            with: plist + Data(repeating: 0, count: section.contents.count - plist.count))
        var size = UInt64(plist.count).littleEndian
        withUnsafeBytes(of: &size) { out.replaceSubrange(section.sizeFieldOffset..<section.sizeFieldOffset + 8, with: $0) }
        return out
    }
}
