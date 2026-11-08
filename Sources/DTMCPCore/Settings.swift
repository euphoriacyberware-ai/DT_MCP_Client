import Foundation

/// How to reach the Draw Things gRPC server. The shared secret is kept in the Keychain, not here.
public struct DrawThingsEndpointSettings: Codable, Sendable, Equatable {
    public var host: String = "127.0.0.1"
    public var port: Int = 7859
    public var useTLS: Bool = true
    public init() {}
}

public struct MCPServerSettings: Codable, Sendable, Equatable {
    public var port: Int = 8765
    public var autostart: Bool = true
    public init() {}
}

/// Limits applied to every agent request so a small model can't ask for something absurd.
public struct Guardrails: Codable, Sendable, Equatable {
    public var maxPixels: Int = 2048 * 2048
    public var maxSteps: Int = 80
    public var maxBatchCount: Int = 8
    public var maxFrames: Int = 362
    /// Upper bound for the estimated memory of upscaling/interpolating a video.
    public var maxProcessingMemoryMB: Int = 6144
    public init() {}

    // Tolerant decoding: settings saved by an older version lack newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Guardrails()
        maxPixels = try c.decodeIfPresent(Int.self, forKey: .maxPixels) ?? d.maxPixels
        maxSteps = try c.decodeIfPresent(Int.self, forKey: .maxSteps) ?? d.maxSteps
        maxBatchCount = try c.decodeIfPresent(Int.self, forKey: .maxBatchCount) ?? d.maxBatchCount
        maxFrames = try c.decodeIfPresent(Int.self, forKey: .maxFrames) ?? d.maxFrames
        maxProcessingMemoryMB = try c.decodeIfPresent(Int.self, forKey: .maxProcessingMemoryMB) ?? d.maxProcessingMemoryMB
    }

    public enum Violation: Error, LocalizedError {
        case tooLarge(String)
        public var errorDescription: String? {
            switch self { case .tooLarge(let m): return "Request exceeds the limits set by the user: \(m)" }
        }
    }

    public func check(width: Int, height: Int, steps: Int, batchCount: Int) throws {
        if width * height > maxPixels {
            throw Violation.tooLarge("\(width)x\(height) is more than \(maxPixels) pixels")
        }
        if steps > maxSteps { throw Violation.tooLarge("steps \(steps) > max \(maxSteps)") }
        if batchCount > maxBatchCount {
            throw Violation.tooLarge("batch_count \(batchCount) > max \(maxBatchCount)")
        }
    }
}

/// Values used when an agent omits a parameter.
public struct GenerationDefaults: Codable, Sendable, Equatable {
    public var model: String = "z_image_turbo_1.0_q8p.ckpt"
    public var sampler: String = "unipctrailing"
    public var width: Int = 1024
    public var height: Int = 1024
    public var steps: Int = 8
    public var guidanceScale: Double = 1.0
    public var shift: Double = 3.0
    public init() {}
}
