import Foundation

/// A minimal Chrome DevTools client for macOS Steam's CEF debugging port: lists its pages and evaluates
/// JavaScript in one of them (`Runtime.evaluate`). Used to put `SteamLibraryFilters` into the library.
/// Only ever talks to 127.0.0.1.
public struct SteamCEFClient: Sendable {
    public struct Target: Sendable, Equatable, Decodable {
        public let title: String
        public let webSocketDebuggerUrl: String?
    }

    public enum Failure: Error, Equatable {
        case noTarget(String)
        case badReply
        case exception(String)
        case timedOut
    }

    public let port: Int
    private let session: URLSession

    public init(port: Int = 8080, session: URLSession = .shared) {
        self.port = port
        self.session = session
    }

    /// The pages Steam exposes (`/json`); throws when the port isn't open (Steam closed or started without it).
    public func targets() async throws -> [Target] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/json")!)
        request.timeoutInterval = 3
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode([Target].self, from: data)
    }

    /// Evaluates `expression` in the page titled `title` (awaiting a promise result) and returns its value as a
    /// string, or nil for a non-string result.
    public func evaluate(_ expression: String, in title: String = "SharedJSContext",
                         timeout: Duration = .seconds(10)) async throws -> String? {
        // A page that never answers must not stall the guard's loop.
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await evaluateNow(expression, in: title) }
            group.addTask { try await Task.sleep(for: timeout); throw Failure.timedOut }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    private func evaluateNow(_ expression: String, in title: String) async throws -> String? {
        guard let target = try await targets().first(where: { $0.title == title }),
              let ws = target.webSocketDebuggerUrl, let url = URL(string: ws) else { throw Failure.noTarget(title) }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 << 20
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let message = try Self.evaluateMessage(id: 1, expression: expression)
        try await task.send(.string(message))
        while true {
            let reply: Data
            switch try await task.receive() {
            case .string(let text): reply = Data(text.utf8)
            case .data(let data): reply = data
            @unknown default: throw Failure.badReply
            }
            if let reply = try Self.result(of: reply, id: 1) { return reply.value }
        }
    }

    /// The DevTools request.
    static func evaluateMessage(id: Int, expression: String) throws -> String {
        let object: [String: Any] = [
            "id": id, "method": "Runtime.evaluate",
            "params": ["expression": expression, "awaitPromise": true, "returnByValue": true],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    struct Reply: Equatable { let value: String? }

    /// The reply to request `id` (nil for an unrelated message): its string value, or the exception thrown.
    static func result(of reply: Data, id: Int) throws -> Reply? {
        guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else { throw Failure.badReply }
        guard object["id"] as? Int == id else { return nil }
        let result = (object["result"] as? [String: Any])
        if let details = result?["exceptionDetails"] as? [String: Any] {
            let description = ((details["exception"] as? [String: Any])?["description"] as? String)
                ?? (details["text"] as? String) ?? "exception"
            throw Failure.exception(description)
        }
        let value = (result?["result"] as? [String: Any])?["value"]
        return Reply(value: value as? String)
    }
}
