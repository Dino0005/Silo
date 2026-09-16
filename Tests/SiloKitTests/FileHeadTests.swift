import Foundation
import Testing
@testable import SiloKit

/// `URL.headString` — the bounded, lenient read of what a file says at the top (a launch log's header).
@Suite("Bounded head read")
struct FileHeadTests {

    @Test("reads no further than maxBytes, however long the file is")
    func stopsAtTheBound() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let log = try tmp.write("big.log", "HEADER\n" + String(repeating: "x", count: 200_000))
        let head = log.headString(maxBytes: 7)
        #expect(head == "HEADER\n")
    }

    @Test("a byte that isn't UTF-8 costs that byte, not the whole read")
    func decodesLeniently() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let file = tmp.url.appendingPathComponent("mixed.log")
        var bytes = Data("ok\n".utf8)
        bytes.append(0xE8)                       // "è" as CP1252 — not valid UTF-8 on its own
        bytes.append(contentsOf: Data("\nstill here\n".utf8))
        try bytes.write(to: file)
        let head = file.headString()
        #expect(head.hasPrefix("ok\n"))
        #expect(head.hasSuffix("still here\n"))
    }

    @Test("a file that isn't there reads as empty, not a failure")
    func missingFileIsEmpty() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(tmp.url.appendingPathComponent("absent.log").headString().isEmpty)
    }
}
