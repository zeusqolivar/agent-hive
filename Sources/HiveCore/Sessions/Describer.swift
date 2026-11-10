import Foundation

/// Sorts a session into a group (needs, working, idle) and says in one sentence what is going on,
/// as server.py's `describe` and `doing_of` do.
public enum Describer {
    public static func planSummary(_ plan: [PlanItem]) -> JSON {
        guard !plan.isEmpty else { return .null }
        let done = plan.filter { $0.state == "completed" }.count
        if done == plan.count { return .null }
        let current = plan.first { $0.state == "in_progress" }?.text
        return ["done": .int(done), "total": .int(plan.count), "current": JSON(current)]
    }

    private static func subagents(_ n: Int) -> String { "Waiting on \(n) subagent\(n != 1 ? "s" : "")" }

    public static func describe(raw: SessionFile, tail: TranscriptTail?, subsRunning: Int,
                                commands: [SessionCommand]) -> (group: String, reason: String?, headline: String) {
        var status = raw.status
        // The status file stays "busy" after a turn ends while anything the session started is still
        // alive. A finished turn with a question is waiting on you; with nothing left running it's idle.
        if status == "busy", let tail, tail.turnEnded, tail.pending.isEmpty, subsRunning == 0 {
            if tail.ask?.isEmpty == false || commands.isEmpty { status = "idle" }
        }
        let pending = tail?.pending ?? []
        let last = pending.last

        if status == "waiting" {
            if let last, last.tool == "AskUserQuestion" {
                return ("needs", "question", replacingFirst(last.title, "Ask ", "Asked: "))
            }
            if let last, last.tool == "ExitPlanMode" {
                return ("needs", "plan", "Waiting for you to approve the plan")
            }
            if raw.waitingFor == "permission prompt" {
                if let last, let first = last.title.first {
                    return ("needs", "permission", "Needs your OK to " + first.lowercased() + last.title.dropFirst())
                }
                return ("needs", "permission", "Waiting for your permission")
            }
            return ("needs", "other", "Waiting for " + (raw.waitingFor ?? "you"))
        }

        // A finished turn that ends with questions in plain text is waiting on you too, even if a background
        // command it started is still running.
        if let tail, tail.turnEnded, pending.isEmpty, subsRunning == 0, tail.ask?.isEmpty != false {
            let qs = OpenQuestions.of(tail)
            if let first = qs.first {
                return ("needs", "questions", "\(qs.count) open question\(qs.count != 1 ? "s" : ""): \(Text.oneLine(first, 140))")
            }
        }

        if status == "busy" {
            if let last {
                let verb = last.verb ?? "use"
                let obj = last.title.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                let object = obj.count > 1 ? String(obj[1]) : ""
                if last.tool == "Agent" || last.tool == "Task", subsRunning > 0 {
                    return ("working", nil, subagents(subsRunning))
                }
                return ("working", nil, Text.strip("\(verbIng[verb] ?? "Using") \(object)"))
            }
            let plan = tail.map { planSummary($0.plan) } ?? .null
            if subsRunning > 0 { return ("working", nil, subagents(subsRunning)) }
            if let first = commands.first { return ("working", nil, "Waiting on " + friendlyCommand(first.cmd)) }
            if let current = plan["current"]?.string, !current.isEmpty { return ("working", nil, current) }
            return ("working", nil, "Thinking")
        }

        if let ask = tail?.ask, !ask.isEmpty { return ("needs", "question", "Asked: " + Text.oneLine(ask, 160)) }
        if let recap = tail?.recap, !recap.isEmpty { return ("idle", nil, Text.firstSentence(recap)) }
        if let text = tail?.lastText, !text.isEmpty { return ("idle", nil, Text.firstSentence(text)) }
        return ("idle", nil, "No activity yet")
    }

    /// One word for what a working session is busy with; the Classroom walks it to the matching spot.
    public static func doing(group: String, tail: TranscriptTail?, subsRunning: Int, commands: [SessionCommand]) -> String? {
        guard group == "working" else { return nil }
        if subsRunning > 0 { return "subagents" }
        if let last = tail?.pending.last {
            let tool = last.tool ?? ""
            let lower = tool.lowercased()
            if tool == "WebFetch" || tool == "WebSearch" || lower.contains("browser") || lower.contains("chrome") {
                return "web"
            }
            let map = ["read": "read", "search": "read", "edit": "write", "write": "write", "run": "run"]
            return map[last.verb ?? ""] ?? "tool"
        }
        return commands.isEmpty ? "think" : "run"
    }

    static let shell = try! NSRegularExpression(pattern: #"^(\S*/)?(ba|z)?sh\s+(-\S+\s+)*"#)

    /// `waitpid.sh 30514` instead of `/bin/zsh /private/tmp/.../perf/waitpid.sh 30514`.
    static func friendlyCommand(_ cmd: String) -> String {
        let c = Text.strip(Text.sub(shell, "", cmd))
        let parts = c.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let first = parts.first.map(String.init) ?? ""
        let rest = parts.count > 1 ? " " + parts[1] : ""
        return Text.oneLine(Text.basename(first) + rest, 80)
    }

    static func replacingFirst(_ s: String, _ target: String, _ with: String) -> String {
        guard let r = s.range(of: target) else { return s }
        return s.replacingCharacters(in: r, with: with)
    }
}
