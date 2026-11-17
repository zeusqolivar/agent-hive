import Foundation
import Testing
@testable import HiveCore

/// A fresh, empty home folder in the temporary directory. Nothing here touches the real home folder.
func tempHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appending(path: "hive-limits-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct UsageHistoryTests {
    static let day: TimeInterval = 86_400
    static let now = ProvidersTests.now

    @Test func spendingSkipsTopUps() throws {
        let history = UsageHistory(file: try tempHome().appending(path: "usage-history.json"))
        let t = Self.now.addingTimeInterval(-3 * Self.day)
        try history.append(service: "deepseek", balance: 10, currency: "USD", at: t)
        try history.append(service: "deepseek", balance: 8, currency: "USD", at: t.addingTimeInterval(3600))      // -2
        try history.append(service: "deepseek", balance: 20, currency: "USD", at: t.addingTimeInterval(7200))     // top-up
        try history.append(service: "deepseek", balance: 19.5, currency: "USD", at: t.addingTimeInterval(10800))  // -0.5
        try history.append(service: "openrouter", balance: 1, currency: "USD", at: t.addingTimeInterval(10800))
        #expect(history.spent(service: "deepseek", from: t.addingTimeInterval(-1), to: Self.now) == 2.5)
        // Only decreases that ended inside the period count.
        #expect(history.spent(service: "deepseek", from: t.addingTimeInterval(5000), to: Self.now) == 0.5)
        #expect(history.spent(service: "openrouter", from: t, to: Self.now) == 0)
        #expect(history.spent(service: "missing", from: t, to: Self.now) == 0)
    }

    @Test func currencyChangeIsNotSpending() throws {
        let history = UsageHistory(file: try tempHome().appending(path: "h.json"))
        try history.append(service: "deepseek", balance: 100, currency: "CNY", at: Self.now.addingTimeInterval(-7200))
        try history.append(service: "deepseek", balance: 5, currency: "USD", at: Self.now.addingTimeInterval(-3600))
        #expect(history.spent(service: "deepseek", from: Self.now.addingTimeInterval(-Self.day), to: Self.now) == 0)
    }

    @Test func keepsSixtyDays() throws {
        let file = try tempHome().appending(path: "usage-history.json")
        let history = UsageHistory(file: file)
        try history.append(service: "deepseek", balance: 50, currency: "USD", at: Self.now.addingTimeInterval(-61 * Self.day))
        try history.append(service: "deepseek", balance: 40, currency: "USD", at: Self.now.addingTimeInterval(-59 * Self.day))
        try history.append(service: "deepseek", balance: 30, currency: "USD", at: Self.now)
        #expect(history.entries().count == 2)
        #expect(history.entries().first?.balance == 40)
        // The file holds balances and times only.
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"balance\""))
    }

    @Test func spentForPeriods() throws {
        let history = UsageHistory(file: try tempHome().appending(path: "h.json"))
        let p = Spending.periods(now: Self.now)
        try history.append(service: "deepseek", balance: 10, currency: "USD", at: p.month.addingTimeInterval(-3600))
        try history.append(service: "deepseek", balance: 9, currency: "USD", at: p.month.addingTimeInterval(3600))   // month
        try history.append(service: "deepseek", balance: 7, currency: "USD", at: p.week.addingTimeInterval(3600))    // week
        try history.append(service: "deepseek", balance: 6.5, currency: "USD", at: p.today.addingTimeInterval(3600)) // today
        let spent = history.spent(service: "deepseek", now: Self.now)
        #expect(spent == Spent(today: 0.5, week: 2.5, month: 3.5))
    }

    @Test func malformedFileStartsOver() throws {
        let file = try tempHome().appending(path: "h.json")
        try Data("{oops".utf8).write(to: file)
        let history = UsageHistory(file: file)
        #expect(history.entries().isEmpty)
        try history.append(service: "deepseek", balance: 1, currency: "USD", at: Self.now)
        #expect(history.entries().count == 1)
    }
}

@Suite struct ClaudeLimitsTests {
    static let now = ProvidersTests.now
    static let t = Int(now.timeIntervalSince1970)

    static func paths() throws -> HivePaths { HivePaths(home: try tempHome(), uid: 501) }

    static func save(_ paths: HivePaths, savedAt: Int, limits: String) throws {
        try FileManager.default.createDirectory(at: paths.supportFolder, withIntermediateDirectories: true)
        try Data(#"{"savedAt": \#(savedAt), "rate_limits": \#(limits)}"#.utf8).write(to: paths.claudeLimitsFile)
    }

    @Test func notSetUp() throws {
        let card = ClaudeLimits.read(paths: try Self.paths(), now: Self.now)
        #expect(card["id"] == "claude")
        #expect(card["kind"] == "plan")
        #expect(card["state"] == "not-set-up")
        #expect(card["windows"] == nil)
    }

    @Test func freshWindows() throws {
        let paths = try Self.paths()
        try Self.save(paths, savedAt: Self.t - 600, limits: """
            {"five_hour": {"used_percentage": 23.5, "resets_at": \(Self.t + 3600)},
             "seven_day": {"used_percentage": 41, "resets_at": \(Self.t + 86400)}}
            """)
        let card = ClaudeLimits.read(paths: paths, now: Self.now)
        #expect(card["state"] == "ok")
        #expect(card["updatedAt"] == .int(Self.t - 600))
        #expect(card["windows"] == [
            ["label": "5-hour", "usedPercent": 23.5, "resetsAt": .int(Self.t + 3600)],
            ["label": "Weekly", "usedPercent": 41, "resetsAt": .int(Self.t + 86400)],
        ])
    }

    @Test func staleWhenOld() throws {
        let paths = try Self.paths()
        // Saved six hours ago: the 5-hour window has reset since and is dropped; the weekly one is old.
        try Self.save(paths, savedAt: Self.t - 6 * 3600, limits: """
            {"five_hour": {"used_percentage": 90, "resets_at": \(Self.t - 3600)},
             "seven_day": {"used_percentage": 41, "resets_at": \(Self.t + 86400)}}
            """)
        let card = ClaudeLimits.read(paths: paths, now: Self.now)
        #expect(card["state"] == "stale")
        #expect(card["windows"]?.array?.map { $0["label"] } == ["Weekly"])
    }

    @Test func installedButNothingYet() throws {
        let paths = try Self.paths()
        try StatusLineInstaller(paths: paths).install()
        let card = ClaudeLimits.read(paths: paths, now: Self.now)
        #expect(card["state"] == "unavailable")
        #expect(card["message"]?.string?.contains("terminal") == true)
        #expect(card["installed"] == true)
    }
}

@Suite struct CodexLimitsTests {
    static let now = ProvidersTests.now

    @Test func latestRateLimitsFromTheNewestRollout() throws {
        let home = try Fixture.prepare("limits/codex-home")
        let card = CodexLimits.read(paths: HivePaths(home: home, uid: 501), now: Self.now)
        #expect(card["id"] == "codex")
        #expect(card["state"] == "ok")
        #expect(card["windows"] == [
            ["label": "5-hour", "usedPercent": 42.5, "resetsAt": 1_794_924_000],
            ["label": "Weekly", "usedPercent": 12.5, "resetsAt": 1_795_400_000],
        ])
        #expect(card["updatedAt"] == .int(1_794_909_900))  // 2026-11-17T10:05:00Z
    }

    @Test func olderFormatWithSecondsLeft() throws {
        let home = try Fixture.prepare("limits/codex-home")
        let newest = home.appending(path: ".codex/sessions/2026/11/17")
        try FileManager.default.removeItem(at: newest)
        let card = CodexLimits.read(paths: HivePaths(home: home, uid: 501),
                                    now: Date(timeIntervalSince1970: 1_794_820_200 + 60))  // a minute after the event
        // 2026-11-16T09:10:00Z plus resets_in_seconds.
        #expect(card["windows"]?.array?.map { $0["resetsAt"] } == [.int(1_794_820_200 + 600), .int(1_794_820_200 + 86400)])
        #expect(card["state"] == "ok")
    }

    @Test func noSessions() throws {
        let card = CodexLimits.read(paths: HivePaths(home: try tempHome(), uid: 501), now: Self.now)
        #expect(card["state"] == "unavailable")
        #expect(card["windows"] == nil)
    }

    @Test func windowLabels() {
        #expect(CodexLimits.label(minutes: 300) == "5-hour")
        #expect(CodexLimits.label(minutes: 10080) == "Weekly")
        #expect(CodexLimits.label(minutes: 1440) == "1-day")
        #expect(CodexLimits.label(minutes: 45) == "45-minute")
        #expect(CodexLimits.label(minutes: nil) == "Window")
    }

    @Test func antigravityIsUnavailable() {
        let card = PlanCards.antigravity()
        #expect(card["id"] == "antigravity")
        #expect(card["state"] == "unavailable")
    }
}

@Suite struct StatusLineInstallerTests {
    static func setup(_ settings: String?) throws -> (HivePaths, StatusLineInstaller) {
        let paths = HivePaths(home: try tempHome(), uid: 501)
        if let settings {
            try FileManager.default.createDirectory(at: paths.claude, withIntermediateDirectories: true)
            try Data(settings.utf8).write(to: paths.settings)
        }
        return (paths, StatusLineInstaller(paths: paths))
    }

    static func settings(_ paths: HivePaths) throws -> JSON { try JSON.parse(Data(contentsOf: paths.settings)) }

    #if !os(Windows)
    // StatusLineInstaller writes statusline.sh and sets a shell command. Phase 4 adds the PowerShell twin;
    // until then these tests describe the Mac only.
    @Test func installWithoutSettingsFileAndRemove() throws {
        let (paths, installer) = try Self.setup(nil)
        #expect(!installer.isInstalled)
        try installer.install()
        #expect(installer.isInstalled)
        let line = try Self.settings(paths)["statusLine"]
        #expect(line?["type"] == "command")
        #expect(line?["command"]?.string == "'\(paths.statusLineScript.path)'")
        let attrs = try FileManager.default.attributesOfItem(atPath: paths.statusLineScript.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o755)
        try installer.remove()
        #expect(!installer.isInstalled)
        #expect(!FileManager.default.fileExists(atPath: paths.statusLineScript.path))
        #expect(!FileManager.default.fileExists(atPath: paths.statusLinePrevious.path))
        #expect(try Self.settings(paths)["statusLine"] == nil)
    }

    @Test func noStatusLineRestoresBytes() throws {
        let original = "{\n  \"model\": \"opus\",\n  \"env\": {\n    \"A\": \"1\"\n  }\n}\n"
        let (paths, installer) = try Self.setup(original)
        try installer.install()
        let installed = try Self.settings(paths)
        #expect(installed["model"] == "opus")
        #expect(installed["env"] == ["A": "1"])
        #expect(installed.object?.keys == ["model", "env", "statusLine"])
        try installer.remove()
        #expect(try String(contentsOf: paths.settings, encoding: .utf8) == original)
    }

    @Test func emptyObjectRestoresBytes() throws {
        let (paths, installer) = try Self.setup("{ }")
        try installer.install()
        #expect(try Self.settings(paths)["statusLine"] != nil)
        try installer.remove()
        #expect(try String(contentsOf: paths.settings, encoding: .utf8) == "{ }")
    }

    @Test func existingStatusLineIsChainedAndRestoredExactly() throws {
        let original = """
            {
              "statusLine": {
                "type": "command",
                "command": "printf 'mine'",
                "padding": 1
              },
              "theme": "dark"
            }
            """
        let (paths, installer) = try Self.setup(original)
        try installer.install()
        let line = try #require(try Self.settings(paths)["statusLine"])
        #expect(line["command"]?.string?.contains("statusline.sh") == true)
        #expect(line["padding"] == 1)
        #expect(try Self.settings(paths)["theme"] == "dark")
        let script = try String(contentsOf: paths.statusLineScript, encoding: .utf8)
        #expect(script.contains("printf '\\''mine'\\''"))
        try installer.remove()
        #expect(try String(contentsOf: paths.settings, encoding: .utf8) == original)
    }

    @Test func otherChangesAreKeptOnRemove() throws {
        let (paths, installer) = try Self.setup(#"{"statusLine": {"type": "command", "command": "echo old"}, "a": 1}"#)
        try installer.install()
        // Something else edits settings.json while the status line is installed.
        guard case .object(var o) = try Self.settings(paths) else { Issue.record("not an object"); return }
        o["b"] = 2
        try JSON.object(o).serialized(indent: 2).write(to: paths.settings)
        try installer.remove()
        let after = try Self.settings(paths)
        #expect(after["statusLine"] == ["type": "command", "command": "echo old"])
        #expect(after["a"] == 1)
        #expect(after["b"] == 2)
    }

    @Test func replacedStatusLineIsLeftAlone() throws {
        let (paths, installer) = try Self.setup(#"{"a": 1}"#)
        try installer.install()
        let mine = #"{"a": 1, "statusLine": {"type": "command", "command": "echo someone-else"}}"#
        try Data(mine.utf8).write(to: paths.settings)
        #expect(!installer.isInstalled)
        try installer.remove()
        #expect(try String(contentsOf: paths.settings, encoding: .utf8) == mine)
        #expect(!FileManager.default.fileExists(atPath: paths.statusLineScript.path))
    }

    @Test func malformedSettingsAreNotTouched() throws {
        let (paths, installer) = try Self.setup("{ not json")
        #expect(throws: StatusLineError.self) { try installer.install() }
        #expect(try String(contentsOf: paths.settings, encoding: .utf8) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: paths.statusLineScript.path))
    }

    #endif

    @Test func installTwiceIsHarmless() throws {
        let (paths, installer) = try Self.setup(#"{"statusLine": {"type": "command", "command": "echo old"}}"#)
        try installer.install()
        try installer.install()
        let script = try String(contentsOf: paths.statusLineScript, encoding: .utf8)
        #expect(script.contains("echo old"))
        try installer.remove()
        #expect(try Self.settings(paths)["statusLine"] == ["type": "command", "command": "echo old"])
    }

    #if !os(Windows)
    // Windows refuses symlinks without Developer Mode or elevation; FileManager.copyItem and atomic replace keep
    // them intact there, but the test cannot set one up.
    @Test func symlinkedSettingsStayALink() throws {
        let (paths, installer) = try Self.setup(nil)
        let real = paths.home.appending(path: "dotfiles/settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"a": 1}"#.utf8).write(to: real)
        try FileManager.default.createDirectory(at: paths.claude, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.settings, withDestinationURL: real)
        try installer.install()
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: paths.settings.path)) != nil)
        #expect(try JSON.parse(Data(contentsOf: real))["statusLine"] != nil)
        try installer.remove()
        #expect(try String(contentsOf: real, encoding: .utf8) == #"{"a": 1}"#)
    }

    /// Runs the generated script the way Claude Code does: the status JSON on stdin, output to the status line.
    static func run(_ script: URL, stdin: String) async throws -> String {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = ["-c", "'\(script.path)'"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        // Wait without holding one of the test runner's threads.
        let exited = AsyncStream<Void> { c in p.terminationHandler = { _ in c.yield(); c.finish() } }
        try p.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        for await _ in exited {}
        return String(decoding: data, as: UTF8.self)
    }

    #endif

    #if !os(Windows)
    // These two run the script with sh. Windows gets the PowerShell script and its own tests in phase 4.
    @Test func scriptSavesLimitsAndRunsThePreviousCommand() async throws {
        let (paths, installer) = try Self.setup(
            #"{"statusLine": {"type": "command", "command": "/usr/bin/plutil -extract cwd raw -o - - ; echo ' done'"}}"#)
        try installer.install()
        let stdin = #"{"cwd": "/work/sample", "rate_limits": {"five_hour": {"used_percentage": 23.5, "resets_at": 1794920000}, "seven_day": {"used_percentage": 41, "resets_at": 1795400000}}}"#
        let out = try await Self.run(paths.statusLineScript, stdin: stdin)
        #expect(out == "/work/sample\n done\n")
        let saved = try JSON.parse(Data(contentsOf: paths.claudeLimitsFile))
        #expect(saved["rate_limits"]?["five_hour"]?["used_percentage"] == 23.5)
        #expect(saved["savedAt"]?.int != nil)
        // Only the limits are kept, not the rest of the status JSON.
        #expect(saved["cwd"] == nil)

        // A payload without rate_limits keeps the last saved limits.
        _ = try await Self.run(paths.statusLineScript, stdin: #"{"cwd": "/work/sample"}"#)
        #expect(try JSON.parse(Data(contentsOf: paths.claudeLimitsFile))["rate_limits"]?["seven_day"]?["used_percentage"] == 41)
    }

    @Test func scriptWithoutPreviousCommandPrintsNothing() async throws {
        let (paths, installer) = try Self.setup(nil)
        try installer.install()
        let out = try await Self.run(paths.statusLineScript, stdin: #"{"rate_limits": {"five_hour": {"used_percentage": 5, "resets_at": 1}}}"#)
        #expect(out.isEmpty)
        #expect(FileManager.default.fileExists(atPath: paths.claudeLimitsFile.path))
    }
    #endif
}
