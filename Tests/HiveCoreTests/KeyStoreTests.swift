import Foundation
import Testing
@testable import HiveCore

@Suite struct KeyStoreTests {
    @Test func memoryStoreSavesReplacesAndRemoves() throws {
        let store = MemoryKeyStore()
        #expect(store.key(for: "deepseek") == nil)
        try store.save("first", for: "deepseek")
        try store.save("second", for: "deepseek")
        #expect(store.key(for: "deepseek") == "second")
        #expect(store.key(for: "openai") == nil)
        try store.remove(service: "deepseek")
        #expect(store.key(for: "deepseek") == nil)
        try store.remove(service: "deepseek")  // removing nothing is fine
    }

    @Test func emptyKeyIsRejected() {
        #expect(throws: KeyStoreError.self) { try MemoryKeyStore().save("  \n", for: "deepseek") }
    }

    /// The only test that touches the real Keychain: a test-only service name, and the item is deleted.
    @Test func keychainRoundTrip() throws {
        let store = KeychainKeyStore(service: "io.github.agenthive.AgentHive.tests-\(UUID().uuidString)")
        let account = "test-account"
        defer { try? store.remove(service: account) }
        #expect(store.key(for: account) == nil)
        try store.save("not-a-real-key-1", for: account)
        try store.save("not-a-real-key-2", for: account)
        #expect(store.key(for: account) == "not-a-real-key-2")
        try store.remove(service: account)
        #expect(store.key(for: account) == nil)
    }

    @Test func keychainUsesTheAppsServiceByDefault() {
        #expect(KeychainKeyStore().service == "io.github.agenthive.AgentHive.usage")
    }
}

@Suite struct HTTPTests {
    @Test func fakeRecordsRequestsAndAnswers() async throws {
        let http = FakeHTTP()
        http.answer("https://api.example.com/x", status: 200, body: #"{"ok": true}"#)
        let r = try await http.get(URL(string: "https://api.example.com/x")!, headers: ["Authorization": "Bearer k"])
        #expect(r.status == 200)
        #expect(http.requests.map(\.url.host) == ["api.example.com"])
        #expect(http.requests.first?.headers["Authorization"] == "Bearer k")
        await #expect(throws: URLError.self) { try await http.get(URL(string: "https://other.example/")!, headers: [:]) }
    }

    @Test func urlSessionClientSettings() {
        let config = URLSessionHTTP.configuration
        #expect(config.timeoutIntervalForRequest == 15)
        #expect(config.httpCookieStorage == nil)
        #expect(config.urlCache == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }
}
