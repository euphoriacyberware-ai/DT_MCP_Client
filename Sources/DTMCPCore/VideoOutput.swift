import CoreGraphics
import DrawThingsClient
import DrawThingsVideoKit
import Foundation

public enum VideoOutputError: Error, LocalizedError {
    case notAVideoModel(String)
    case tooManyFrames(Int, Int)
    case noVideoReturned(Int)

    public var errorDescription: String? {
        switch self {
        case .notAVideoModel(let m):
            return "'\(m)' is an image model, not a video model. Call list_models (try query 'wan', 'ltx' or 'hunyuan') to find a video model."
        case .tooManyFrames(let n, let max): return "num_frames \(n) is more than the user's limit of \(max)."
        case .noVideoReturned(let n):
            return "The server returned \(n) frame(s), not a video. Check that the model is a video model and that sampler, steps, guidance and shift suit it."
        }
    }
}

public enum VideoOutput {
    /// True when the model family is known to be an image-only family. Unknown families are allowed
    /// through because new video models appear faster than the family list.
    public static func isKnownImageModel(_ file: String, version: String?) -> Bool {
        let family = ModelFamily.detect(from: version ?? file)
        return family != .unknown && family.nativeFrameRate == nil
    }

    public struct Written: Sendable {
        public var video: String
        public var poster: String
        /// Exact last frame as PNG, when requested.
        public var lastFrame: String?
        /// Folder with every frame as PNG plus a manifest, when requested.
        public var framesFolder: String?
        /// What upscaling / interpolation actually ran, when any was requested.
        public var processingNote: String?
    }

    /// Writes the frames (and the model's audio, if any) to an MP4 and returns its path plus the
    /// path of the first frame as a PNG poster, which lets a vision model check the result cheaply.
    /// Optionally also keeps the exact last frame (for chaining clips) and every frame as a folder.
    public static func write(
        frames: [CGImage], frameRate: Int, audio: GeneratedAudio?, jobID: String, into folder: URL,
        saveLastFrame: Bool = false, saveFrames: Bool = false,
        process: VideoProcessOptions = VideoProcessOptions(),
        preferredUpscale: SuperResolutionMethod? = nil,
        preferredInterpolation: InterpolationMethod? = nil
    ) async throws -> Written {
        for (name, v) in [("upscale_factor", process.upscale), ("interpolate_factor", process.interpolate)] {
            if let v, !VideoProcessing.factors.contains(v) { throw VideoProcessError.badFactor(name, v) }
        }
        if let fr = process.frameRate, !(1...240).contains(fr) {
            throw VideoProcessError.badFactor("frame_rate (1-240)", fr)
        }
        guard frames.count > 1 else { throw VideoOutputError.noVideoReturned(frames.count) }
        let videoName = OutputManager.fileName(jobID: jobID, index: 0, ext: "mp4")
        let videoURL = folder.appendingPathComponent(videoName)
        let posterURL = folder.appendingPathComponent(OutputManager.fileName(jobID: jobID, index: 0, ext: "png"))
        let stem = (videoName as NSString).deletingPathExtension
        let wav = audio?.wavData()
        // Upscaling and interpolation run on the raw frames in the same pass that encodes the MP4,
        // so the video is compressed once. Interpolation keeps the duration unless frame_rate is given.
        var config = VideoConfiguration(
            outputURL: videoURL, sourceFrameRate: frameRate, frameRate: frameRate, audioData: wav)
        let f = process.interpolate ?? 1
        var audioNote = ""
        if f > 1 {
            config.frameRate = process.frameRate ?? frameRate * f
            config.interpolation = .enabled(factor: f)
        } else if let fr = process.frameRate {
            config.sourceFrameRate = fr
            config.frameRate = fr
        }
        let durationKept = f > 1 ? config.frameRate == frameRate * f : config.sourceFrameRate == frameRate
        if !durationKept, wav != nil {
            config.audioData = nil
            audioNote = "; audio dropped because the speed changed"
        }
        if let u = process.upscale { config.superResolution = .enabled(factor: u) }
        config.interpolationMethod = preferredInterpolation
        config.superResolutionMethod = preferredUpscale
        var engines: [String] = []
        if let u = process.upscale {
            let m = await SuperResolutionScaler(preferredMethod: preferredUpscale).activeMethod
            engines.append("upscaled \(u)x (\(m.rawValue))")
            if let first = frames.first, m != .coreImageLanczos, first.width > 1920 || first.height > 1080 {
                engines[engines.count - 1] += ", frames over 1920x1080 are resized without ML"
            }
        }
        if f > 1 {
            let m = await FrameInterpolator(preferredMethod: preferredInterpolation).activeMethod
            engines.append("interpolated \(f)x (\(m.rawValue))")
        }
        _ = try await VideoAssembler(
            preferredInterpolationMethod: preferredInterpolation,
            preferredSuperResolutionMethod: preferredUpscale
        ).assemble(frames: VideoFrameCollection(cgImages: frames), configuration: config)
        try ImageHelpers.saveImage(frames[0], to: posterURL, format: .png)
        var result = Written(video: videoURL.path, poster: posterURL.path)
        if !engines.isEmpty { result.processingNote = engines.joined(separator: ", ") + audioNote }
        if saveLastFrame, let last = frames.last {
            let url = folder.appendingPathComponent("\(stem)_last.png")
            try ImageHelpers.saveImage(last, to: url, format: .png)
            result.lastFrame = url.path
        }
        if saveFrames {
            let dir = folder.appendingPathComponent("\(stem)_frames", isDirectory: true)
            var collection = VideoFrameCollection(
                cgImages: frames, metadata: VideoFrameMetadata(custom: ["frameRate": String(frameRate)]))
            if let wav { collection.audioData = [wav] }
            try await collection.save(to: dir, format: .png)
            result.framesFolder = dir.path
        }
        return result
    }
}
