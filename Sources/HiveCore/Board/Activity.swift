import Foundation

/// The per-session and cross-session views built from one board state: `/api/session/<id>`,
/// `/api/session/<id>/agent/<agentId>`, `/api/session/<id>/live` and `/api/activity`.
struct BoardViews {
    let builder: BoardBuilder
    let state: BoardState

    func sessionDetail(_ id: String, usage: (@Sendable (String) -> JSON)?) -> JSON? {
        guard let row = state.row(id), let url = builder.locator.find(id) else { return nil }
        let tail = builder.transcripts.read(url)
        let subs = builder.subagents.list(transcript: url)
            .stableSorted { a, b in
                let ka = (a.state == "running" ? 0 : 1, -a.lastTs), kb = (b.state == "running" ? 0 : 1, -b.lastTs)
                return ka < kb
            }
        let views = subs.prefix(40).enumerated().map { i, a in builder.subagents.view(a, withLast: i < 12) }
        let raw = state.raws[id]
        guard case .object(var o) = row.json else { return nil }
        o["events"] = .array((tail?.events ?? []).reversed().map(\.json))
        o["prompt"] = JSON(tail?.prompt)
        o["promptTs"] = JSON(tail?.promptTs)
        o["recap"] = JSON(tail?.recap)
        o["ask"] = JSON(tail?.ask)
        o["lastText"] = JSON(tail?.lastText)
        o["lastTextTs"] = JSON(tail?.lastTextTs)
        o["planItems"] = (tail?.plan ?? []).json
        o["prs"] = (tail?.prs ?? []).json
        o["contextTokens"] = JSON(tail?.contextTokens)
        o["mode"] = JSON(tail?.mode)
        o["subagentList"] = .array(Array(views))
        o["formerNames"] = .array((raw?.formerNames ?? []).map { $0.isEmpty ? .null : .string($0) })
        o["tokens"] = usage?(id) ?? .null
        o["transcriptMB"] = .double((Double(tail?.size ?? 0) / 1e6 * 10).rounded(.toNearestOrEven) / 10)
        o["shortCwd"] = JSON(builder.naming.shortPath(row.cwd))
        o["resumeCommand"] = row.cwd.flatMap { cwd -> String? in
            if cwd.isEmpty { return nil }
            if row.provider == "google" { return "open -a Antigravity \(Shell.quote(cwd))" }
            return "cd \(Shell.quote(cwd)) && claude --resume \(id)"
        }.map(JSON.string) ?? .null
        if let pid = row.pid {
            o["processes"] = ProcessTable.sessionProcesses(state.processes, pid: Int32(truncatingIfNeeded: pid),
                                                           naming: builder.naming).json
        }
        return .object(o)
    }

    func agentDetail(_ id: String, agentId: String) -> JSON? {
        guard let url = builder.locator.find(id), Patterns.isID(agentId),
              let agent = builder.subagents.list(transcript: url).first(where: { $0.id == agentId }) else { return nil }
        let log = URL(filePath: agent.path)
        let tail = builder.transcripts.read(log)
        guard case .object(var o) = builder.subagents.view(agent, withLast: true) else { return nil }
        o["brief"] = .string(SubagentReader.brief(log))
        o["events"] = .array((tail?.events ?? []).reversed().prefix(40).map(\.json))
        return .object(o)
    }

    func live(_ id: String) -> JSON? {
        guard let row = state.row(id), let url = builder.locator.find(id) else { return nil }
        var items = builder.liveFeed.items(transcript: url, sub: nil)
        for agent in builder.subagents.list(transcript: url) where agent.state == "running" {
            items += builder.liveFeed.items(transcript: URL(filePath: agent.path),
                                            sub: agent.description.isEmpty ? agent.type : agent.description)
        }
        items = items.stableSorted { ($0.t ?? 0) < ($1.t ?? 0) }
        let tree = row.pid.map {
            ProcessTable.sessionProcesses(state.processes, pid: Int32(truncatingIfNeeded: $0), naming: builder.naming)
        }
        return [
            "name": .string(row.name), "group": .string(row.group), "headline": .string(row.headline),
            "model": JSON(row.model), "items": Array(items.suffix(LiveFeed.maxItems)).json,
            "tasks": builder.liveFeed.backgroundTasks(sessionId: id).json,
            "commands": (tree?.commands ?? []).json,
        ]
    }

    func activity() -> JSON {
        var items: [(t: Int, json: JSON)] = []
        for row in state.rows {
            guard let url = builder.locator.find(row.id), let tail = builder.transcripts.read(url) else { continue }
            for ev in tail.events.suffix(50) {
                guard let t = ev.t, t != 0 else { continue }
                items.append((t, [
                    "id": .string(ev.id), "t": .int(t), "k": .string(ev.k), "title": .string(ev.title),
                    "err": .bool(ev.err ?? false), "sid": .string(row.id), "name": .string(row.name),
                    "group": .string(row.group),
                ]))
            }
        }
        return .array(items.stableSorted { $0.t > $1.t }.prefix(240).map(\.json))
    }
}
