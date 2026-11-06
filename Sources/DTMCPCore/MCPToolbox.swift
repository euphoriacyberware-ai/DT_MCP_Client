import Foundation
import MCP

/// Tool definitions and dispatch. Results are JSON text so small models can read them easily.
public struct MCPToolbox: Sendable {
    let manager: GenerationManager
    let log: @Sendable (String) -> Void

    public init(manager: GenerationManager, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.manager = manager
        self.log = log
    }

    // MARK: Schema

    private static func prop(_ type: String, _ desc: String) -> Value {
        .object(["type": .string(type), "description": .string(desc)])
    }

    public static let tools: [Tool] = [
        Tool(
            name: "get_server_status",
            description: "Check whether the Draw Things server is reachable. Call this first.",
            inputSchema: .object(["type": "object", "properties": .object([:])]),
            annotations: .init(title: "Server status", readOnlyHint: true)),
        Tool(
            name: "generate_image",
            description: """
                Start a text-to-image job. Returns a job_id immediately; then call wait_for_job \
                (or get_job) to get the saved file paths. Omitted settings use the user's defaults.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "prompt": prop("string", "What to draw."),
                    "negative_prompt": prop("string", "What to avoid."),
                    "model": prop("string", "Model file name, e.g. z_image_turbo_1.0_q8p.ckpt."),
                    "width": prop("integer", "Pixels, multiple of 64."),
                    "height": prop("integer", "Pixels, multiple of 64."),
                    "steps": prop("integer", "Sampling steps."),
                    "guidance_scale": prop("number", "CFG scale; model-specific."),
                    "shift": prop("number", "Sampling shift; model-specific."),
                    "sampler": prop("string", "Sampler id, e.g. unipctrailing, eulera, dpmpp2mkarras."),
                    "seed": prop("integer", "Omit for random. The used seed is returned."),
                    "batch_count": prop("integer", "Number of images."),
                    "loras": .object([
                        "type": "array",
                        "description": "LoRAs to apply.",
                        "items": .object([
                            "type": "object",
                            "properties": .object([
                                "file": prop("string", "LoRA file name."),
                                "weight": prop("number", "Strength, default 1.0."),
                            ]),
                            "required": .array([.string("file")]),
                        ]),
                    ]),
                ]),
                "required": .array([.string("prompt")]),
            ]),
            annotations: .init(title: "Generate image", readOnlyHint: false, openWorldHint: false)),
        Tool(
            name: "get_job",
            description: "Get the status, progress and output file paths of a job.",
            inputSchema: .object([
                "type": "object",
                "properties": .object(["job_id": prop("string", "Id returned by generate_image.")]),
                "required": .array([.string("job_id")]),
            ]),
            annotations: .init(title: "Get job", readOnlyHint: true)),
        Tool(
            name: "wait_for_job",
            description: "Wait until a job finishes (or the timeout passes), then return its state.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "job_id": prop("string", "Id returned by generate_image."),
                    "timeout_seconds": prop("integer", "Max seconds to wait, default 60, max 300."),
                ]),
                "required": .array([.string("job_id")]),
            ]),
            annotations: .init(title: "Wait for job", readOnlyHint: true)),
        Tool(
            name: "list_jobs",
            description: "List recent jobs, newest first.",
            inputSchema: .object(["type": "object", "properties": .object([:])]),
            annotations: .init(title: "List jobs", readOnlyHint: true)),
        Tool(
            name: "cancel_job",
            description: "Cancel a queued or running job.",
            inputSchema: .object([
                "type": "object",
                "properties": .object(["job_id": prop("string", "Job to cancel.")]),
                "required": .array([.string("job_id")]),
            ]),
            annotations: .init(title: "Cancel job", destructiveHint: false)),
    ]

    // MARK: Dispatch

    public func call(_ name: String, _ args: [String: Value]?) async -> CallTool.Result {
        log("tool \(name) \(args.map { String(describing: $0) } ?? "")")
        do {
            switch name {
            case "get_server_status":
                return json(await manager.status())
            case "generate_image":
                return json(try await generateImage(args ?? [:]))
            case "get_job":
                let id = try requireString(args, "job_id")
                guard let job = await manager.jobs.get(id) else { throw ToolError("Unknown job_id '\(id)'.") }
                return json(job)
            case "wait_for_job":
                let id = try requireString(args, "job_id")
                let secs = min(max(args?["timeout_seconds"]?.intValue ?? 60, 1), 300)
                guard let job = await manager.jobs.wait(id, timeout: .seconds(secs)) else {
                    throw ToolError("Unknown job_id '\(id)'.")
                }
                return json(job)
            case "list_jobs":
                return json(await manager.jobs.list())
            case "cancel_job":
                let id = try requireString(args, "job_id")
                let ok = await manager.jobs.cancel(id)
                return json(["cancelled": ok])
            default:
                throw ToolError("Unknown tool '\(name)'.")
            }
        } catch {
            return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
        }
    }

    private func generateImage(_ a: [String: Value]) async throws -> Job {
        let d = await manager.defaults
        guard let prompt = a["prompt"]?.stringValue, !prompt.isEmpty else {
            throw ToolError("'prompt' is required.")
        }
        var p = ImageJobParams(
            prompt: prompt,
            model: a["model"]?.stringValue ?? d.model,
            width: a["width"]?.intValue ?? d.width,
            height: a["height"]?.intValue ?? d.height,
            steps: a["steps"]?.intValue ?? d.steps,
            guidanceScale: a["guidance_scale"]?.doubleValue ?? d.guidanceScale,
            shift: a["shift"]?.doubleValue ?? d.shift,
            sampler: a["sampler"]?.stringValue ?? d.sampler)
        p.negativePrompt = a["negative_prompt"]?.stringValue ?? ""
        p.batchCount = max(a["batch_count"]?.intValue ?? 1, 1)
        if let s = a["seed"]?.intValue {
            guard let seed = UInt32(exactly: s) else { throw ToolError("'seed' must be 0...4294967295.") }
            p.seed = seed
        }
        for item in a["loras"]?.arrayValue ?? [] {
            guard let file = item.objectValue?["file"]?.stringValue else {
                throw ToolError("Each lora needs a 'file'.")
            }
            p.loras.append((file, item.objectValue?["weight"]?.doubleValue ?? 1.0))
        }
        guard p.width % 64 == 0, p.height % 64 == 0, p.width > 0, p.height > 0 else {
            throw ToolError("width and height must be positive multiples of 64.")
        }
        return try await manager.submitImage(p)
    }

    // MARK: Helpers

    struct ToolError: Error, LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    private func requireString(_ a: [String: Value]?, _ key: String) throws -> String {
        guard let s = a?[key]?.stringValue, !s.isEmpty else { throw ToolError("'\(key)' is required.") }
        return s
    }

    private func json<T: Encodable>(_ value: T) -> CallTool.Result {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let text = (try? enc.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }
}
