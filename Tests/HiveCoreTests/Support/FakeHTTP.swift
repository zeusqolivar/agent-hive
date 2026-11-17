import Foundation
@testable import HiveCore

/// An HTTP client that answers from canned responses and records every request. An unknown URL fails as if
/// the network were down.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    struct Request { var url: URL; var headers: [String: String] }

    private let lock = NSLock()
    private var answers: [String: (status: Int, body: Data)] = [:]
    private var recorded: [Request] = []

    var requests: [Request] { lock.withLock { recorded } }

    func answer(_ url: String, status: Int, body: String) { answer(url, status: status, data: Data(body.utf8)) }

    func answer(_ url: String, status: Int, data: Data) {
        lock.withLock { answers[url] = (status, data) }
    }

    func get(_ url: URL, headers: [String: String]) async throws -> (status: Int, body: Data) {
        let a = lock.withLock { () -> (status: Int, body: Data)? in
            recorded.append(Request(url: url, headers: headers))
            return answers[url.absoluteString]
        }
        guard let a else { throw URLError(.cannotConnectToHost) }
        return a
    }
}
