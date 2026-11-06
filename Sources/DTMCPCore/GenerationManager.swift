import CoreGraphics
import DrawThingsClient
import Foundation

/// Parameters of a text-to-image job as parsed from an agent's tool call.
public struct ImageJobParams: Sendable {
    public var prompt: String
    public var negativePrompt: String = ""
    public var model: String
    public var width: Int
    public var height: Int
    public var steps: Int
    public var guidanceScale: Double
    public var shift: Double
    public var sampler: String
    public var seed: UInt32?
    public var batchCount: Int = 1
    public var loras: [(file: String, weight: Double)] = []
    /// Path to an init image (img2img). Must be inside a folder the user granted.
    public var initImage: String?
    /// Path to a mask image (inpaint). Requires `initImage`.
    public var maskImage: String?
    public var maskMode: MaskMode = .white
    /// 0...1. Defaults to 0.7 for img2img and 1.0 for inpaint.
    public var strength: Double?
    /// When true, width/height are derived from the init image instead of the values above.
    public var sizeFromImage = false
    /// Set for video jobs: number of frames to generate. Requires a video model.
    public var numFrames: Int?
    /// ControlNets to apply; each carries its own prepared control map (depth map, edges, pose, ...).
    public var controls: [ControlInput] = []
    /// Upscaler file; the finished image is upscaled by the factor the upscaler is made for.
    public var upscaler: String?
}

public enum GenerationError: Error, LocalizedError {
    case invalid(String)
    case notConfigured
    case unknownSampler(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let m): return m
        case .notConfigured: return "Not connected to a Draw Things server. Ask the user to configure the connection in the DT MCP Client app."
        case .unknownSampler(let s): return "Unknown sampler '\(s)'. Valid samplers: \(SamplerNames.all.joined(separator: ", "))"
        }
    }
}

public enum SamplerNames {
    public static let map: [String: SamplerType] = [
        "dpmpp2mkarras": .dpmpp2mkarras, "eulera": .eulera, "ddim": .ddim, "plms": .plms,
        "dpmppsdekarras": .dpmppsdekarras, "unipc": .unipc, "lcm": .lcm,
        "eulerasubstep": .eulerasubstep, "dpmppsdesubstep": .dpmppsdesubstep, "tcd": .tcd,
        "euleratrailing": .euleratrailing, "dpmppsdetrailing": .dpmppsdetrailing,
        "dpmpp2mays": .dpmpp2mays, "euleraays": .euleraays, "dpmppsdeays": .dpmppsdeays,
        "dpmpp2mtrailing": .dpmpp2mtrailing, "ddimtrailing": .ddimtrailing,
        "unipctrailing": .unipctrailing, "unipcays": .unipcays, "tcdtrailing": .tcdtrailing,
    ]
    public static var all: [String] { map.keys.sorted() }
}

/// Owns the connection to Draw Things and runs jobs one at a time (the server renders serially).
public actor GenerationManager {
    public let jobs: JobStore
    private let folders: FolderAccess
    private var service: DrawThingsService?
    private var tail: Task<Void, Never>?

    public private(set) var endpoint = DrawThingsEndpointSettings()
    public var defaults = GenerationDefaults()
    public var guardrails = Guardrails()

    public init(jobs: JobStore, folders: FolderAccess) {
        self.jobs = jobs
        self.folders = folders
    }

    // MARK: Configuration

    public func configure(
        endpoint: DrawThingsEndpointSettings, sharedSecret: String?,
        defaults: GenerationDefaults, guardrails: Guardrails
    ) async {
        self.defaults = defaults
        self.guardrails = guardrails
        let old = service
        cachedCatalog = nil
        self.endpoint = endpoint
        var options = ConnectionOptions()
        options.security = endpoint.useTLS ? .tls() : .plaintext
        options.sharedSecret = (sharedSecret?.isEmpty ?? true) ? nil : sharedSecret
        service = DrawThingsService(
            endpoint: ServerEndpoint(host: endpoint.host, port: endpoint.port), options: options)
        await old?.shutdown()
    }

    /// Connects (echo) and returns a short status for the UI and the `get_server_status` tool.
    public func status() async -> [String: String] {
        guard let service else { return ["connected": "false", "error": GenerationError.notConfigured.localizedDescription] }
        do {
            let reply = try await service.echo()
            return [
                "connected": "true",
                "server_identifier": String(reply.serverIdentifier),
                "shared_secret_missing": String(reply.sharedSecretMissing),
                "host": "\(endpoint.host):\(endpoint.port)",
            ]
        } catch {
            return ["connected": "false", "error": error.localizedDescription]
        }
    }

    // MARK: Catalog

    private var cachedCatalog: ModelCatalog?

    /// Installed models, LoRAs, ControlNets and upscalers, cached for 30 seconds.
    public func catalog(forceRefresh: Bool = false) async throws -> ModelCatalog {
        if !forceRefresh, let c = cachedCatalog, Date().timeIntervalSince(c.fetchedAt) < 30 { return c }
        guard let service else { throw GenerationError.notConfigured }
        let reply = try await service.echo()
        let c = ModelCatalog.parse(reply.override)
        cachedCatalog = c
        return c
    }

    // MARK: Jobs

    /// Validates, registers and enqueues a text-to-image job. Returns immediately with the job.
    public func submitImage(_ params: ImageJobParams) async throws -> Job {
        guard let service else { throw GenerationError.notConfigured }
        guard let sampler = SamplerNames.map[params.sampler.lowercased()] else {
            throw GenerationError.unknownSampler(params.sampler)
        }
        var params = params
        let outDir = try await folders.outputFolder()

        // Load and prepare img2img / inpaint inputs up front so problems come back to the agent immediately.
        var initCG: CGImage?
        var maskCG: CGImage?
        var maskedFraction: Double?
        if params.maskImage != nil && params.initImage == nil {
            throw ImageInputError.unreadable("mask_image requires init_image")
        }
        if let path = params.initImage {
            let img = try await ImageInputs.load(path: path, folders: folders)
            if params.sizeFromImage {
                let size = ImageInputs.canvasSize(for: img, maxPixels: max(defaults.width * defaults.height, 64 * 64))
                params.width = size.width
                params.height = size.height
            }
            initCG = ImageInputs.fit(img, width: params.width, height: params.height)
            if let mp = params.maskImage {
                let raw = try await ImageInputs.load(path: mp, folders: folders)
                maskCG = try ImageInputs.drawThingsMask(
                    from: raw, mode: params.maskMode, width: params.width, height: params.height)
                maskedFraction = ImageInputs.regeneratedFraction(maskCG!)
            }
        }
        // ControlNets: validate against the server's catalog, then load and size each control map.
        var hints: [HintProto] = []
        var controlConfigs: [ControlConfig] = []
        if !params.controls.isEmpty {
            guard params.controls.count <= ControlHints.maxControls else {
                throw ControlInputError.tooMany(params.controls.count)
            }
            let cat = try? await catalog()
            var maps: [CGImage] = []
            for c in params.controls {
                try ControlHints.validate(c, model: params.model, catalog: cat)
                maps.append(try await ImageInputs.load(path: c.imagePath, folders: folders))
            }
            // With no init image and no explicit size, the first control map sets the canvas.
            if initCG == nil, params.sizeFromImage {
                let size = ImageInputs.canvasSize(for: maps[0], maxPixels: max(defaults.width * defaults.height, 64 * 64))
                params.width = size.width
                params.height = size.height
            }
            var builder = HintBuilder()
            for (c, map) in zip(params.controls, maps) {
                let fitted = ImageInputs.fit(map, width: params.width, height: params.height)
                builder.addHint(type: c.hintType, imageData: try ImageHelpers.pngData(for: fitted), weight: Float(c.weight))
                controlConfigs.append(ControlConfig(
                    file: c.file, weight: Float(c.weight), guidanceStart: Float(c.guidanceStart),
                    guidanceEnd: Float(c.guidanceEnd), controlMode: c.mode))
            }
            hints = try builder.build()
        }
        // Upscaler: must be installed when we can see the server's catalog.
        var upscaleFactor: Int32 = 0
        if let up = params.upscaler {
            let cat = try? await catalog()
            if let cat, !cat.isEmpty {
                guard let u = cat.upscalers.first(where: { $0.file == up }) else {
                    throw GenerationError.invalid("Upscaler '\(up)' is not installed. Call list_upscalers for valid files.")
                }
                upscaleFactor = Int32(u.scaleFactor ?? 0)
            }
        }
        let isVideo = params.numFrames != nil
        if isVideo {
            if params.maskImage != nil { throw ImageInputError.unreadable("mask_image is not supported for video") }
            if params.batchCount != 1 { throw GenerationError.invalid("batch_count must be 1 for video.") }
            if let n = params.numFrames, n > guardrails.maxFrames {
                throw VideoOutputError.tooManyFrames(n, guardrails.maxFrames)
            }
            let version = (try? await catalog())?.checkpoint(file: params.model)?.version
            if VideoOutput.isKnownImageModel(params.model, version: version) {
                throw VideoOutputError.notAVideoModel(params.model)
            }
        }
        // A video start frame should be followed closely; image edits default lower.
        let strength = params.strength ?? (maskCG != nil || isVideo ? 1.0 : 0.7)
        guard (0...1).contains(strength) else { throw ImageInputError.strengthOutOfRange(strength) }
        let kind = isVideo ? "video" : (maskCG != nil ? "inpaint" : (initCG != nil ? "img2img" : "image"))

        try guardrails.check(
            width: params.width, height: params.height, steps: params.steps,
            batchCount: params.batchCount)

        var seed = params.seed
        if seed == nil { seed = UInt32.random(in: 0...UInt32.max) }

        let job = await jobs.create(kind: kind, prompt: params.prompt, model: params.model)
        let note: String? = initCG.map { _ in
            let pct = maskedFraction.map { ", \(Int(($0 * 100).rounded()))% of the image regenerated" } ?? ""
            return "canvas \(params.width)x\(params.height), strength \(strength)\(pct)"
        } ?? (isVideo ? "canvas \(params.width)x\(params.height), \(params.numFrames ?? 0) frames" : nil)
        let controlNote = params.controls.isEmpty ? nil
            : "controls: " + params.controls.map { "\($0.hintType) via \($0.file)" }.joined(separator: ", ")
        let upNote = params.upscaler.map { "upscaler: \($0)" }
        let fullNote = [note, controlNote, upNote].compactMap { $0 }.joined(separator: "; ")
        await jobs.update(job.id) { $0.seed = seed; $0.note = fullNote.isEmpty ? nil : fullNote }

        var cfg = DrawThingsConfiguration()
        cfg.width = Int32(params.width)
        cfg.height = Int32(params.height)
        cfg.steps = Int32(params.steps)
        cfg.model = params.model
        cfg.sampler = sampler
        cfg.guidanceScale = Float(params.guidanceScale)
        cfg.shift = Float(params.shift)
        cfg.seed = seed
        cfg.batchCount = Int32(params.batchCount)
        cfg.loras = params.loras.map { LoRAConfig(file: $0.file, weight: Float($0.weight)) }
        cfg.controls = controlConfigs
        if let up = params.upscaler { cfg.upscaler = up; cfg.upscalerScaleFactor = upscaleFactor }
        if let n = params.numFrames { cfg.numFrames = Int32(n) }
        if initCG != nil {
            cfg.strength = Float(strength)
            // Dedicated inpainting checkpoints need the inpaint control enabled.
            if maskCG != nil, let c = try? await catalog(),
                c.checkpoint(file: params.model)?.modifier == "inpainting"
            {
                cfg.enableInpainting = true
            }
        }
        let request = GenerationRequest(
            prompt: params.prompt, negativePrompt: params.negativePrompt, configuration: cfg,
            image: initCG, mask: maskCG, hints: hints)

        let previous = tail
        let jobs = self.jobs
        let jobID = job.id
        let task = Task {
            await previous?.value
            if Task.isCancelled { return }
            await jobs.update(jobID) { $0.status = .running }
            do {
                let result = try await service.generate(request) { event in
                    if case .progress(let p) = event {
                        await jobs.update(jobID) {
                            $0.stage = "\(p.stage)"
                            $0.step = p.step
                            $0.totalSteps = p.totalSteps
                        }
                    }
                }
                let paths: [String]
                if isVideo {
                    await jobs.update(jobID) { $0.stage = "Assembling video"; $0.step = nil }
                    let fps = result.media.frameRate ?? 16
                    let out = try await VideoOutput.write(
                        frames: result.images, frameRate: fps, audio: result.audio.first,
                        jobID: jobID, into: outDir)
                    paths = [out.video, out.poster]
                    await jobs.update(jobID) {
                        $0.note = "\($0.note ?? ""), \(result.images.count) frames at \(fps) fps; outputs are [video.mp4, first_frame.png]"
                    }
                } else {
                    paths = try OutputManager.writeImages(result.images, jobID: jobID, into: outDir)
                }
                await jobs.update(jobID) { $0.outputs = paths; $0.status = .completed }
            } catch is CancellationError {
                await jobs.update(jobID) { $0.status = .cancelled }
            } catch {
                await jobs.update(jobID) {
                    $0.error = Self.describe(error)
                    $0.status = .failed
                }
            }
        }
        tail = task
        await jobs.attach(task: task, to: jobID)
        return await jobs.get(jobID) ?? job
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? DrawThingsError, case .incompleteResponse = e {
            return "The server returned no image. This usually means the sampler, steps, guidance or shift don't suit the model. Try the model's recommended settings."
        }
        return error.localizedDescription
    }
}
