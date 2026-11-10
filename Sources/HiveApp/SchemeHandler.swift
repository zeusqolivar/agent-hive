import Foundation
import HiveCore
import WebKit

/// Serves `hive://app/...` to the web view: the bundled pages and the same `/api/...` paths server.py
/// answers, through `HiveAPI`. Nothing listens on a port.
@MainActor
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "hive"
    static let home = URL(string: "hive://app/")!

    private let api: HiveAPI
    private var live = Set<ObjectIdentifier>()

    init(api: HiveAPI) {
        self.api = api
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        live.insert(id)
        let request = task.request
        guard let url = request.url, url.host == "app" else {
            task.didFailWithError(URLError(.badURL))
            live.remove(id)
            return
        }
        let method = request.httpMethod ?? "GET"
        var path = url.path(percentEncoded: true)
        if path.isEmpty { path = "/" }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let api = self.api
        // The API call runs off the main actor; only answering the task happens here.
        Task { @MainActor in
            let response = await api.handle(method: method, path: path, body: body)
            guard self.live.remove(id) != nil else { return }
            let headers = ["Content-Type": response.contentType, "Cache-Control": "no-store",
                           "Content-Length": String(response.body.count)]
            let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
            task.didReceive(http)
            task.didReceive(response.body)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }

    nonisolated static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if data.count > 1_000_000 { break }
        }
        return data
    }
}
