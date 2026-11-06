import DTMCPCore
import SwiftUI

@main
struct DTMCPClientApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("DT MCP Client") {
            ContentView().environment(model).frame(minWidth: 640, minHeight: 520)
        }
        MenuBarExtra("DT MCP", systemImage: model.serverRunning ? "photo.circle.fill" : "photo.circle") {
            Text(model.serverRunning ? "MCP server running on port \(model.mcp.port)" : "MCP server stopped")
            Button(model.serverRunning ? "Stop server" : "Start server") {
                Task { model.serverRunning ? await model.stopServer() : await model.startServer() }
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
