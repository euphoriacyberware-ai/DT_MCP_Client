import DTMCPCore
import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    // Persisted settings
    var endpoint = DrawThingsEndpointSettings() { didSet { save("endpoint", endpoint) } }
    var mcp = MCPServerSettings() { didSet { save("mcp", mcp) } }
    var defaults = GenerationDefaults() { didSet { save("defaults", defaults) } }
    var guardrails = Guardrails() { didSet { save("guardrails", guardrails) } }
    var sharedSecret: String = Keychain.get("drawthings-secret") ?? ""
    var token: String = Keychain.get("mcp-token") ?? ""

    // Live state
    var serverRunning = false
    var serverError: String?
    var connectionStatus: [String: String] = [:]
    var grants: [FolderAccess.Grant] = []
    var jobs: [Job] = []
    var callLog: [String] = []

    let folders = FolderAccess()
    let jobStore = JobStore()
    let manager: GenerationManager
    private let http: MCPHTTPServer

    init() {
        let manager = GenerationManager(jobs: jobStore, folders: folders)
        let box = LogBox()
        self.manager = manager
        self.http = MCPHTTPServer(toolbox: MCPToolbox(manager: manager, log: { box.append($0) }))

        endpoint = Self.load("endpoint") ?? endpoint
        mcp = Self.load("mcp") ?? mcp
        defaults = Self.load("defaults") ?? defaults
        guardrails = Self.load("guardrails") ?? guardrails
        if token.isEmpty { token = Keychain.randomToken(); Keychain.set(token, for: "mcp-token") }
        box.sink = { [weak self] line in Task { @MainActor in self?.appendLog(line) } }

        Task {
            await jobStore.setOnChange { [weak self] _ in Task { @MainActor in await self?.refreshJobs() } }
            await refreshGrants()
            await applyConnection()
            if mcp.autostart { await startServer() }
        }
    }

    // MARK: Actions

    func applyConnection() async {
        await manager.configure(
            endpoint: endpoint, sharedSecret: sharedSecret, defaults: defaults, guardrails: guardrails)
    }

    func testConnection() async {
        await applyConnection()
        connectionStatus = await manager.status()
    }

    func saveSecret() { Keychain.set(sharedSecret, for: "drawthings-secret") }

    func regenerateToken() {
        token = Keychain.randomToken()
        Keychain.set(token, for: "mcp-token")
        if serverRunning { Task { await stopServer(); await startServer() } }
    }

    func startServer() async {
        do {
            try await http.start(port: mcp.port, token: token)
            serverRunning = true
            serverError = nil
        } catch {
            serverRunning = false
            serverError = error.localizedDescription
        }
    }

    func stopServer() async {
        await http.stop()
        serverRunning = false
    }

    func grantFolder(_ url: URL, role: FolderAccess.Role) async {
        _ = try? await folders.grant(url, role: role)
        await refreshGrants()
    }

    func revoke(_ id: UUID) async {
        await folders.revoke(id)
        await refreshGrants()
    }

    func refreshGrants() async { grants = await folders.allGrants() }
    func refreshJobs() async { jobs = await jobStore.list(limit: 50) }

    func appendLog(_ line: String) {
        callLog.append(line)
        if callLog.count > 200 { callLog.removeFirst(callLog.count - 200) }
    }

    var clientConfigSnippet: String {
        """
        {
          "mcpServers": {
            "drawthings": {
              "url": "http://127.0.0.1:\(mcp.port)/mcp",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    // MARK: Persistence

    private func save<T: Encodable>(_ key: String, _ v: T) {
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

private final class LogBox: @unchecked Sendable {
    var sink: (@Sendable (String) -> Void)?
    func append(_ s: String) { sink?(s) }
}
