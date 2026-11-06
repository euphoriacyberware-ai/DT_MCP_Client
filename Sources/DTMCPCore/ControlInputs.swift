import CoreGraphics
import DrawThingsClient
import DrawThingsKit
import Foundation

/// One ControlNet (or similar control) an agent wants applied, with its already-prepared input map.
public struct ControlInput: Sendable {
    public var file: String
    public var imagePath: String
    public var weight: Double = 1.0
    public var guidanceStart: Double = 0.0
    public var guidanceEnd: Double = 1.0
    public var mode: ControlMode = .balanced
    /// Hint type the control reads: depth, canny, pose, scribble, softedge, lineart, seg, mlsd, tile, ...
    public var hintType: String
}

public enum ControlInputError: Error, LocalizedError {
    case unknownHintType(String)
    case cannotInferHint(String)
    case notInstalled(String)
    case incompatible(control: String, model: String)
    case tooMany(Int)
    case invalidRange(String)
    case invalidMode(String)

    public var errorDescription: String? {
        switch self {
        case .unknownHintType(let t):
            return "hint_type '\(t)' is not valid. Use one of: \(ControlHints.validTypes.joined(separator: ", "))."
        case .cannotInferHint(let f):
            return "Could not tell which kind of map '\(f)' reads from its name. Pass hint_type (e.g. depth, canny, pose, scribble)."
        case .notInstalled(let f):
            return "Control '\(f)' is not installed on the Draw Things server. Call list_controlnets (with compatible_with set to your model) for valid files."
        case .incompatible(let c, let m):
            return "Control '\(c)' was made for a different model family than '\(m)'. Call list_controlnets with compatible_with set to your model."
        case .tooMany(let n): return "\(n) controls requested; at most \(ControlHints.maxControls) are allowed."
        case .invalidRange(let m): return m
        case .invalidMode(let m): return "mode '\(m)' is not valid. Use: balanced, prompt, control."
        }
    }
}

public enum ControlHints {
    public static let maxControls = 4

    public static var validTypes: [String] { HintType.allCases.map(\.rawValue).filter { $0 != "custom" } }

    /// Guesses the hint type from a ControlNet file name. Order matters: more specific names first.
    public static func infer(from file: String) -> String? {
        let f = file.lowercased()
        let table: [(String, [String])] = [
            ("softedge", ["softedge", "soft_edge", "hed", "pidinet"]),
            ("lineart", ["lineart", "line_art"]),
            ("scribble", ["scribble", "sketch"]),
            ("canny", ["canny"]),
            ("depth", ["depth", "midas", "zoe"]),
            ("pose", ["openpose", "pose"]),
            ("seg", ["segment", "_seg"]),
            ("mlsd", ["mlsd"]),
            ("tile", ["tile"]),
            ("shuffle", ["shuffle"]),
            ("ip2p", ["ip2p", "instruct_pix"]),
            ("blur", ["blur"]),
            ("inpaint", ["inpaint"]),
        ]
        for (type, keys) in table where keys.contains(where: f.contains) { return type }
        return nil
    }

    public static func parseMode(_ s: String) throws -> ControlMode {
        switch s.lowercased() {
        case "balanced": return .balanced
        case "prompt": return .prompt
        case "control": return .control
        default: throw ControlInputError.invalidMode(s)
        }
    }

    /// Checks the control against what the server has installed and the chosen model's family.
    /// With an empty catalog (model browsing off) we can't check, so we let the server decide.
    public static func validate(_ c: ControlInput, model: String, catalog: ModelCatalog?) throws {
        guard HintType(rawValue: c.hintType) != nil else { throw ControlInputError.unknownHintType(c.hintType) }
        guard (0...2).contains(c.weight) else { throw ControlInputError.invalidRange("weight must be between 0 and 2.") }
        guard (0...1).contains(c.guidanceStart), (0...1).contains(c.guidanceEnd), c.guidanceStart < c.guidanceEnd else {
            throw ControlInputError.invalidRange("guidance_start and guidance_end must be within 0...1 with start < end.")
        }
        // An entirely empty catalog means model browsing is off and we can't check. Otherwise the
        // control must be installed (an empty ControlNet list then means none are).
        guard let catalog, !catalog.isEmpty else { return }
        guard let net = catalog.controlNets.first(where: { $0.file == c.file }) else {
            throw ControlInputError.notInstalled(c.file)
        }
        if let v = catalog.checkpoint(file: model)?.version,
            !ModelVersionNormalizer.areCompatible(net.version, v)
        {
            throw ControlInputError.incompatible(control: c.file, model: model)
        }
    }
}
