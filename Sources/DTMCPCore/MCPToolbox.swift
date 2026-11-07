import Foundation
import DrawThingsClient
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

    private static func listTool(_ name: String, _ desc: String, compat: Bool) -> Tool {
        var props: [String: Value] = [
            "query": prop("string", "Only entries whose name or file contains this text."),
            "limit": prop("integer", "Max entries to return, default 50."),
            "include_deprecated": prop("boolean", "Include models Draw Things has replaced. Default false."),
        ]
        if compat { props["compatible_with"] = prop("string", "Model file name; only compatible entries are returned.") }
        return Tool(
            name: name, description: desc,
            inputSchema: .object(["type": "object", "properties": .object(props)]),
            annotations: .init(title: name, readOnlyHint: true))
    }

    public static let tools: [Tool] = [
        Tool(
            name: "get_server_status",
            description: "Check whether the Draw Things server is reachable. Call this first.",
            inputSchema: .object(["type": "object", "properties": .object([:])]),
            annotations: .init(title: "Server status", readOnlyHint: true)),
        listTool("list_models", "List checkpoint models installed on the Draw Things server. Use the returned 'file' as the model for generate_image.", compat: false),
        listTool("list_loras", "List installed LoRAs. Pass compatible_with (a model file) to see only LoRAs that fit that model. Use 'trigger_prefix' text in your prompt if present.", compat: true),
        listTool("list_controlnets", "List installed ControlNet models, optionally only those compatible with a model.", compat: true),
        listTool("list_upscalers", "List installed upscaler models.", compat: false),
        Tool(
            name: "get_model_recommendations",
            description: "Suggested sampler, steps, guidance, shift and size for a model file. Call this before generate_image with a model you have not used.",
            inputSchema: .object([
                "type": "object",
                "properties": .object(["model": prop("string", "Model file name from list_models.")]),
                "required": .array([.string("model")]),
            ]),
            annotations: .init(title: "Model recommendations", readOnlyHint: true)),
        Tool(
            name: "generate_image",
            description: """
                Start an image job: text-to-image, or img2img when init_image is given, or inpaint \
                when init_image and mask_image are both given. Returns a job_id immediately; then \
                call wait_for_job (or get_job) to get the saved file paths. Omitted settings use \
                the user's defaults. Image paths must be inside a folder the user granted in the app \
                (the output folder counts, so you can refine earlier results).
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
                    "init_image": prop("string", "Absolute path of a starting image (PNG/JPEG/HEIC) for img2img or inpaint. If width/height are omitted they follow this image's shape."),
                    "strength": prop("number", "0-1. How much to change init_image. Default 0.7 for img2img, 1.0 for inpaint. Few-step (turbo) models barely change the picture below about 0.8; use 0.85-0.95 for big changes like a new scene or lighting."),
                    "mask_image": prop("string", "Absolute path of a mask image for inpaint (needs init_image). Same shape as init_image is best."),
                    "mask_mode": prop("string", "Which mask pixels get regenerated: 'white' (default), 'black', or 'alpha' (transparent)."),
                    "batch_count": prop("integer", "Number of images."),
                    "upscaler": prop("string", "Upscaler file from list_upscalers. The result is upscaled by that upscaler's factor (e.g. 2x), so the saved image is larger than width x height."),
                    "controls": .object([
                        "type": "array",
                        "description": "ControlNets that steer the layout. Each 'image' must already be the control map (a depth map, edge image, pose skeleton, scribble...), not an ordinary photo. The control file must be compatible with the model: use list_controlnets with compatible_with.",
                        "items": .object([
                            "type": "object",
                            "properties": .object([
                                "file": prop("string", "ControlNet file name from list_controlnets."),
                                "image": prop("string", "Absolute path of the control map image."),
                                "hint_type": prop("string", "What kind of map it is: depth, canny, pose, scribble, softedge, lineart, seg, mlsd, tile, shuffle. Usually inferred from the file name."),
                                "weight": prop("number", "0-2, default 1.0."),
                                "guidance_start": prop("number", "0-1, fraction of steps where control begins. Default 0."),
                                "guidance_end": prop("number", "0-1, fraction where control ends. Default 1; lower (e.g. 0.7) gives the model more freedom."),
                                "mode": prop("string", "balanced (default), prompt (favor the prompt) or control (favor the map)."),
                            ]),
                            "required": .array([.string("file"), .string("image")]),
                        ]),
                    ]),
                    "loras": Self.lorasProp,
                    "shift_for_audio": Self.shiftForAudioProp,
                    "config_json": Self.configJSONProp,
                ]),
                "required": .array([.string("prompt")]),
            ]),
            annotations: .init(title: "Generate image", readOnlyHint: false, openWorldHint: false)),
        Tool(
            name: "generate_video",
            description: """
                Start a video job with a video model (Wan, LTX, Hunyuan, ...; find one with list_models). \
                Returns a job_id; video takes minutes, so use wait_for_job with a long timeout. \
                outputs is [video.mp4, first_frame.png]. Give init_image to start from a picture \
                (image-to-video). Use get_model_recommendations for the model's size and settings. \
                Same folder rules as generate_image.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "prompt": prop("string", "What happens in the video."),
                    "negative_prompt": prop("string", "What to avoid."),
                    "model": prop("string", "Video model file name from list_models."),
                    "num_frames": prop("integer", "Number of frames; clip length is num_frames divided by the model's fps. Counts like 33, 49 or 81 are typical."),
                    "width": prop("integer", "Pixels, multiple of 64."),
                    "height": prop("integer", "Pixels, multiple of 64."),
                    "steps": prop("integer", "Sampling steps."),
                    "guidance_scale": prop("number", "CFG scale; model-specific."),
                    "shift": prop("number", "Sampling shift; model-specific."),
                    "sampler": prop("string", "Sampler name (e.g. ddimtrailing) or Draw Things numeric id (e.g. 16)."),
                    "seed": prop("integer", "Omit for random."),
                    "init_image": prop("string", "Absolute path of a start frame for image-to-video."),
                    "strength": prop("number", "0-1 for init_image; default 1.0."),
                    "loras": Self.lorasProp,
                    "shift_for_audio": Self.shiftForAudioProp,
                    "config_json": Self.configJSONProp,
                ]),
                "required": .array([.string("prompt"), .string("model"), .string("num_frames")]),
            ]),
            annotations: .init(title: "Generate video", readOnlyHint: false, openWorldHint: false)),
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
            case "list_models", "list_loras", "list_controlnets", "list_upscalers":
                let catalog = try await manager.catalog()
                var o = CatalogQuery.Options()
                o.query = args?["query"]?.stringValue
                o.limit = args?["limit"]?.intValue ?? 50
                o.includeDeprecated = args?["include_deprecated"]?.boolValue ?? false
                o.compatibleWith = args?["compatible_with"]?.stringValue
                if let m = o.compatibleWith, catalog.checkpoint(file: m) == nil {
                    throw ToolError("compatible_with '\(m)' is not an installed model. Call list_models first.")
                }
                switch name {
                case "list_models": return json(CatalogQuery.checkpoints(catalog, o))
                case "list_loras": return json(CatalogQuery.loras(catalog, o))
                case "list_controlnets": return json(CatalogQuery.controlNets(catalog, o))
                default: return json(CatalogQuery.upscalers(catalog, o))
                }
            case "get_model_recommendations":
                let model = try requireString(args, "model")
                let catalog = try await manager.catalog()
                return json(ModelPresets.recommend(model: model, catalog: catalog, defaults: await manager.defaults))
            case "generate_image":
                return json(try await generateImage(args ?? [:]))
            case "generate_video":
                var a = args ?? [:]
                guard a["model"]?.stringValue?.isEmpty == false else { throw ToolError("'model' is required for video.") }
                guard let n = a["num_frames"]?.intValue, n >= 2 else { throw ToolError("'num_frames' is required and must be at least 2.") }
                a["batch_count"] = nil
                a.removeValue(forKey: "mask_image")
                a.removeValue(forKey: "upscaler")
                if a["controls"] != nil { throw ToolError("controls are not supported for generate_video.") }
                return json(try await generateImage(a, numFrames: n))
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

    private func generateImage(_ a: [String: Value], numFrames: Int? = nil) async throws -> Job {
        let d = await manager.defaults
        guard let prompt = a["prompt"]?.stringValue, !prompt.isEmpty else {
            throw ToolError("'prompt' is required.")
        }
        // Start from the user's defaults; a supplied Draw Things configuration overlays them, and
        // explicit arguments override both.
        var base = DrawThingsConfiguration()
        base.model = d.model
        base.width = Int32(d.width)
        base.height = Int32(d.height)
        base.steps = Int32(d.steps)
        base.guidanceScale = Float(d.guidanceScale)
        base.shift = Float(d.shift)
        base.sampler = SamplerNames.resolve(d.sampler) ?? .dpmpp2mkarras
        var configGiven = false
        if let cv = a["config_json"], !(cv.stringValue ?? "x").isEmpty {
            let text: String
            if let s = cv.stringValue { text = s }
            else if let data = try? JSONEncoder().encode(cv), let s = String(data: data, encoding: .utf8) { text = s }
            else { throw ToolError("config_json must be a JSON string or object.") }
            do { try base.mergeJSON(text) }
            catch { throw ToolError("config_json is not a valid Draw Things configuration: \(error.localizedDescription)") }
            configGiven = true
        }
        // A sampler may be given as a name or as the numeric id Draw Things writes.
        let samplerArg: String? = a["sampler"]?.stringValue ?? a["sampler"]?.intValue.map(String.init)
        var p = ImageJobParams(
            prompt: prompt,
            model: a["model"]?.stringValue ?? base.model,
            width: a["width"]?.intValue ?? Int(base.width),
            height: a["height"]?.intValue ?? Int(base.height),
            steps: a["steps"]?.intValue ?? Int(base.steps),
            guidanceScale: a["guidance_scale"]?.doubleValue ?? Double(base.guidanceScale),
            shift: a["shift"]?.doubleValue ?? Double(base.shift),
            sampler: samplerArg ?? SamplerNames.name(of: base.sampler))
        p.numFrames = numFrames
        p.negativePrompt = a["negative_prompt"]?.stringValue ?? ""
        p.shiftForAudio = a["shift_for_audio"]?.doubleValue ?? (configGiven ? Double(base.shiftForAudio) : nil)
        if configGiven {
            p.baseConfig = base
            p.batchCount = max(a["batch_count"]?.intValue ?? Int(base.batchCount), 1)
            p.loras = base.loras.map { ($0.file, Double($0.weight)) }
            if numFrames == nil { p.upscaler = base.upscaler }
            if let s = base.seed { p.seed = s }
        } else {
            p.batchCount = max(a["batch_count"]?.intValue ?? 1, 1)
        }
        if let s = a["seed"]?.intValue {
            guard let seed = UInt32(exactly: s) else { throw ToolError("'seed' must be 0...4294967295.") }
            p.seed = seed
        }
        if let arr = a["loras"]?.arrayValue {
            p.loras = []
            for item in arr {
                guard let file = item.objectValue?["file"]?.stringValue else {
                    throw ToolError("Each lora needs a 'file'.")
                }
                p.loras.append((file, item.objectValue?["weight"]?.doubleValue ?? 1.0))
            }
        }
        if let ip = a["init_image"]?.stringValue, !ip.isEmpty {
            p.initImage = ip
            p.sizeFromImage = a["width"] == nil && a["height"] == nil
        } else if a["mask_image"] != nil {
            throw ToolError("mask_image needs init_image too.")
        }
        if let mp = a["mask_image"]?.stringValue, !mp.isEmpty { p.maskImage = mp }
        if let up = a["upscaler"]?.stringValue, !up.isEmpty { p.upscaler = up }
        else if a["upscaler"] != nil { p.upscaler = nil }
        for item in a["controls"]?.arrayValue ?? [] {
            guard let o = item.objectValue, let file = o["file"]?.stringValue, !file.isEmpty,
                let image = o["image"]?.stringValue, !image.isEmpty
            else { throw ToolError("Each control needs 'file' and 'image'.") }
            let hint: String
            if let h = o["hint_type"]?.stringValue { hint = h.lowercased() }
            else if let guess = ControlHints.infer(from: file) { hint = guess }
            else { throw ControlInputError.cannotInferHint(file) }
            var c = ControlInput(file: file, imagePath: image, hintType: hint)
            c.weight = o["weight"]?.doubleValue ?? 1.0
            c.guidanceStart = o["guidance_start"]?.doubleValue ?? 0.0
            c.guidanceEnd = o["guidance_end"]?.doubleValue ?? 1.0
            if let m = o["mode"]?.stringValue { c.mode = try ControlHints.parseMode(m) }
            p.controls.append(c)
        }
        if p.initImage == nil, !p.controls.isEmpty {
            p.sizeFromImage = a["width"] == nil && a["height"] == nil
        }
        if let m = a["mask_mode"]?.stringValue {
            guard let mode = MaskMode(rawValue: m.lowercased()) else { throw ImageInputError.invalidMode(m) }
            p.maskMode = mode
        }
        p.strength = a["strength"]?.doubleValue ?? (configGiven ? Double(base.strength) : nil)
        guard p.width % 64 == 0, p.height % 64 == 0, p.width > 0, p.height > 0 else {
            throw ToolError("width and height must be positive multiples of 64.")
        }
        return try await manager.submitImage(p)
    }

    // MARK: Helpers

    static let lorasProp: Value = .object([
        "type": "array",
        "description": "LoRAs to apply (image and video). Replaces any LoRAs in config_json.",
        "items": .object([
            "type": "object",
            "properties": .object([
                "file": prop("string", "LoRA file name."),
                "weight": prop("number", "Strength, default 1.0."),
            ]),
            "required": .array([.string("file")]),
        ]),
    ])

    static let shiftForAudioProp: Value = prop("number", "Sampling shift for the audio track of audio-capable video models (Draw Things default 3).")

    static let configJSONProp: Value = prop(
        "string",
        "A Draw Things configuration as JSON (the app's 'Copy Configuration' text, or a JSON object). It sets everything this tool has no argument for (LoRA modes, tiled decoding, TeaCache, sampler as a number, shiftForAudio, ...). Any argument you pass explicitly overrides it. Do not edit it beyond seed and frame count unless asked.")

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
