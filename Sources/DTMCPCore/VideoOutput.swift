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

    /// Writes the frames (and the model's audio, if any) to an MP4 and returns its path plus the
    /// path of the first frame as a PNG poster, which lets a vision model check the result cheaply.
    public static func write(
        frames: [CGImage], frameRate: Int, audio: GeneratedAudio?, jobID: String, into folder: URL
    ) async throws -> (video: String, poster: String) {
        guard frames.count > 1 else { throw VideoOutputError.noVideoReturned(frames.count) }
        let videoURL = folder.appendingPathComponent(OutputManager.fileName(jobID: jobID, index: 0, ext: "mp4"))
        let posterURL = folder.appendingPathComponent(OutputManager.fileName(jobID: jobID, index: 0, ext: "png"))
        let config = VideoConfiguration(
            outputURL: videoURL, sourceFrameRate: frameRate, frameRate: frameRate,
            audioData: audio?.wavData())
        _ = try await VideoAssembler().assemble(
            frames: VideoFrameCollection(cgImages: frames), configuration: config)
        try ImageHelpers.saveImage(frames[0], to: posterURL, format: .png)
        return (videoURL.path, posterURL.path)
    }
}
