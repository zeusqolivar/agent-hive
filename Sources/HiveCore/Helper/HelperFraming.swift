import Foundation

/// The wire between the Windows shell and `hive-core`: one JSON object per line, in both directions.
///
/// A pipe rather than a local port, so nothing else on the PC can reach the API; that keeps the promise the
/// README makes for the Mac app ("no server and no open port"). Bodies are base64, because a response body is
/// bytes and could be any content type.
public enum HelperFraming {
    /// The Mac handler's limit, refused here with 413 so the two answer the same way.
    public static let maxBody = 1_000_000

    /// One request from the shell. `id` is echoed back; it is nil only when the shell sent nothing usable.
    public struct Request: Sendable, Equatable {
        public var id: Int?
        public var method: String
        public var path: String
        public var body: Data?

        public init(id: Int?, method: String, path: String, body: Data?) {
            self.id = id
            self.method = method
            self.path = path
            self.body = body
        }
    }

    /// One answer from the helper.
    public struct Answer: Sendable, Equatable {
        public var id: Int?
        public var status: Int
        public var contentType: String
        public var body: Data

        public init(id: Int?, status: Int, contentType: String, body: Data) {
            self.id = id
            self.status = status
            self.contentType = contentType
            self.body = body
        }
    }

    /// Why a line could not be read. Both cases become an answer, and the helper keeps running.
    public enum Failure: Error, Equatable {
        case malformed
        case bodyTooLarge

        public var status: Int { self == .bodyTooLarge ? 413 : 400 }

        public var message: String {
            switch self {
            case .malformed: return "Each line must be one JSON object with a path."
            case .bodyTooLarge: return "The request body is over 1 MB."
            }
        }
    }

    /// Reads one line. A blank line is malformed, not ignored: it means the shell is out of step.
    public static func decode(_ line: Data) -> Result<Request, Failure> {
        let trimmed = line.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D })
        guard !trimmed.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: Data(trimmed))) as? [String: Any] else {
            return .failure(.malformed)
        }
        guard let path = object["path"] as? String, !path.isEmpty else { return .failure(.malformed) }
        let method = (object["method"] as? String) ?? "GET"
        let id = (object["id"] as? NSNumber)?.intValue

        var body: Data?
        if let encoded = object["body"] as? String, !encoded.isEmpty {
            guard let decoded = Data(base64Encoded: encoded) else { return .failure(.malformed) }
            guard decoded.count <= maxBody else { return .failure(.bodyTooLarge) }
            body = decoded
        }
        return .success(Request(id: id, method: method.uppercased(), path: path, body: body))
    }

    /// One answer, ready to write: a single line, newline-terminated, UTF-8.
    public static func encode(_ answer: Answer) -> Data {
        var object: [String: Any] = [
            "status": answer.status,
            "contentType": answer.contentType,
            "body": answer.body.base64EncodedString(),
        ]
        if let id = answer.id { object["id"] = id }
        let json = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"status":500,"contentType":"text/plain","body":""}"#.utf8)
        return json + Data("\n".utf8)
    }

    /// The answer for a line that could not be read.
    public static func refusal(for failure: Failure, id: Int? = nil) -> Answer {
        Answer(id: id, status: failure.status, contentType: "application/json; charset=utf-8",
               body: Data(#"{"error":"\#(failure.message)"}"#.utf8))
    }
}

/// Splits what arrives on a pipe into whole lines. The shell may write half a line, or several at once; only a
/// complete line is a request.
public struct LineReader {
    private var buffer = Data()

    public init() {}

    /// Adds a chunk and returns every line it completed, without their terminators.
    public mutating func feed(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }  // a CRLF writer is fine too
            lines.append(Data(line))
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        return lines
    }

    /// Whatever is left when the pipe closes: a last line that never got its newline.
    public mutating func flush() -> Data? {
        guard !buffer.isEmpty else { return nil }
        var line = buffer
        if line.last == 0x0D { line = line.dropLast() }
        buffer = Data()
        return line.isEmpty ? nil : line
    }
}
