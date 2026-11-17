import Foundation

/// Everything the API needs, wired once, with no UI.
///
/// The Mac app builds these readers for its window and menu bar; `hive-core` builds the same ones for its pipe.
/// Only two things differ between them, and both are the shell's business: the `ActionHandler` (opening a URL
/// or a folder) and where the pages are.
public final class HiveServices: Sendable {
    public let paths: HivePaths
    public let board: Board
    public let usage: UsageCounter
    public let skills: SkillsReader
    public let jobs: SkillsJobs
    public let limits: LimitsService
    public let api: HiveAPI

    /// - Parameters:
    ///   - start: start the board, usage and limits refresh loops, as the Mac app does. `hive-core --dump`
    ///     leaves them off and refreshes once instead.
    public init(paths: HivePaths = .current,
                processes: ProcessSource = ProcessSources.system(),
                keys: KeyStore = KeyStores.system(),
                http: HTTPClient = URLSessionHTTP(),
                actions: ActionHandler,
                pages: URL? = nil,
                start: Bool = false) {
        self.paths = paths
        let replies = ReplySender(paths: paths)
        let board = Board(paths: paths, processes: processes, pageVersion: 1, replies: replies)
        let usage = UsageCounter(paths: paths, antigravityProject: { board.antigravityProject($0) })
        let skills = SkillsReader(paths: paths)
        let jobs = SkillsJobs(paths: paths, onFinish: { skills.invalidate() })
        let limits = LimitsService(paths: paths, keys: keys, http: http)
        let api = HiveAPI(board: board, usage: usage, skills: skills, jobs: jobs, system: SystemReport(paths: paths),
                          classroom: ClassroomStore(paths: paths), actions: actions, pages: pages, replies: replies,
                          connectors: ConnectorsReader(paths: paths), limits: limits)

        self.board = board
        self.usage = usage
        self.skills = skills
        self.jobs = jobs
        self.limits = limits
        self.api = api

        guard start else { return }
        // HIVE_ONLY lets a developer start one loop on its own while measuring; it changes nothing by default.
        let only = ProcessInfo.processInfo.environment["HIVE_ONLY"]
        Task {
            if only == nil || only == "board" { await board.start() }
            if only == nil || only == "usage" { usage.start() }
            if only == nil || only == "limits" { await limits.start() }
        }
    }
}

/// The app's version. Phase 5 replaces the fallback with a generated value, so the helper, the Mac app's plist
/// and the Tauri manifest cannot drift apart.
public enum HiveVersion {
    public static let value: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.4.0"
}
