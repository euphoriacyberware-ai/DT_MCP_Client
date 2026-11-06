import CoreGraphics
import DrawThingsClient
import Foundation

/// Which pixels of an agent-supplied mask image mean "regenerate this area".
public enum MaskMode: String, Sendable, CaseIterable {
    /// White (or light) pixels are regenerated; black pixels are kept. The usual convention.
    case white
    /// Black (or dark) pixels are regenerated.
    case black
    /// Transparent pixels are regenerated (Draw Things' own convention).
    case alpha
}

public enum ImageInputError: Error, LocalizedError {
    case unreadable(String)
    case invalidMode(String)
    case strengthOutOfRange(Double)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let p): return "Could not read '\(p)' as an image (PNG, JPEG or HEIC)."
        case .invalidMode(let m): return "mask_mode '\(m)' is not valid. Use: \(MaskMode.allCases.map(\.rawValue).joined(separator: ", "))."
        case .strengthOutOfRange(let s): return "strength \(s) must be between 0 and 1."
        }
    }
}

public enum ImageInputs {
    /// Loads an image the user has granted access to (EXIF orientation applied).
    static func load(path: String, folders: FolderAccess) async throws -> CGImage {
        let url = try await folders.authorizedReadURL(path)
        do { return try ImageHelpers.loadCGImage(from: url) }
        catch { throw ImageInputError.unreadable(path) }
    }

    /// Picks a canvas size for an init image when the agent gave none: keep the aspect ratio, fit
    /// within `maxPixels`, round to multiples of 64.
    public static func canvasSize(for image: CGImage, maxPixels: Int) -> (width: Int, height: Int) {
        let w = Double(image.width), h = Double(image.height)
        let scale = min(1.0, (Double(maxPixels) / (w * h)).squareRoot())
        func snap(_ v: Double) -> Int { max(64, Int((v * scale / 64).rounded()) * 64) }
        return (snap(w), snap(h))
    }

    /// Resizes the init image to the canvas. Same aspect ratio: plain resize. Different: fit inside
    /// the canvas without distortion.
    static func fit(_ image: CGImage, width: Int, height: Int) -> CGImage {
        if image.width == width && image.height == height { return image }
        let sameRatio = abs(Double(image.width) / Double(image.height) - Double(width) / Double(height)) < 0.02
        if sameRatio, let r = ImageHelpers.resizedImage(image, width: width, height: height) { return r }
        return ImageHelpers.scaledImageToCanvas(image, canvasWidth: width, canvasHeight: height, backgroundColor: nil) ?? image
    }

    /// Converts an agent's mask into the form Draw Things expects: an image the size of the canvas
    /// where transparent pixels are regenerated and opaque pixels are kept.
    public static func drawThingsMask(from mask: CGImage, mode: MaskMode, width: Int, height: Int) throws -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        func context() throws -> CGContext {
            guard let c = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: info)
            else { throw ImageInputError.unreadable("mask") }
            c.interpolationQuality = .none
            return c
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        // White/black masks are flattened onto black so any alpha channel can't leak into the result.
        let src = try context()
        if mode != .alpha {
            src.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            src.fill(rect)
        }
        src.draw(mask, in: rect)
        guard let sp = src.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else {
            throw ImageInputError.unreadable("mask")
        }

        let out = try context()
        guard let op = out.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else {
            throw ImageInputError.unreadable("mask")
        }
        for i in 0..<(width * height) {
            let o = i * 4
            let regenerate: Bool
            switch mode {
            case .alpha: regenerate = sp[o + 3] < 255
            case .white: regenerate = luminance(sp[o], sp[o + 1], sp[o + 2]) >= 128
            case .black: regenerate = luminance(sp[o], sp[o + 1], sp[o + 2]) < 128
            }
            // Premultiplied: transparent = (0,0,0,0); kept = opaque black.
            op[o] = 0; op[o + 1] = 0; op[o + 2] = 0
            op[o + 3] = regenerate ? 0 : 255
        }
        guard let image = out.makeImage() else { throw ImageInputError.unreadable("mask") }
        return image
    }

    /// Fraction of the mask that will be regenerated, for reporting back to the agent.
    public static func regeneratedFraction(_ mask: CGImage) -> Double {
        let w = mask.width, h = mask.height
        guard let c = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let p = { c.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h)); return c.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) }()
        else { return 0 }
        var n = 0
        for i in 0..<(w * h) where p[i * 4 + 3] < 255 { n += 1 }
        return Double(n) / Double(w * h)
    }

    private static func luminance(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
        (299 * Int(r) + 587 * Int(g) + 114 * Int(b)) / 1000
    }
}
