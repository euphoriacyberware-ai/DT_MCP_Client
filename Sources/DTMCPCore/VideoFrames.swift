import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

public enum VideoFramesError: Error, LocalizedError {
    case noVideoTrack(String)
    case readFailed(String)
    case indexOutOfRange(Int, Int)
    case tooManyIndices(Int)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack(let p): return "'\(p)' has no video track. Pass an .mp4 video file."
        case .readFailed(let m): return "Could not read frames from the video: \(m)"
        case .indexOutOfRange(let i, let n):
            return "Frame \(i) does not exist; the video has \(n) frames (numbered from 0)."
        case .tooManyIndices(let n): return "Asked for \(n) separate frames; the limit is \(VideoFrames.maxIndices). Use \"all\" for a folder of every frame."
        }
    }
}

/// Which frames of a video to pull out.
public enum FrameSelection: Sendable, Equatable {
    case first
    case last
    case indices([Int])
    case all
}

public struct VideoInfo: Sendable {
    public var width: Int
    public var height: Int
    /// Estimated from duration and nominal frame rate; exact counts come from decoding.
    public var frameCount: Int
    public var frameRate: Double
    public var duration: Double
    public var hasAudio: Bool
}

/// Reads frames back out of an MP4. DrawThingsVideoKit only writes video, so this is ours.
public enum VideoFrames {
    public static let maxIndices = 64

    public static func info(of url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw VideoFramesError.noVideoTrack(url.lastPathComponent)
        }
        let size = try await track.load(.naturalSize)
        let fps = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds
        let audio = (try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false
        let rate = fps > 0 ? fps : 16
        return VideoInfo(
            width: Int(size.width.rounded()), height: Int(size.height.rounded()),
            frameCount: max(Int((rate * duration).rounded()), 1), frameRate: rate,
            duration: duration, hasAudio: audio)
    }

    /// Decodes the requested frames. Returns (frame number, image) pairs in order, plus the total
    /// number of frames in the file. Frames that are not requested are decoded but not kept.
    public static func read(
        _ url: URL, selection: FrameSelection
    ) async throws -> (frames: [(index: Int, image: CGImage)], total: Int) {
        if case .indices(let list) = selection, list.count > maxIndices {
            throw VideoFramesError.tooManyIndices(list.count)
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw VideoFramesError.noVideoTrack(url.lastPathComponent)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard reader.canAdd(output) else { throw VideoFramesError.readFailed("unsupported video format") }
        reader.add(output)
        guard reader.startReading() else {
            throw VideoFramesError.readFailed(reader.error?.localizedDescription ?? "could not start reading")
        }
        let wanted: Set<Int>? = {
            switch selection {
            case .first: return [0]
            case .indices(let l): return Set(l)
            case .last, .all: return nil
            }
        }()

        var kept: [(index: Int, image: CGImage)] = []
        var latest: (index: Int, image: CGImage)?
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let i = count
            count += 1
            switch selection {
            case .all:
                if let img = cgImage(from: buffer) { kept.append((i, img)) }
            case .last:
                latest = cgImage(from: buffer).map { (i, $0) }
            case .first, .indices:
                if wanted?.contains(i) == true, let img = cgImage(from: buffer) { kept.append((i, img)) }
            }
        }
        if reader.status == .failed {
            throw VideoFramesError.readFailed(reader.error?.localizedDescription ?? "decode error")
        }
        if case .last = selection, let l = latest { kept = [l] }

        if case .indices(let list) = selection {
            if let bad = list.first(where: { $0 < 0 || $0 >= count }) {
                throw VideoFramesError.indexOutOfRange(bad, count)
            }
            kept.sort { $0.index < $1.index }
        }
        return (kept, count)
    }

    /// BGRA pixel buffer to an independent CGImage (the pixel data is copied).
    static func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard
            let ctx = CGContext(
                data: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: info)
        else { return nil }
        return ctx.makeImage()
    }
}
