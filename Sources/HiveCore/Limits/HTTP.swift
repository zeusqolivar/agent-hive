import Foundation
#if canImport(FoundationNetworking)
// On Windows, URLSession and friends live in a separate module.
import FoundationNetworking
#endif

/// The one way usage services reach the network, so tests can answer with fixtures.
public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (status: Int, body: Data)
}

/// URLSession with a 15-second timeout, no cookies, no cache, and no redirects: a redirect answers with its
/// own 3xx status instead of carrying the key to another address.
public final class URLSessionHTTP: HTTPClient {
    static var configuration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 15
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 1
        return c
    }

    private let session = URLSession(configuration: URLSessionHTTP.configuration, delegate: NoRedirects(),
                                     delegateQueue: nil)

    public init() {}

    public func get(_ url: URL, headers: [String: String]) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
