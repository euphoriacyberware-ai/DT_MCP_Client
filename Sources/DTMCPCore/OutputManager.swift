import CoreGraphics
import DrawThingsClient
import Foundation

public enum OutputManager {
    /// `20261106-153012_job_ab12cd34_1.png`
    public static func fileName(jobID: String, index: Int, date: Date = Date(), ext: String = "png") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: date))_\(jobID)_\(index + 1).\(ext)"
    }

    /// Writes each image as PNG into `folder` (which must already be security-scope accessible)
    /// and returns absolute paths.
    public static func writeImages(_ images: [CGImage], jobID: String, into folder: URL) throws -> [String] {
        var paths: [String] = []
        for (i, image) in images.enumerated() {
            let url = folder.appendingPathComponent(fileName(jobID: jobID, index: i))
            try ImageHelpers.saveImage(image, to: url, format: .png)
            paths.append(url.path)
        }
        return paths
    }
}
