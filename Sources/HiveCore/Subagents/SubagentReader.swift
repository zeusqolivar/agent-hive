import Foundation

/// A real subagent, from `<session>/subagents/agent-<id>.meta.json` and its log.
public struct Subagent: Sendable, Equatable, JSONRepresentable {
    public var id: String
    public var type: String
    public var description: String
    public var state: String          // running, stalled or done
    public var startedAt: Int
    public var lastTs: Int
    public var path: String

    public var json: JSON {
        ["id": .string(id), "type": .string(type), "description": .string(description), "state": .string(state),
         "startedAt": .int(startedAt), "lastTs": .int(lastTs), "path": .string(path)]
    }
}

/// A running subagent as the Classroom draws it.
public struct Helper: Sendable, Equatable, JSONRepresentable {
    public var id: String
    public var type: String
    public var description: String
    public var doing: String?
    public var task: String

    public var json: JSON {
        ["id": .string(id), "type": .string(type), "description": .string(description),
         "doing": JSON(doing), "task": .string(task)]
    }
}

/// Reads a session's subagents as server.py's `list_subagents`, `helper_views` and `subagent_view` do.
public final class SubagentReader: @unchecked Sendable {
    public static let stall: TimeInterval = 30 * 60

    let transcripts: TranscriptReader
    let now: @Sendable () -> Date
    private let lock = NSLock()
    private var finishedMeta: [String: JSONObject] = [:]

    public init(transcripts: TranscriptReader, now: @escaping @Sendable () -> Date = Date.init) {
        self.transcripts = transcripts
        self.now = now
    }

    public func list(transcript: URL) -> [Subagent] {
        let path = transcript.path
        // Antigravity records no subagents of this kind.
        guard path.hasSuffix(".jsonl"), !transcripts.paths.isAntigravity(transcript) else { return [] }
        let folder = String(path.dropLast(".jsonl".count)) + "/subagents"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        let nowTs = now().timeIntervalSince1970
        var out: [Subagent] = []
        for name in names where name.hasPrefix("agent-") && name.hasSuffix(".meta.json") {
            let metaPath = folder + "/" + name
            lock.lock()
            var meta = finishedMeta[metaPath]
            lock.unlock()
            if meta == nil {
                guard let data = FileManager.default.contents(atPath: metaPath),
                      let o = (try? JSON.parse(data))?.object else { continue }
                meta = o
                if o["finished"].truthy {
                    lock.lock()
                    finishedMeta[metaPath] = o
                    lock.unlock()
                }
            }
            guard let meta else { continue }
            let agentID = String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
            let log = folder + "/agent-\(agentID).jsonl"
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: log),
                  let mdate = attrs[.modificationDate] as? Date else { continue }
            let mtime = mdate.timeIntervalSince1970
            let born = (attrs[.creationDate] as? Date)?.timeIntervalSince1970 ?? mtime
            let state = meta["finished"].truthy ? "done" : nowTs - mtime < Self.stall ? "running" : "stalled"
            out.append(Subagent(id: agentID, type: meta["agentType"].truthy ? Py.str(meta["agentType"]!) : "agent",
                                description: Py.str(orEmpty: meta["description"]), state: state,
                                startedAt: Int(born.rounded(.down)), lastTs: Int(mtime.rounded(.down)), path: log))
        }
        return out.stableSorted { $0.lastTs > $1.lastTs }
    }

    /// Running subagents for the Classroom, at most 12.
    public func helpers(_ agents: [Subagent]) -> [Helper] {
        var out: [Helper] = []
        for agent in agents where agent.state == "running" {
            let parsed = transcripts.read(URL(filePath: agent.path))
            let pending = parsed?.pending ?? []
            let task: String
            if let last = pending.last {
                task = last.title
            } else if let text = parsed?.lastText, !text.isEmpty {
                task = Text.firstSentence(text, 140)
            } else {
                task = ""
            }
            out.append(Helper(id: agent.id, type: agent.type,
                              description: agent.description.isEmpty ? agent.type : agent.description,
                              doing: Describer.doing(group: "working", tail: parsed, subsRunning: 0, commands: []),
                              task: task))
        }
        return Array(out.prefix(12))
    }

    /// `subagent_view`: the subagent without its path, plus what it last did when asked.
    public func view(_ agent: Subagent, withLast: Bool) -> JSON {
        guard case .object(var o) = agent.json else { return .null }
        o["path"] = nil
        if withLast, let parsed = transcripts.read(URL(filePath: agent.path)) {
            if let last = parsed.pending.last {
                o["last"] = .string(last.title)
            } else if let text = parsed.lastText, !text.isEmpty {
                o["last"] = .string(Text.firstSentence(text, 140))
            }
        }
        return .object(o)
    }

    /// `subagent_brief`: the first message of a subagent's log, which is its brief.
    public static func brief(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 200_000) else { return "" }
        let line = data.firstIndex(of: 0x0A).map { data[..<$0] } ?? data[...]
        guard let d = (try? JSON.parse(Data(line)))?.object else { return "" }
        var content = d["message"]?["content"]
        if let list = content?.array {
            content = .string(list.compactMap { $0.object }.map { Py.str(orEmpty: $0["text"]) }.joined(separator: "\n"))
        }
        return Text.prefix(Py.str(orEmpty: content), 3000)
    }
}
