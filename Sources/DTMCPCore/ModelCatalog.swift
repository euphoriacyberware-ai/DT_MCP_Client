import DrawThingsClient
import DrawThingsKit
import Foundation

/// What the Draw Things server says it has installed (from the echo reply's metadata override).
/// Empty lists usually mean "Enable Model Browsing" is off on the server.
public struct ModelCatalog: Sendable {
    public var checkpoints: [CheckpointModel] = []
    public var loras: [LoRAModel] = []
    public var controlNets: [ControlNetModel] = []
    public var upscalers: [UpscalerModel] = []
    public var fetchedAt = Date()

    public var isEmpty: Bool {
        checkpoints.isEmpty && loras.isEmpty && controlNets.isEmpty && upscalers.isEmpty
    }

    public static func parse(_ o: MetadataOverride) -> ModelCatalog {
        ModelCatalog(
            checkpoints: decodeEach(o.models), loras: decodeEach(o.loras),
            controlNets: decodeEach(o.controlNets), upscalers: decodeEach(o.upscalers))
    }

    /// Decodes a JSON array element by element so one odd entry doesn't hide the rest.
    static func decodeEach<M: Decodable>(_ data: Data) -> [M] {
        guard !data.isEmpty, let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        let decoder = JSONDecoder()
        return array.compactMap { el in
            guard let d = try? JSONSerialization.data(withJSONObject: el) else { return nil }
            return try? decoder.decode(M.self, from: d)
        }
    }

    public func checkpoint(file: String) -> CheckpointModel? { checkpoints.first { $0.file == file } }
}

// MARK: - Agent-facing entries

public struct ModelEntry: Encodable, Sendable {
    public var file: String
    public var name: String
    public var version: String?
    public var family: String
    /// Native square size in pixels for checkpoints (Draw Things stores it in units of 64).
    public var native_size: Int?
    public var trigger_prefix: String?
    public var note: String?
    public var deprecated: Bool?
}

public enum CatalogQuery {
    public struct Options: Sendable {
        public var query: String?
        public var limit: Int = 50
        public var includeDeprecated = false
        /// Checkpoint file; only LoRAs/ControlNets of the same model family are returned.
        public var compatibleWith: String?
        public init() {}
    }

    public struct Page: Encodable, Sendable {
        public var total: Int
        public var returned: Int
        public var items: [ModelEntry]
        public var hint: String?
    }

    static func matches(_ q: String?, _ fields: [String?]) -> Bool {
        guard let q = q?.lowercased(), !q.isEmpty else { return true }
        return fields.contains { $0?.lowercased().contains(q) == true }
    }

    static func page(_ entries: [ModelEntry], _ o: Options, emptyHint: String?) -> Page {
        let limit = min(max(o.limit, 1), 500)
        let shown = Array(entries.prefix(limit))
        var hint: String? = nil
        if entries.isEmpty { hint = emptyHint }
        else if entries.count > shown.count { hint = "Showing \(shown.count) of \(entries.count). Use 'query' to narrow the list." }
        return Page(total: entries.count, returned: shown.count, items: shown, hint: hint)
    }

    static let browsingHint =
        "No entries. If you expected some, the Draw Things server may have 'Enable Model Browsing' turned off, or the filters excluded everything."

    public static func checkpoints(_ c: ModelCatalog, _ o: Options) -> Page {
        let items = c.checkpoints
            .filter { o.includeDeprecated || $0.deprecated != true }
            .filter { matches(o.query, [$0.name, $0.file, $0.version]) }
            .map {
                ModelEntry(
                    file: $0.file, name: $0.name, version: $0.version, family: $0.family.rawValue,
                    native_size: $0.defaultScale.map { $0 * 64 },
                    trigger_prefix: ($0.prefix?.isEmpty ?? true) ? nil : $0.prefix,
                    note: nil, deprecated: $0.deprecated)
            }
        return page(items, o, emptyHint: browsingHint)
    }

    public static func loras(_ c: ModelCatalog, _ o: Options) -> Page {
        let want = compatibleVersion(c, o)
        let items = c.loras
            .filter { matches(o.query, [$0.name, $0.file, $0.version]) }
            .filter { ModelVersionNormalizer.areCompatible($0.version, want) }
            .map {
                ModelEntry(
                    file: $0.file, name: $0.name, version: $0.version,
                    family: ModelFamily.detect(from: $0.version ?? $0.file).rawValue,
                    native_size: nil, trigger_prefix: ($0.prefix?.isEmpty ?? true) ? nil : $0.prefix,
                    note: nil, deprecated: nil)
            }
        return page(items, o, emptyHint: browsingHint)
    }

    public static func controlNets(_ c: ModelCatalog, _ o: Options) -> Page {
        let want = compatibleVersion(c, o)
        let items = c.controlNets
            .filter { o.includeDeprecated || $0.deprecated != true }
            .filter { matches(o.query, [$0.name, $0.file, $0.version]) }
            .filter { ModelVersionNormalizer.areCompatible($0.version, want) }
            .map {
                ModelEntry(
                    file: $0.file, name: $0.name, version: $0.version,
                    family: ModelFamily.detect(from: $0.version ?? $0.file).rawValue,
                    native_size: nil, trigger_prefix: nil, note: nil, deprecated: $0.deprecated)
            }
        return page(items, o, emptyHint: browsingHint)
    }

    public static func upscalers(_ c: ModelCatalog, _ o: Options) -> Page {
        let items = c.upscalers
            .filter { matches(o.query, [$0.name, $0.file]) }
            .map {
                ModelEntry(
                    file: $0.file, name: $0.name, version: nil, family: "upscaler",
                    native_size: nil, trigger_prefix: nil,
                    note: $0.scaleFactor.map { "\($0)x upscale" }, deprecated: nil)
            }
        return page(items, o, emptyHint: browsingHint)
    }

    /// nil means "don't filter by compatibility".
    private static func compatibleVersion(_ c: ModelCatalog, _ o: Options) -> String? {
        guard let f = o.compatibleWith else { return nil }
        return c.checkpoint(file: f)?.version
    }
}

// MARK: - Recommendations

/// Starting-point settings. Draw Things metadata only carries the native size, so sampler, steps
/// and guidance come from this small table; families without an entry fall back to the user's
/// defaults. These are suggestions, not guarantees.
public struct Recommendation: Encodable, Sendable {
    public var model: String
    public var family: String
    public var native_size: Int?
    public var sampler: String?
    public var steps: Int?
    public var guidance_scale: Double?
    public var shift: Double?
    public var source: String
    public var advice: String
    /// Only set when there is no built-in preset. These are the user's own defaults, not a suggestion for this model.
    public var user_defaults: GenerationDefaults?
}

public enum ModelPresets {
    public static func recommend(model file: String, catalog: ModelCatalog, defaults: GenerationDefaults)
        -> Recommendation
    {
        let ckpt = catalog.checkpoint(file: file)
        let family = ModelFamily.detect(from: ckpt?.version ?? file)
        let size = ckpt?.defaultScale.map { $0 * 64 }
        func rec(_ sampler: String?, _ steps: Int?, _ g: Double?, _ shift: Double?, _ src: String, _ advice: String)
            -> Recommendation
        {
            Recommendation(
                model: file, family: family.rawValue, native_size: size, sampler: sampler, steps: steps,
                guidance_scale: g, shift: shift, source: src, advice: advice, user_defaults: nil)
        }
        let lower = file.lowercased()
        switch family {
        case .sd1:
            return rec("dpmpp2mkarras", 25, 7.0, nil, "built-in starting point",
                       "Stay near the native size; larger sizes can duplicate subjects.")
        case .sdxl:
            return rec("dpmpp2mkarras", 30, 6.0, nil, "built-in starting point",
                       "Works best at about 1024x1024.")
        case .zImage where lower.contains("turbo"):
            return rec("unipctrailing", 8, 1.0, 3.0, "DrawThingsClient library defaults",
                       "Turbo models need few steps and guidance near 1.")
        default:
            var r = rec(nil, nil, nil, nil, "no built-in preset for this family",
                        "No verified settings for this model. Use native_size for width/height. Ask the user for the model's recommended sampler, steps, guidance and shift (a wrong combination makes the server return no image), or omit them to use user_defaults.")
            r.user_defaults = defaults
            return r
        }
    }
}
