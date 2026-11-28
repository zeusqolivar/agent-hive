import Foundation
import Testing
@testable import HiveCore

/// The helper's pipe: one JSON line each way. These tests run on both systems, so the protocol is checked
/// wherever it is built, not only where the shell runs.
@Suite struct HelperFramingTests {
    static func line(_ text: String) -> Data { Data(text.utf8) }

    @Test func aRequestRoundTrips() throws {
        let decoded = try HelperFraming.decode(Self.line(#"{"id": 17, "method": "GET", "path": "/api/board", "body": null}"#)).get()
        #expect(decoded.id == 17)
        #expect(decoded.method == "GET")
        #expect(decoded.path == "/api/board")
        #expect(decoded.body == nil)
        // A method is upper-cased once, so the shell can send either.
        #expect(try HelperFraming.decode(Self.line(#"{"method": "post", "path": "/api/classroom"}"#)).get().method == "POST")
        // GET when the shell leaves it out.
        #expect(try HelperFraming.decode(Self.line(#"{"path": "/api/limits"}"#)).get().method == "GET")
    }

    @Test func aBodyIsBase64() throws {
        let body = Data(#"{"cols": 24}"#.utf8)
        let request = #"{"id": 18, "method": "POST", "path": "/api/classroom", "body": "\#(body.base64EncodedString())"}"#
        let decoded = try HelperFraming.decode(Self.line(request)).get()
        #expect(decoded.body == body)
        // Bodies over 1 MB are refused like the Mac handler refuses them.
        let big = Data(repeating: 0x61, count: HelperFraming.maxBody + 1)
        #expect(HelperFraming.decode(Self.line(#"{"path": "/x", "body": "\#(big.base64EncodedString())"}"#))
            == .failure(.bodyTooLarge))
    }

    @Test func anAnswerIsOneLineWithTheIdCopiedBack() throws {
        let answer = HelperFraming.Answer(id: 17, status: 200, contentType: "application/json; charset=utf-8",
                                          body: Data(#"{"ok": true}"#.utf8))
        let encoded = HelperFraming.encode(answer)
        #expect(encoded.last == 0x0A)
        #expect(encoded.filter { $0 == 0x0A }.count == 1)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["id"] as? Int == 17)
        #expect(object["status"] as? Int == 200)
        #expect(object["contentType"] as? String == "application/json; charset=utf-8")
        #expect((object["body"] as? String).flatMap { Data(base64Encoded: $0) } == Data(#"{"ok": true}"#.utf8))
        // A malformed line's answer has no id, because there was nothing to copy.
        let refused = HelperFraming.refusal(for: .malformed)
        let body = try #require(try JSONSerialization.jsonObject(with: refused.body) as? [String: Any])
        #expect(refused.id == nil)                    // nothing to copy back
        #expect(refused.status == 400)
        #expect(body["error"] != nil)
        #expect(HelperFraming.refusal(for: .bodyTooLarge).status == 413)
    }

    @Test func badLinesAreRefusedAndNotCrashing() {
        let bad = [
            "",
            "   ",
            "not json",
            #"{"path": ""}"#,
            #"{"method": "GET"}"#,
            #"{"path": "/api/board", "body": "not base64!"}"#,
            "[1, 2, 3]",
        ]
        for line in bad {
            #expect(HelperFraming.decode(Self.line(line)) == .failure(.malformed), "\(line)")
        }
    }

    @Test func linesAreSplitAsTheyArrive() throws {
        var reader = LineReader()
        #expect(reader.feed(Data(#"{"id": 1"#.utf8)).isEmpty)         // half a line
        let rest = reader.feed(Data(##", "path": "/a"}"##.utf8) + Data("\n".utf8))
        #expect(rest.count == 1)
        #expect(String(decoding: rest[0], as: UTF8.self) == #"{"id": 1, "path": "/a"}"#)
        // Two lines in one chunk, and a CRLF writer is fine.
        let both = reader.feed(Data("one\r\ntwo\n".utf8))
        #expect(both.map { String(decoding: $0, as: UTF8.self) } == ["one", "two"])
        // A last line with no newline still counts when the pipe closes.
        _ = reader.feed(Data("last".utf8))
        #expect(reader.flush().map { String(decoding: $0, as: UTF8.self) } == "last")
        #expect(reader.flush() == nil)
    }

    @Test func theHelperIsWiredLikeTheMacApp() {
        // The same readers the app builds, with actions that answer for this platform.
        let services = HiveServices(actions: HelperActions(), pages: nil, start: false)
        #expect(services.paths.home.path == HivePaths.current.home.path)
        // `open` is a real action on Windows now — it brings the Claude app forward when no claude:// handler
        // exists — so what is worth pinning down is that an id which isn't shaped like one is refused before
        // any command runs.
        #expect(HelperActions().openInTerminal(sessionId: "not an id; rm -rf", cwd: nil) == false)
    }
}
