import Foundation
import Testing

/// The app icon made by scripts/make_icon.swift: every macOS size in the icns, and Info.plist naming it.
@Suite struct AppIconTests {
    static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func infoPlistNamesTheIcon() throws {
        let data = try Data(contentsOf: Self.repo.appending(path: "Sources/HiveApp/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
    }

    #if os(macOS)
    // The .icns container is a Mac format; Windows takes PNGs and an .ico.
    @Test func icnsHoldsEverySize() async throws {
        let icns = Self.repo.appending(path: "Sources/HiveApp/Resources/AppIcon.icns")
        let out = FileManager.default.temporaryDirectory.appending(path: "icon-\(UUID().uuidString).iconset")
        defer { try? FileManager.default.removeItem(at: out) }
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/iconutil")
        p.arguments = ["-c", "iconset", icns.path, "-o", out.path]
        let exited = AsyncStream<Void> { c in p.terminationHandler = { _ in c.yield(); c.finish() } }
        try p.run()
        for await _ in exited {}
        #expect(p.terminationStatus == 0)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: out.path))
        var expected = Set<String>()
        for s in [16, 32, 128, 256, 512] { expected.insert("icon_\(s)x\(s).png"); expected.insert("icon_\(s)x\(s)@2x.png") }
        #expect(names == expected)
    }
    #endif

    @Test func bundleScriptCopiesTheIcon() throws {
        let script = try String(contentsOf: Self.repo.appending(path: "scripts/bundle.sh"), encoding: .utf8)
        #expect(script.contains("AppIcon.icns"))
    }
}
