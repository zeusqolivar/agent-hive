import Foundation

/// Sessions with no live process whose transcript changed in the last 48 hours. The Claude app stops
/// idle session processes, so these are really "not running": they can continue.
final class EndedSessions: @unchecked Sendable {
    static let window: TimeInterval = 48 * 3600
    static let cacheFor: TimeInterval = 30

    private let paths: HivePaths
    private let naming: Naming
    private let transcripts: TranscriptReader
    private let subagents: SubagentReader
    private let locator: TranscriptLocator
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var builtAt: TimeInterval = -.infinity
    private var rows: [BoardRow] = []

    init(paths: HivePaths, transcripts: TranscriptReader, subagents: SubagentReader, locator: TranscriptLocator,
         now: @escaping @Sendable () -> Date) {
        self.paths = paths
        naming = Naming(paths: paths)
        self.transcripts = transcripts
        self.subagents = subagents
        self.locator = locator
        self.now = now
    }

    func rows(excluding live: Set<String>) -> [BoardRow] {
        let nowTs = now().timeIntervalSince1970
        lock.lock()
        let fresh = nowTs - builtAt < Self.cacheFor && nowTs >= builtAt
        let cached = rows
        lock.unlock()
        if fresh { return cached.filter { !live.contains($0.id) } }

        var out: [BoardRow] = []
        let cutoff = nowTs - Self.window
        for url in locator.allTranscripts() {
            guard let mdate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  mdate.timeIntervalSince1970 >= cutoff else { continue }
            let sid = String(url.lastPathComponent.dropLast(".jsonl".count))
            if live.contains(sid) { continue }
            guard let tail = transcripts.read(url), !tail.events.isEmpty else { continue }
            locator.remember(sid, url)
            let (project, worktree) = naming.projectOf(tail.cwd)
            let prompt = Text.oneLine(tail.prompt, 70)
            let name = tail.title.flatMap { $0.isEmpty ? nil : $0 } ?? (prompt.isEmpty ? project : prompt)
            let summary = [tail.recap, tail.lastText].compactMap { $0 }.first { !$0.isEmpty } ?? "Ended"
            out.append(BoardRow(
                id: sid, pid: nil, name: name, project: project, worktree: worktree, branch: tail.branch,
                cwd: tail.cwd, group: "ended", reason: nil, headline: Text.firstSentence(summary),
                doing: nil, statusSince: tail.mtime, lastTs: tail.mtime, model: tail.model, effort: tail.effort,
                subagentsRunning: 0, subagentsTotal: subagents.list(transcript: url).count, helpers: nil,
                plan: .null, hostId: nil, entry: nil, version: nil, startedAt: nil, uptime: nil, live: false))
        }
        out = Array(out.stableSorted { ($0.lastTs ?? 0) > ($1.lastTs ?? 0) }.prefix(60))
        lock.lock()
        builtAt = nowTs
        rows = out
        lock.unlock()
        return out.filter { !live.contains($0.id) }
    }
}

/// Finds a session's transcript under `~/.claude/projects/*/<id>.jsonl`, remembering what it found.
final class TranscriptLocator: @unchecked Sendable {
    private let paths: HivePaths
    private let lock = NSLock()
    private var known: [String: URL] = [:]

    init(paths: HivePaths) { self.paths = paths }

    func remember(_ id: String, _ url: URL) {
        lock.lock()
        known[id] = url
        lock.unlock()
    }

    func find(_ id: String) -> URL? {
        lock.lock()
        let cached = known[id]
        lock.unlock()
        if let cached, FileManager.default.fileExists(atPath: cached.path) { return cached }
        guard Patterns.isID(id) else { return nil }
        let hits = projectFolders().map { $0.appending(path: id + ".jsonl", directoryHint: .notDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if let best = hits.stableSorted(by: { mtime($0) < mtime($1) }).last {
            remember(id, best)
            return best
        }
        let antigravity = paths.antigravityTranscript(id)
        guard FileManager.default.fileExists(atPath: antigravity.path) else { return nil }
        remember(id, antigravity)
        return antigravity
    }

    func allTranscripts() -> [URL] {
        projectFolders().flatMap { folder -> [URL] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { $0.hasSuffix(".jsonl") }.map { folder.appending(path: $0, directoryHint: .notDirectory) }
        }
    }

    func projectFolders() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.projects.path)) ?? []
        return names.map { paths.projects.appending(path: $0, directoryHint: .isDirectory) }
    }

    private func mtime(_ url: URL) -> TimeInterval {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
    }
}
