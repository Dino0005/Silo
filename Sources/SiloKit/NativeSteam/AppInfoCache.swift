import CryptoKit
import Foundation

/// Steam's local app-metadata cache, `<Steam>/appcache/appinfo.vdf`: one binary KeyValues tree per app (name,
/// supported OSes, depots, launch entries, Steam Cloud rules), as the client last received it from Steam's
/// servers. It is a cache — deleting it makes Steam download it again — which is also why an edit has to be
/// written the way Steam expects or the client throws the entry away and re-downloads it.
///
/// Layout (little-endian), versions 28 (`0x07564428`) and 29 (`0x07564429`):
/// - `u32 magic`, `u32 universe`; v29 then has `i64 offset` of a string table at the end of the file.
/// - entries until an app id of 0: `u32 appid`, `u32 size`, then `size` bytes = a 60-byte header
///   (`u32 state`, `u32 lastUpdated`, `u64 picsToken`, `20 sha1`, `u32 changeNumber`, `20 sha1 of the
///   KeyValues blob`) followed by the binary KeyValues of the app.
/// - v29 only: `u32 count` + `count` NUL-terminated key names; keys inside the blobs are `u32` indexes into it.
///
/// Edits are surgical: only the replaced app is re-encoded, every other entry is copied byte for byte, and
/// the v29 string table is only ever appended to, so existing indexes stay valid.
/// (Format as documented by SteamDB; the same approach as mont127/Neutron's `appinfo_write.py`, Apache-2.0.)
public struct AppInfoCache: Sendable {
    public static let magicV28: UInt32 = 0x0756_4428
    public static let magicV29: UInt32 = 0x0756_4429
    static let headerSize = 60
    /// Byte offsets inside an app's 60-byte header.
    static let changeNumberOffset = 36
    static let blobSHA1Offset = 40

    public enum Failure: Error, Equatable {
        case unsupportedMagic(UInt32)
        case truncated(at: Int)
        case badTag(UInt8, at: Int)
        case badKeyIndex(UInt32)
        case appNotFound(UInt32)
    }

    /// One app's entry: its raw 60-byte header and its KeyValues tree (the `appinfo` map and anything beside it).
    public struct App: Sendable, Equatable {
        public var appID: UInt32
        public var header: Data
        public var root: [BinaryKVEntry]

        public init(appID: UInt32, header: Data, root: [BinaryKVEntry]) {
            self.appID = appID
            self.header = header
            self.root = root
        }

        /// The `appinfo` map, where `common`, `config`, `depots`, `ufs` live.
        public var info: [BinaryKVEntry] {
            get { root.map("appinfo") ?? root }
            set {
                if root.index(of: "appinfo") != nil { root.set("appinfo", .map(newValue)) } else { root = newValue }
            }
        }

        public var changeNumber: UInt32 {
            get { header.readUInt32(at: AppInfoCache.changeNumberOffset) }
            set { header.writeUInt32(newValue, at: AppInfoCache.changeNumberOffset) }
        }
    }

    public let magic: UInt32
    public let universe: UInt32
    private(set) var strings: [String]
    private let data: Data
    /// (app id, byte range of the whole entry including the id and size words).
    private let slots: [(appID: UInt32, range: Range<Int>)]

    public var appIDs: [UInt32] { slots.map(\.appID) }

    public init(data: Data) throws {
        self.data = data
        var r = Reader(data: data, pos: 0)
        magic = try r.u32()
        universe = try r.u32()
        guard magic == Self.magicV28 || magic == Self.magicV29 else { throw Failure.unsupportedMagic(magic) }
        var endOfApps = data.count
        var strings: [String] = []
        if magic == Self.magicV29 {
            let tableOffset = Int(try r.i64())
            var t = Reader(data: data, pos: tableOffset)
            let count = try t.u32()
            strings.reserveCapacity(Int(count))
            for _ in 0..<count { strings.append(try t.cString()) }
            endOfApps = tableOffset
        }
        self.strings = strings
        var slots: [(UInt32, Range<Int>)] = []
        while r.pos + 8 <= endOfApps {
            let start = r.pos
            let appID = try r.u32()
            if appID == 0 { break }
            let size = Int(try r.u32())
            let end = r.pos + size
            guard end <= endOfApps else { throw Failure.truncated(at: start) }
            slots.append((appID, start..<end))
            r.pos = end
        }
        self.slots = slots
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    /// The parsed entry for `appID`, or nil when the cache has no such app.
    public func app(_ appID: UInt32) throws -> App? {
        guard let slot = slots.first(where: { $0.appID == appID }) else { return nil }
        let headerStart = slot.range.lowerBound + 8
        let header = data.subdata(in: headerStart..<(headerStart + Self.headerSize))
        var r = Reader(data: data, pos: headerStart + Self.headerSize)
        let root = try readMap(&r)
        return App(appID: appID, header: header, root: root)
    }

    /// The whole file with `app` written in place of its old entry. The header's blob SHA-1 is recomputed: a
    /// stale one makes Steam decide the entry is corrupt and re-download it, which drops the edit.
    public func replacing(_ app: App) throws -> Data {
        guard let index = slots.firstIndex(where: { $0.appID == app.appID }) else {
            throw Failure.appNotFound(app.appID)
        }
        var copy = self
        let blob = copy.encodeMap(app.root)
        var header = app.header
        header.replaceSubrange(Self.blobSHA1Offset..<(Self.blobSHA1Offset + 20),
                               with: Data(Insecure.SHA1.hash(data: blob)))
        var entry = Data()
        entry.appendUInt32(app.appID)
        entry.appendUInt32(UInt32(header.count + blob.count))
        entry.append(header)
        entry.append(blob)

        var body = Data()
        for (i, slot) in slots.enumerated() {
            body.append(i == index ? entry : data.subdata(in: slot.range))
        }
        body.appendUInt32(0)
        return copy.assemble(body: body)
    }

    /// A brand-new cache file holding `apps` — used by tests to build fixtures, never against Steam's own file.
    public static func encode(magic: UInt32 = magicV29, universe: UInt32 = 1, apps: [App]) -> Data {
        var cache = AppInfoCache(magic: magic, universe: universe)
        var body = Data()
        for app in apps {
            let blob = cache.encodeMap(app.root)
            var header = app.header
            header.replaceSubrange(blobSHA1Offset..<(blobSHA1Offset + 20), with: Data(Insecure.SHA1.hash(data: blob)))
            body.appendUInt32(app.appID)
            body.appendUInt32(UInt32(header.count + blob.count))
            body.append(header)
            body.append(blob)
        }
        body.appendUInt32(0)
        return cache.assemble(body: body)
    }

    private init(magic: UInt32, universe: UInt32) {
        self.magic = magic
        self.universe = universe
        strings = []
        data = Data()
        slots = []
    }

    private func assemble(body: Data) -> Data {
        var out = Data()
        out.appendUInt32(magic)
        out.appendUInt32(universe)
        if magic == Self.magicV29 {
            out.appendInt64(Int64(out.count + 8 + body.count))
            out.append(body)
            out.appendUInt32(UInt32(strings.count))
            for s in strings {
                out.append(Data(s.utf8))
                out.append(0)
            }
        } else {
            out.append(body)
        }
        return out
    }

    // MARK: - KeyValues

    private func readKey(_ r: inout Reader) throws -> String {
        guard magic == Self.magicV29 else { return try r.cString() }
        let index = try r.u32()
        guard Int(index) < strings.count else { throw Failure.badKeyIndex(index) }
        return strings[Int(index)]
    }

    private func readMap(_ r: inout Reader) throws -> [BinaryKVEntry] {
        var entries: [BinaryKVEntry] = []
        while true {
            let at = r.pos
            let tag = try r.u8()
            if tag == 0x08 { return entries }
            let key = try readKey(&r)
            let value: BinaryKV
            switch tag {
            case 0x00: value = .map(try readMap(&r))
            case 0x01: value = .string(try r.cString())
            case 0x02: value = .int32(Int32(bitPattern: try r.u32()))
            case 0x03: value = .float(Float(bitPattern: try r.u32()))
            case 0x04: value = .pointer(Int32(bitPattern: try r.u32()))
            case 0x05: value = .wideString(try r.cString())
            case 0x06: value = .color(Int32(bitPattern: try r.u32()))
            case 0x07: value = .uint64(try r.u64())
            case 0x0A: value = .int64(try r.i64())
            default: throw Failure.badTag(tag, at: at)
            }
            entries.append(BinaryKVEntry(key, value))
        }
    }

    private mutating func keyIndex(_ key: String) -> UInt32 {
        if let i = strings.firstIndex(of: key) { return UInt32(i) }
        strings.append(key)
        return UInt32(strings.count - 1)
    }

    private mutating func encodeMap(_ entries: [BinaryKVEntry]) -> Data {
        var out = Data()
        encode(entries, into: &out)
        out.append(0x08)
        return out
    }

    private mutating func encode(_ entries: [BinaryKVEntry], into out: inout Data) {
        for entry in entries {
            out.append(entry.value.tag)
            if magic == Self.magicV29 {
                out.appendUInt32(keyIndex(entry.key))
            } else {
                out.append(Data(entry.key.utf8))
                out.append(0)
            }
            switch entry.value {
            case .map(let children):
                encode(children, into: &out)
                out.append(0x08)
            case .string(let s), .wideString(let s):
                out.append(Data(s.utf8))
                out.append(0)
            case .int32(let v), .pointer(let v), .color(let v):
                out.appendUInt32(UInt32(bitPattern: v))
            case .float(let v):
                out.appendUInt32(v.bitPattern)
            case .uint64(let v):
                out.appendUInt64(v)
            case .int64(let v):
                out.appendInt64(v)
            }
        }
    }
}

/// A bounds-checked little-endian cursor over the cache bytes.
private struct Reader {
    let data: Data
    var pos: Int

    mutating func take(_ n: Int) throws -> Data {
        guard pos >= 0, pos + n <= data.count else { throw AppInfoCache.Failure.truncated(at: pos) }
        defer { pos += n }
        return data.subdata(in: (data.startIndex + pos)..<(data.startIndex + pos + n))
    }

    mutating func u8() throws -> UInt8 { try take(1)[0] }
    mutating func u32() throws -> UInt32 { try take(4).readUInt32(at: 0) }
    mutating func u64() throws -> UInt64 {
        let d = try take(8)
        return UInt64(d.readUInt32(at: 0)) | (UInt64(d.readUInt32(at: 4)) << 32)
    }
    mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }

    mutating func cString() throws -> String {
        guard let end = data[(data.startIndex + pos)...].firstIndex(of: 0) else {
            throw AppInfoCache.Failure.truncated(at: pos)
        }
        let s = String(decoding: data[(data.startIndex + pos)..<end], as: UTF8.self)
        pos = end - data.startIndex + 1
        return s
    }
}

extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16
            | UInt32(self[base + 3]) << 24
    }

    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        let base = startIndex + offset
        for i in 0..<4 { self[base + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(i))) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        for i in 0..<4 { append(UInt8(truncatingIfNeeded: value >> (8 * UInt32(i)))) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        for i in 0..<8 { append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(i)))) }
    }

    mutating func appendInt64(_ value: Int64) { appendUInt64(UInt64(bitPattern: value)) }
}
