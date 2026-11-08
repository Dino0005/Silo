import Foundation

/// One value of Valve's *binary* KeyValues, the format of Steam's `appcache/appinfo.vdf`.
///
/// Unlike the text KeyValues of `.acf`/`.vdf` files (`KeyValuesParser`), every value carries a type tag, and a
/// map keeps its children in file order. Order matters: Steam's own launch-entry and depot maps are written in
/// order, and a rewrite that reshuffled them would change which entry Steam picks first.
public indirect enum BinaryKV: Sendable, Equatable {
    case map([BinaryKVEntry])
    case string(String)
    case int32(Int32)
    case float(Float)
    case pointer(Int32)
    case wideString(String)
    case color(Int32)
    case uint64(UInt64)
    case int64(Int64)

    /// The tag byte Valve writes before a value of this kind.
    var tag: UInt8 {
        switch self {
        case .map: 0x00
        case .string: 0x01
        case .int32: 0x02
        case .float: 0x03
        case .pointer: 0x04
        case .wideString: 0x05
        case .color: 0x06
        case .uint64: 0x07
        case .int64: 0x0A
        }
    }

    /// The text of a string-like value (Steam stores most "numbers" in appinfo as strings, e.g. `osarch`).
    public var stringValue: String? {
        switch self {
        case .string(let s), .wideString(let s): s
        case .int32(let v), .pointer(let v), .color(let v): String(v)
        case .uint64(let v): String(v)
        case .int64(let v): String(v)
        case .float(let v): String(v)
        case .map: nil
        }
    }

    public var children: [BinaryKVEntry]? {
        if case .map(let entries) = self { return entries }
        return nil
    }
}

/// A key and its value inside a binary KeyValues map.
public struct BinaryKVEntry: Sendable, Equatable {
    public var key: String
    public var value: BinaryKV

    public init(_ key: String, _ value: BinaryKV) {
        self.key = key
        self.value = value
    }
}

/// Lookup and in-place edits on a map's children. Keys are matched case-insensitively, as Steam does.
extension Array where Element == BinaryKVEntry {
    public func index(of key: String) -> Int? {
        firstIndex { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }

    public subscript(key: String) -> BinaryKV? {
        index(of: key).map { self[$0].value }
    }

    /// The child map under `key`, or nil when absent or not a map.
    public func map(_ key: String) -> [BinaryKVEntry]? {
        self[key]?.children
    }

    public func string(_ key: String) -> String? {
        self[key]?.stringValue
    }

    /// Sets `key` to a string, replacing an existing entry in place (keeping its position) or appending one.
    public mutating func setString(_ key: String, _ value: String) {
        set(key, .string(value))
    }

    public mutating func set(_ key: String, _ value: BinaryKV) {
        if let i = index(of: key) { self[i].value = value } else { append(BinaryKVEntry(key, value)) }
    }

    public mutating func remove(_ key: String) {
        if let i = index(of: key) { remove(at: i) }
    }

    /// Edits the child map under `key` in place, creating an empty one first when `create` is set. Returns
    /// false (and runs nothing) when the key is missing and `create` is off, or holds a non-map value.
    @discardableResult
    public mutating func editMap(_ key: String, create: Bool = false,
                                 _ body: (inout [BinaryKVEntry]) -> Void) -> Bool {
        if index(of: key) == nil {
            guard create else { return false }
            append(BinaryKVEntry(key, .map([])))
        }
        guard let i = index(of: key), case .map(var children) = self[i].value else { return false }
        body(&children)
        self[i].value = .map(children)
        return true
    }
}
