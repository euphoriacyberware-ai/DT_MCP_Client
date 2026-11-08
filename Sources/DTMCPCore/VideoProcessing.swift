import CoreGraphics
import DrawThingsVideoKit
import Foundation

public struct VideoProcessOptions: Sendable {
    public var upscale: Int?
    public var interpolate: Int?
    public var frameRate: Int?
    public var keepAudio = true
    public init(upscale: Int? = nil, interpolate: Int? = nil, frameRate: Int? = nil, keepAudio: Bool = true) {
        self.upscale = upscale; self.interpolate = interpolate; self.frameRate = frameRate; self.keepAudio = keepAudio
    }
}

public enum VideoProcessError: Error, LocalizedError {
    case badFactor(String, Int)
    case nothingToDo
    case tooMuchMemory(Int, Int)
    case noFrameRate
    case notVideoOrFolder(String)
    case emptySource(String)

    public var errorDescription: String? {
        switch self {
        case .badFactor(let n, let v): return "\(n) must be 2, 3 or 4 (got \(v))."
        case .nothingToDo:
            return "Nothing to do: give at least one of upscale_factor, interpolate_factor or frame_rate."
        case .tooMuchMemory(let need, let limit):
            return "This would need about \(need) MB of memory, more than the user's limit of \(limit) MB. Use a smaller factor, a shorter clip, or ask the user to raise the limit."
        case .noFrameRate:
            return "This frames folder does not record a frame rate. Pass frame_rate."
        case .notVideoOrFolder(let p): return "'\(p)' is neither a video file nor a frames folder."
        case .emptySource(let p): return "'\(p)' contains no frames."
        }
    }
}

public enum VideoProcessing {
    public static let factors = 2...4

    /// Rough peak memory in MB: the decoded source frames, the upscaled copy and the interpolated copy
    /// can all be alive at once (BGRA, 4 bytes a pixel).
    public static func estimateMemoryMB(frames: Int, width: Int, height: Int, upscale: Int, interpolate: Int) -> Int {
        let up = max(upscale, 1), f = max(interpolate, 1)
        let src = Double(frames) * Double(width) * Double(height) * 4
        let upFrames = Double(frames) * Double(width * up) * Double(height * up) * 4
        let outFrames = f > 1 ? Double((frames - 1) * f + 1) : Double(frames)
        let outBytes = outFrames * Double(width * up) * Double(height * up) * 4
        let total = src + (up > 1 ? upFrames : 0) + (f > 1 ? outBytes : 0)
        return Int((total / 1_048_576).rounded(.up))
    }

    /// Processes a video (or frames folder) into a new MP4. Returns a one-line summary of what ran,
    /// including which engine did the upscaling and interpolation.
    public static func process(
        source: URL, output: URL, options: VideoProcessOptions, maxMemoryMB: Int,
        preferredUpscale: SuperResolutionMethod? = nil,
        preferredInterpolation: InterpolationMethod? = nil,
        progress: @escaping @Sendable (String, Double) -> Void
    ) async throws -> String {
        for (name, v) in [("upscale_factor", options.upscale), ("interpolate_factor", options.interpolate)] {
            if let v, !factors.contains(v) { throw VideoProcessError.badFactor(name, v) }
        }
        if let fr = options.frameRate, !(1...240).contains(fr) {
            throw VideoProcessError.badFactor("frame_rate (1-240)", fr)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw VideoProcessError.notVideoOrFolder(source.lastPathComponent)
        }
        let fromFolder = isDir.boolValue
        if !fromFolder, options.upscale == nil, options.interpolate == nil, options.frameRate == nil {
            throw VideoProcessError.nothingToDo
        }

        // Describe the source and check memory before decoding anything.
        var collection: VideoFrameCollection?
        let width: Int, height: Int, count: Int, fps: Int
        var audioURL: URL?
        var audioData: Data?
        if fromFolder {
            guard VideoFrameCollection.exists(at: source) else { throw VideoProcessError.notVideoOrFolder(source.lastPathComponent) }
            let c = try await VideoFrameCollection.load(from: source)
            guard !c.isEmpty, let first = c.cgImage(at: 0) else { throw VideoProcessError.emptySource(source.lastPathComponent) }
            width = first.width; height = first.height; count = c.count
            guard let r = c.metadata.custom["frameRate"].flatMap({ Int($0) }) ?? options.frameRate else {
                throw VideoProcessError.noFrameRate
            }
            fps = r
            if options.keepAudio { audioData = c.audioData?.first }
            collection = c
        } else {
            let info = try await VideoFrames.info(of: source)
            width = info.width; height = info.height; count = info.frameCount
            fps = max(Int(info.frameRate.rounded()), 1)
            if options.keepAudio && info.hasAudio { audioURL = source }
        }
        let need = estimateMemoryMB(
            frames: count, width: width, height: height,
            upscale: options.upscale ?? 1, interpolate: options.interpolate ?? 1)
        guard need <= maxMemoryMB else { throw VideoProcessError.tooMuchMemory(need, maxMemoryMB) }

        // Frame timing: interpolation keeps the duration when the new rate is source x factor.
        let f = options.interpolate ?? 1
        var config = VideoConfiguration(outputURL: output)
        var durationKept = true
        if f > 1 {
            config.sourceFrameRate = fps
            config.frameRate = options.frameRate ?? fps * f
            durationKept = config.frameRate == fps * f
        } else {
            config.sourceFrameRate = options.frameRate ?? fps
            config.frameRate = config.sourceFrameRate
            durationKept = config.sourceFrameRate == fps
        }
        var audioNote = ""
        if durationKept {
            config.audioURL = audioURL
            config.audioData = audioData
        } else if audioURL != nil || audioData != nil {
            audioNote = "; audio dropped because the speed changed"
        }
        if let u = options.upscale { config.superResolution = .enabled(factor: u) }
        if f > 1 { config.interpolation = .enabled(factor: f) }
        config.interpolationMethod = preferredInterpolation
        config.superResolutionMethod = preferredUpscale

        // Engines, so the report says whether ML or the plain fallback ran.
        var engineNotes: [String] = []
        if let u = options.upscale {
            let m = await SuperResolutionScaler(preferredMethod: preferredUpscale).activeMethod
            var s = "upscaled \(u)x (\(m.rawValue))"
            if m != .coreImageLanczos, width > 1920 || height > 1080 {
                s += ", frames over 1920x1080 are resized without ML"
            }
            engineNotes.append(s)
            if case .downloadRequired = SuperResolutionScaler.modelStatus(forWidth: width, height: height, scaleFactor: u) {
                progress("Downloading upscaling model", 0)
                try? await SuperResolutionScaler.downloadModels(forWidth: width, height: height, scaleFactor: u) { p in
                    progress("Downloading upscaling model", Double(p))
                }
            }
        }
        if f > 1 {
            let m = await FrameInterpolator(preferredMethod: preferredInterpolation).activeMethod
            engineNotes.append("interpolated \(f)x (\(m.rawValue))")
        }

        progress("Reading frames", 0)
        let frames: VideoFrameCollection
        if let c = collection {
            frames = VideoFrameCollection(cgImages: c.allCGImages())
        } else {
            let all = try await VideoFrames.read(source, selection: .all)
            frames = VideoFrameCollection(cgImages: all.frames.map(\.image))
        }
        guard !frames.isEmpty else { throw VideoProcessError.emptySource(source.lastPathComponent) }

        _ = try await VideoAssembler(
            preferredInterpolationMethod: preferredInterpolation,
            preferredSuperResolutionMethod: preferredUpscale
        ).assemble(frames: frames, configuration: config) { p in progress("Processing video", p) }

        let after = try await VideoFrames.info(of: output)
        let steps = engineNotes.isEmpty ? "re-timed" : engineNotes.joined(separator: ", ")
        return "\(steps); \(frames.count) source frames at \(fps) fps -> \(after.width)x\(after.height), "
            + "about \(Int(after.frameRate.rounded())) fps, \(String(format: "%.1f", after.duration)) s\(audioNote)"
    }
}
