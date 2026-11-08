import AppKit
import DTMCPCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            ConnectionTab().tabItem { Label("Connection", systemImage: "network") }
            ServerTab().tabItem { Label("MCP Server", systemImage: "server.rack") }
            FoldersTab().tabItem { Label("Folders", systemImage: "folder") }
            SkillTab().tabItem { Label("Skill", systemImage: "book") }
            ActivityTab().tabItem { Label("Activity", systemImage: "list.bullet") }
        }
        .padding()
    }
}

private struct ConnectionTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        Form {
            Section("Draw Things server") {
                TextField("Host", text: $m.endpoint.host)
                TextField("Port", value: $m.endpoint.port, format: .number.grouping(.never))
                Toggle("Use TLS", isOn: $m.endpoint.useTLS)
                SecureField("Shared secret", text: $m.sharedSecret).onSubmit { m.saveSecret() }
                HStack {
                    Button("Save & test connection") {
                        m.saveSecret()
                        Task { await m.testConnection() }
                    }
                    if let c = m.connectionStatus["connected"] {
                        Text(c == "true" ? "Connected" : (m.connectionStatus["error"] ?? "Failed"))
                            .foregroundStyle(c == "true" ? .green : .red)
                    }
                }
            }
            Section("Defaults for agents") {
                TextField("Model", text: $m.defaults.model)
                TextField("Sampler", text: $m.defaults.sampler)
                TextField("Steps", value: $m.defaults.steps, format: .number)
                TextField("Width", value: $m.defaults.width, format: .number.grouping(.never))
                TextField("Height", value: $m.defaults.height, format: .number.grouping(.never))
                TextField("Guidance", value: $m.defaults.guidanceScale, format: .number)
                TextField("Shift", value: $m.defaults.shift, format: .number)
                Button("Apply") { Task { await m.applyConnection() } }
            }
            Section("Guardrails") {
                TextField("Max steps", value: $m.guardrails.maxSteps, format: .number)
                TextField("Max batch count", value: $m.guardrails.maxBatchCount, format: .number)
                TextField("Max video frames", value: $m.guardrails.maxFrames, format: .number)
                TextField("Max video processing memory (MB)", value: $m.guardrails.maxProcessingMemoryMB, format: .number.grouping(.never))
                TextField("Max pixels", value: $m.guardrails.maxPixels, format: .number.grouping(.never))
            }
        }
        .formStyle(.grouped)
    }
}

private struct ServerTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        Form {
            Section("Status") {
                LabeledContent("State", value: m.serverRunning ? "Running" : "Stopped")
                if let e = m.serverError { Text(e).foregroundStyle(.red) }
                TextField("Port", value: $m.mcp.port, format: .number.grouping(.never))
                Toggle("Start at launch", isOn: $m.mcp.autostart)
                Button(m.serverRunning ? "Stop" : "Start") {
                    Task { m.serverRunning ? await m.stopServer() : await m.startServer() }
                }
            }
            Section("Agent configuration") {
                Text(m.clientConfigSnippet).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("Copy config") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(m.clientConfigSnippet, forType: .string)
                    }
                    Button("Regenerate token") { m.regenerateToken() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FoldersTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Output folder (required)") {
                ForEach(model.grants.filter { $0.role == .output }) { g in row(g) }
                Button("Choose output folder…") { pick(.output) }
            }
            Section("Input folders (images agents may read)") {
                ForEach(model.grants.filter { $0.role == .input }) { g in row(g) }
                Button("Add input folder…") { pick(.input) }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ g: FolderAccess.Grant) -> some View {
        HStack {
            Text(g.path).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Remove", role: .destructive) { Task { await model.revoke(g.id) } }
        }
    }

    private func pick(_ role: FolderAccess.Role) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Grant Access"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.grantFolder(url, role: role) }
        }
    }
}

private struct ActivityTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading) {
            List(model.jobs) { job in
                VStack(alignment: .leading) {
                    HStack {
                        Text(job.id).font(.headline)
                        Text(job.status.rawValue).foregroundStyle(.secondary)
                        if let s = job.step, let t = job.totalSteps { Text("\(s)/\(t)") }
                    }
                    Text(job.prompt).lineLimit(2)
                    if let e = job.error { Text(e).foregroundStyle(.red) }
                    ForEach(job.outputs, id: \.self) { p in
                        Button(p) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                            .buttonStyle(.link)
                    }
                }
            }
            Text("Tool calls").font(.headline)
            List(Array(model.callLog.enumerated()), id: \.offset) { Text($0.element).font(.caption) }
                .frame(height: 120)
        }
        .task { await model.refreshJobs() }
    }
}

private struct SkillTab: View {
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        Form {
            Section("Agent skill") {
                Text("A skill is a short guide that teaches an AI agent how to use these tools well: the order to call them, safe settings, and what to do when something fails.")
                Text("Export it into the folder your agent harness reads skills from, or copy the text into the agent's instructions. It never contains your token.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Export skill folder…") { export() }
                    Button("Copy SKILL.md text") { copyText() }
                }
                if let message {
                    Text(message).foregroundStyle(failed ? .red : .green).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose the folder your agent loads skills from. A 'drawthings-mcp' folder will be created inside it."
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let out = try SkillExporter.export(to: url)
            message = "Exported to \(out.path)"; failed = false
        } catch {
            message = error.localizedDescription; failed = true
        }
    }

    private func copyText() {
        do {
            let text = try SkillExporter.skillText()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            message = "Copied \(text.count) characters."; failed = false
        } catch {
            message = error.localizedDescription; failed = true
        }
    }
}
