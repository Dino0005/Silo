import Foundation

extension URL {
    /// Read the last `maxBytes` of this file as UTF-8 (so a huge log doesn't blow memory); "" if missing.
    /// `nonisolated`-safe — callable off any actor (e.g. from a file-watch handler).
    func tailString(maxBytes: Int = 64 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: self) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// Read the first `maxBytes` of this file as UTF-8; "" if missing. The counterpart of `tailString`, for
    /// what a file says at the TOP — a launch log's header, which Silo writes before the process output.
    ///
    /// Decoding is lossy, and that is the point: a game writes its own messages in a Windows codepage, so a
    /// byte that isn't valid UTF-8 shows up in the output sooner or later. Anything strict returns nothing
    /// at all for the whole file because of it, header included.
    /// `nonisolated`-safe — callable off any actor.
    func headString(maxBytes: Int = 64 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: self) else { return "" }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: maxBytes) else { return "" }
        return String(decoding: head, as: UTF8.self)
    }
}
