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
}

public enum GenerationError: Error, LocalizedError {
    case notConfigured
    case unknownSampler(String)

    public var errorDescription: String? {
        switch self {
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

    // MARK: Jobs

    /// Validates, registers and enqueues a text-to-image job. Returns immediately with the job.
    public func submitImage(_ params: ImageJobParams) async throws -> Job {
        guard let service else { throw GenerationError.notConfigured }
        guard let sampler = SamplerNames.map[params.sampler.lowercased()] else {
            throw GenerationError.unknownSampler(params.sampler)
        }
        try guardrails.check(
            width: params.width, height: params.height, steps: params.steps,
            batchCount: params.batchCount)
        let outDir = try await folders.outputFolder()

        var seed = params.seed
        if seed == nil { seed = UInt32.random(in: 0...UInt32.max) }

        let job = await jobs.create(kind: "image", prompt: params.prompt, model: params.model)
        await jobs.update(job.id) { $0.seed = seed }

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
        let request = GenerationRequest(
            prompt: params.prompt, negativePrompt: params.negativePrompt, configuration: cfg)

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
                let paths = try OutputManager.writeImages(
                    result.images, jobID: jobID, into: outDir)
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
