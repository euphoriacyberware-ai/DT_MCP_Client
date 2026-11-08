import Foundation
import DrawThingsClient
import MCP
import Testing

@testable import DTMCPCore

@Suite struct JobStoreTests {
    @Test func lifecycleAndWait() async {
        let store = JobStore()
        let job = await store.create(kind: "image", prompt: "a cat", model: "m")
        #expect(job.status == .queued)

        Task {
            try? await Task.sleep(for: .milliseconds(50))
            await store.update(job.id) { $0.status = .completed; $0.outputs = ["/x.png"] }
        }
        let done = await store.wait(job.id, timeout: .seconds(5))
        #expect(done?.status == .completed)
        #expect(done?.outputs == ["/x.png"])
        #expect(done?.durationSeconds != nil)
    }

    @Test func finishedJobsStayFinished() async {
        let store = JobStore()
        let job = await store.create(kind: "image", prompt: "p", model: "m")
        #expect(await store.cancel(job.id))
        await store.update(job.id) { $0.status = .running }  // late progress event
        #expect(await store.get(job.id)?.status == .cancelled)
        #expect(await store.cancel(job.id) == false)
    }

    @Test func waitTimesOut() async {
        let store = JobStore()
        let job = await store.create(kind: "image", prompt: "p", model: "m")
        let r = await store.wait(job.id, timeout: .milliseconds(50))
        #expect(r?.status == .queued)
    }
}

@Suite struct GuardrailTests {
    @Test func rejectsOversize() {
        let g = Guardrails()
        #expect(throws: Guardrails.Violation.self) {
            try g.check(width: 8192, height: 8192, steps: 8, batchCount: 1)
        }
        #expect(throws: Guardrails.Violation.self) {
            try g.check(width: 512, height: 512, steps: 1000, batchCount: 1)
        }
        #expect(throws: Never.self) { try g.check(width: 1024, height: 1024, steps: 8, batchCount: 1) }
    }
}

@Suite struct MiscTests {
    @Test func outputNaming() {
        let n = OutputManager.fileName(jobID: "job_ab12cd34", index: 0, date: Date(timeIntervalSince1970: 0))
        #expect(n.hasSuffix("_job_ab12cd34_1.png"))
    }

    @Test func samplerNamesResolve() {
        #expect(SamplerNames.map["unipctrailing"] != nil)
        #expect(SamplerNames.all.count == 20)
    }

    @Test func toolsHaveSchemas() {
        let names = MCPToolbox.tools.map(\.name)
        #expect(names.contains("generate_image"))
        #expect(Set(names).count == names.count)
    }

    @Test func tokenIsRandomHex() {
        let a = Keychain.randomToken(), b = Keychain.randomToken()
        #expect(a.count == 64 && a != b)
    }
}

@Suite struct CatalogTests {
    static func catalog() -> ModelCatalog {
        func j(_ s: String) -> Data { Data(s.utf8) }
        var o = MetadataOverride()
        o.models = j("""
            [{"name":"Z Image Turbo","file":"z_image_turbo_1.0_q8p.ckpt","version":"z_image","default_scale":16},
             {"name":"SD 1.5","file":"sd_v1.5_f16.ckpt","version":"v1","default_scale":8},
             {"name":"Old","file":"old.ckpt","version":"v1","deprecated":true},
             {"broken":true}]
            """)
        o.loras = j("""
            [{"name":"Zed Style","file":"zed_lora.ckpt","version":"z_image","prefix":"zedstyle"},
             {"name":"Cartoon","file":"cartoon_lora.ckpt","version":"v1"}]
            """)
        return ModelCatalog.parse(o)
    }

    @Test func parsesAndSkipsBrokenEntries() {
        let c = Self.catalog()
        #expect(c.checkpoints.count == 3)
        #expect(c.loras.count == 2)
    }

    @Test func hidesDeprecatedAndFiltersByQuery() {
        let c = Self.catalog()
        var o = CatalogQuery.Options()
        #expect(CatalogQuery.checkpoints(c, o).total == 2)
        o.includeDeprecated = true
        #expect(CatalogQuery.checkpoints(c, o).total == 3)
        o.query = "turbo"
        #expect(CatalogQuery.checkpoints(c, o).items.first?.native_size == 1024)
    }

    @Test func loraCompatibility() {
        let c = Self.catalog()
        var o = CatalogQuery.Options()
        o.compatibleWith = "z_image_turbo_1.0_q8p.ckpt"
        let page = CatalogQuery.loras(c, o)
        #expect(page.items.map(\.file) == ["zed_lora.ckpt"])
        #expect(page.items.first?.trigger_prefix == "zedstyle")
    }

    @Test func emptyCatalogExplainsBrowsing() {
        let page = CatalogQuery.checkpoints(ModelCatalog(), .init())
        #expect(page.total == 0 && page.hint?.contains("Model Browsing") == true)
    }

    @Test func recommendations() {
        let c = Self.catalog()
        let turbo = ModelPresets.recommend(model: "z_image_turbo_1.0_q8p.ckpt", catalog: c, defaults: .init())
        #expect(turbo.steps == 8 && turbo.native_size == 1024)
        let sd = ModelPresets.recommend(model: "sd_v1.5_f16.ckpt", catalog: c, defaults: .init())
        #expect(sd.sampler == "dpmpp2mkarras" && sd.native_size == 512)
        let other = ModelPresets.recommend(model: "mystery.ckpt", catalog: c, defaults: .init())
        #expect(other.steps == nil && other.sampler == nil && other.user_defaults != nil)
    }
}

// MARK: - img2img / inpaint

import CoreGraphics

@Suite struct ImageInputTests {
    /// Solid-colour test image, optionally with a differently coloured left half.
    static func image(_ w: Int, _ h: Int, left: (UInt8, UInt8, UInt8, UInt8), right: (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        let c = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fill(_ col: (UInt8, UInt8, UInt8, UInt8), _ r: CGRect) {
            c.setFillColor(CGColor(red: CGFloat(col.0) / 255, green: CGFloat(col.1) / 255, blue: CGFloat(col.2) / 255, alpha: CGFloat(col.3) / 255))
            c.fill(r)
        }
        c.clear(CGRect(x: 0, y: 0, width: w, height: h))
        fill(left, CGRect(x: 0, y: 0, width: w / 2, height: h))
        fill(right, CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
        return c.makeImage()!
    }

    @Test func whiteMaskRegeneratesWhiteHalf() throws {
        let m = Self.image(64, 64, left: (255, 255, 255, 255), right: (0, 0, 0, 255))
        let out = try ImageInputs.drawThingsMask(from: m, mode: .white, width: 64, height: 64)
        let f = ImageInputs.regeneratedFraction(out)
        #expect(abs(f - 0.5) < 0.02)
    }

    @Test func blackModeInverts() throws {
        let m = Self.image(64, 64, left: (255, 255, 255, 255), right: (0, 0, 0, 255))
        let out = try ImageInputs.drawThingsMask(from: m, mode: .black, width: 64, height: 64)
        #expect(abs(ImageInputs.regeneratedFraction(out) - 0.5) < 0.02)
    }

    @Test func alphaMaskUsesTransparency() throws {
        let m = Self.image(64, 64, left: (0, 0, 0, 0), right: (0, 0, 0, 255))
        let out = try ImageInputs.drawThingsMask(from: m, mode: .alpha, width: 64, height: 64)
        #expect(abs(ImageInputs.regeneratedFraction(out) - 0.5) < 0.02)
    }

    @Test func maskIsResizedToCanvas() throws {
        let m = Self.image(32, 32, left: (255, 255, 255, 255), right: (255, 255, 255, 255))
        let out = try ImageInputs.drawThingsMask(from: m, mode: .white, width: 128, height: 64)
        #expect(out.width == 128 && out.height == 64)
        #expect(ImageInputs.regeneratedFraction(out) > 0.99)
    }

    @Test func canvasSizeSnapsAndCapsPixels() {
        let big = Self.image(4000, 3000, left: (0, 0, 0, 255), right: (0, 0, 0, 255))
        let s = ImageInputs.canvasSize(for: big, maxPixels: 1024 * 1024)
        #expect(s.width % 64 == 0 && s.height % 64 == 0)
        #expect(s.width * s.height <= 1100 * 1100 && s.width > s.height)
        let small = Self.image(300, 200, left: (0, 0, 0, 255), right: (0, 0, 0, 255))
        let t = ImageInputs.canvasSize(for: small, maxPixels: 1024 * 1024)
        #expect(t.width == 320 && t.height == 192)  // not upscaled beyond rounding
    }

    @Test func folderAllowlist() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dtmcp-\(UUID().uuidString)")
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("dtmcp-other-\(UUID().uuidString)")
        for d in [dir, other] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { for d in [dir, other] { try? FileManager.default.removeItem(at: d) } }
        let ok = dir.appendingPathComponent("a.png"), bad = other.appendingPathComponent("b.png")
        for f in [ok, bad] { try Data([0]).write(to: f) }

        let suite = UserDefaults(suiteName: "dtmcp-test-\(UUID().uuidString)")!
        let folders = FolderAccess(defaults: suite)
        try await folders.grant(dir, role: .input)

        _ = try await folders.authorizedReadURL(ok.path)
        await #expect(throws: FolderAccess.AccessError.self) { _ = try await folders.authorizedReadURL(bad.path) }
        // `..` traversal out of a granted folder is rejected.
        let sneaky = dir.path + "/../" + other.lastPathComponent + "/b.png"
        await #expect(throws: FolderAccess.AccessError.self) { _ = try await folders.authorizedReadURL(sneaky) }
        // A sibling whose name merely starts with the granted folder's name is rejected.
        let sibling = URL(fileURLWithPath: dir.path + "-evil")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let f = sibling.appendingPathComponent("c.png"); try Data([0]).write(to: f)
        await #expect(throws: FolderAccess.AccessError.self) { _ = try await folders.authorizedReadURL(f.path) }
    }
}

// MARK: - Video

import AVFoundation

@Suite struct VideoTests {
    @Test func imageModelsAreRecognised() {
        #expect(VideoOutput.isKnownImageModel("z_image_turbo_1.0_q8p.ckpt", version: "z_image"))
        #expect(VideoOutput.isKnownImageModel("sd_v1.5_f16.ckpt", version: "v1"))
        #expect(!VideoOutput.isKnownImageModel("wan_v2.2_a14b_hne_t2v_q8p.ckpt", version: nil))
        #expect(!VideoOutput.isKnownImageModel("brand_new_model.ckpt", version: nil))  // unknown passes through
    }

    @Test func assemblesMP4AndPoster() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dtmcp-vid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let frames = (0..<12).map { i in
            ImageInputTests.image(128, 128, left: (UInt8(i * 20), 40, 80, 255), right: (200, UInt8(i * 10), 0, 255))
        }
        let out = try await VideoOutput.write(frames: frames, frameRate: 16, audio: nil, jobID: "job_test", into: dir)
        #expect(out.video.hasSuffix(".mp4") && out.poster.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: out.poster))

        let asset = AVURLAsset(url: URL(fileURLWithPath: out.video))
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 12.0 / 16.0) < 0.2)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
    }

    @Test func singleFrameIsNotAVideo() async {
        let dir = FileManager.default.temporaryDirectory
        let one = [ImageInputTests.image(64, 64, left: (0, 0, 0, 255), right: (0, 0, 0, 255))]
        await #expect(throws: VideoOutputError.self) {
            _ = try await VideoOutput.write(frames: one, frameRate: 16, audio: nil, jobID: "x", into: dir)
        }
    }

    @Test func videoToolRegistered() {
        let t = MCPToolbox.tools.first { $0.name == "generate_video" }
        #expect(t != nil)
    }
}

// MARK: - ControlNet

@Suite struct ControlTests {
    @Test func infersHintTypeFromFileName() {
        #expect(ControlHints.infer(from: "controlnet_depth_sdxl_f16.ckpt") == "depth")
        #expect(ControlHints.infer(from: "control_openpose_sd15.ckpt") == "pose")
        #expect(ControlHints.infer(from: "xinsir_canny_sdxl.ckpt") == "canny")
        #expect(ControlHints.infer(from: "t2i_adapter_softedge.ckpt") == "softedge")  // not "canny"/"depth"
        #expect(ControlHints.infer(from: "mystery_net.ckpt") == nil)
    }

    static func catalog() -> ModelCatalog {
        var o = MetadataOverride()
        o.models = Data(#"[{"name":"SD","file":"sd.ckpt","version":"v1","default_scale":8}]"#.utf8)
        o.controlNets = Data(#"[{"name":"Depth","file":"depth_sd15.ckpt","version":"v1"},{"name":"XL","file":"depth_xl.ckpt","version":"sdxl_base_v0.9"}]"#.utf8)
        return ModelCatalog.parse(o)
    }

    @Test func validation() throws {
        let c = Self.catalog()
        func ctl(_ f: String, hint: String = "depth") -> ControlInput { ControlInput(file: f, imagePath: "/x.png", hintType: hint) }

        try ControlHints.validate(ctl("depth_sd15.ckpt"), model: "sd.ckpt", catalog: c)
        #expect(throws: ControlInputError.self) { try ControlHints.validate(ctl("nope.ckpt"), model: "sd.ckpt", catalog: c) }
        #expect(throws: ControlInputError.self) { try ControlHints.validate(ctl("depth_xl.ckpt"), model: "sd.ckpt", catalog: c) }
        #expect(throws: ControlInputError.self) { try ControlHints.validate(ctl("depth_sd15.ckpt", hint: "bogus"), model: "sd.ckpt", catalog: c) }
        // Server lists models but no ControlNets at all: any control is rejected.
        var noNets = MetadataOverride()
        noNets.models = Data(#"[{"name":"SD","file":"sd.ckpt","version":"v1"}]"#.utf8)
        #expect(throws: ControlInputError.self) {
            try ControlHints.validate(ctl("depth_sd15.ckpt"), model: "sd.ckpt", catalog: ModelCatalog.parse(noNets))
        }
        // Model browsing off: can't verify, so allow.
        try ControlHints.validate(ctl("anything.ckpt"), model: "sd.ckpt", catalog: ModelCatalog())

        var bad = ctl("depth_sd15.ckpt"); bad.guidanceStart = 0.8; bad.guidanceEnd = 0.2
        #expect(throws: ControlInputError.self) { try ControlHints.validate(bad, model: "sd.ckpt", catalog: c) }
        var heavy = ctl("depth_sd15.ckpt"); heavy.weight = 5
        #expect(throws: ControlInputError.self) { try ControlHints.validate(heavy, model: "sd.ckpt", catalog: c) }
    }

    @Test func toolRejectsMalformedControls() async {
        let box = MCPToolbox(manager: GenerationManager(jobs: JobStore(), folders: FolderAccess(defaults: UserDefaults(suiteName: "dtmcp-\(UUID().uuidString)")!)))
        let missing = await box.call("generate_image", ["prompt": "x", "controls": .array([.object(["file": "a.ckpt"])])])
        #expect(missing.isError == true)
        let noHint = await box.call("generate_image", ["prompt": "x", "controls": .array([.object(["file": "mystery.ckpt", "image": "/x.png"])])])
        #expect(noHint.isError == true)
        if case .text(let t, _, _) = noHint.content.first { #expect(t.contains("hint_type")) }
        let badMode = await box.call("generate_image", ["prompt": "x", "controls": .array([.object(["file": "depth.ckpt", "image": "/x.png", "mode": "wild"])])])
        if case .text(let t, _, _) = badMode.content.first { #expect(t.contains("mode")) }
        let video = await box.call("generate_video", ["prompt": "x", "model": "wan.ckpt", "num_frames": 33, "controls": .array([])])
        if case .text(let t, _, _) = video.content.first { #expect(t.contains("not supported")) }
    }
}

// MARK: - Skill

@Suite struct SkillTests {
    @Test func bundledSkillHasFrontmatter() throws {
        let text = try SkillExporter.skillText()
        #expect(text.hasPrefix("---\nname: drawthings-mcp\n"))
        #expect(text.contains("description:"))
    }

    /// Every tool the server offers should be mentioned in the skill, so agents learn about it.
    @Test func skillMentionsEveryTool() throws {
        let text = try SkillExporter.skillText()
        for tool in MCPToolbox.tools { #expect(text.contains(tool.name), "skill does not mention \(tool.name)") }
    }

    /// Argument names used in the skill's recipes must exist in the tool schemas.
    @Test func recipeArgumentsExist() throws {
        let text = try SkillExporter.skillText()
        let image = MCPToolbox.tools.first { $0.name == "generate_image" }!
        let video = MCPToolbox.tools.first { $0.name == "generate_video" }!
        func props(_ t: Tool) -> Set<String> {
            guard case .object(let o) = t.inputSchema, case .object(let p)? = o["properties"] else { return [] }
            return Set(p.keys)
        }
        for arg in ["init_image", "mask_image", "mask_mode", "strength", "controls", "upscaler", "width", "height"] {
            #expect(text.contains(arg) && props(image).contains(arg), "\(arg)")
        }
        for arg in ["num_frames", "init_image", "loras", "shift_for_audio", "config_json"] {
            #expect(props(video).contains(arg), "\(arg)")
        }
        for arg in ["loras", "shift_for_audio", "config_json"] {
            #expect(props(image).contains(arg) && text.contains(arg), "\(arg)")
        }
        for arg in ["save_last_frame", "save_frames"] { #expect(props(video).contains(arg) && text.contains(arg), "\(arg)") }
        let process = MCPToolbox.tools.first { $0.name == "process_video" }!
        let extract = MCPToolbox.tools.first { $0.name == "extract_frames" }!
        for arg in ["source", "upscale_factor", "interpolate_factor", "frame_rate", "keep_audio"] {
            #expect(props(process).contains(arg) && text.contains(arg), "\(arg)")
        }
        for arg in ["video", "frames"] { #expect(props(extract).contains(arg), "\(arg)") }
    }

    @Test func exportsAndReplaces() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dtmcp-skill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try SkillExporter.export(to: dir)
        try "stale".write(to: a.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        let b = try SkillExporter.export(to: dir)  // second export replaces the first
        #expect(FileManager.default.fileExists(atPath: b.appendingPathComponent("SKILL.md").path))
        #expect(!FileManager.default.fileExists(atPath: b.appendingPathComponent("old.txt").path))
    }
}


// MARK: - Draw Things configuration JSON

@Suite struct ConfigJSONTests {
    /// A "Copy Configuration" export for a video model, as pasted by a user.
    static let videoConfig = """
    {"strength":1,"batchCount":1,"seed":868670200,"loras":[{"mode":"all","file":"turbo_lora_f16.ckpt","weight":0.6}],\
    "model":"video_model_q8p.ckpt","width":1024,"height":576,"upscaler":"","numFrames":226,"guidanceScale":1,\
    "shiftForAudio":3,"shift":6.5,"steps":6,"seedMode":2,"sampler":16,"tiledDecoding":true,"decodingTileWidth":256,\
    "teaCache":false,"faceRestoration":"","refinerModel":""}
    """

    @Test func samplerAcceptsNamesAndNumbers() {
        #expect(SamplerNames.resolve("ddimtrailing") == .ddimtrailing)
        #expect(SamplerNames.resolve("16") == .ddimtrailing)
        #expect(SamplerNames.resolve("DPMPP2MKarras") == .dpmpp2mkarras)
        #expect(SamplerNames.resolve("99") == nil)
        #expect(SamplerNames.resolve("nonsense") == nil)
        #expect(SamplerNames.name(of: .unipctrailing) == "unipctrailing")
    }

    @Test func overlayKeepsDefaultsForMissingKeys() throws {
        var base = DrawThingsConfiguration()
        base.steps = 30
        base.guidanceScale = 6
        try base.mergeJSON(#"{"steps": 8, "sampler": 17}"#)
        #expect(base.steps == 8)
        #expect(base.guidanceScale == 6)
        #expect(base.sampler == .unipctrailing)
    }

    @Test func parsesVideoConfig() throws {
        var base = DrawThingsConfiguration()
        try base.mergeJSON(Self.videoConfig)
        #expect(base.sampler == .ddimtrailing)
        #expect(base.numFrames == 226)
        #expect(base.shiftForAudio == 3)
        #expect(base.shift == 6.5)
        #expect(base.loras.count == 1 && base.loras[0].file == "turbo_lora_f16.ckpt")
        #expect(abs(base.loras[0].weight - 0.6) < 0.001)
        #expect(base.upscaler == nil)
        #expect(base.seed == 868_670_200)
    }

    @Test func rejectsUnknownSamplerNumber() {
        var base = DrawThingsConfiguration()
        #expect(throws: (any Error).self) { try base.mergeJSON(#"{"sampler": 99}"#) }
    }
}

// MARK: - Video post-processing

import DrawThingsVideoKit

@Suite struct VideoProcessingTests {
    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dtmcp-vp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// 16-bit mono 8 kHz WAV of a quiet tone.
    static func wav(seconds: Double) -> Data {
        let rate = 8000, n = Int(seconds * Double(rate))
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + n * 2); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(n * 2)
        for i in 0..<n { u16(Int(UInt16(bitPattern: Int16(2000 * sin(Double(i) * 0.1))))) }
        return d
    }

    /// A real MP4 of `count` frames whose colour changes frame to frame.
    static func makeVideo(in dir: URL, count: Int = 12, fps: Int = 16, audio: Bool = false) async throws -> URL {
        let url = dir.appendingPathComponent("src-\(UUID().uuidString.prefix(4)).mp4")
        let frames = (0..<count).map { i in
            ImageInputTests.image(128, 96, left: (UInt8(i * 20), 40, 80, 255), right: (200, UInt8(i * 10), 0, 255))
        }
        let cfg = VideoConfiguration(
            outputURL: url, sourceFrameRate: fps, frameRate: fps,
            audioData: audio ? wav(seconds: Double(count) / Double(fps)) : nil)
        _ = try await VideoAssembler().assemble(frames: VideoFrameCollection(cgImages: frames), configuration: cfg)
        return url
    }

    static func process(_ src: URL, _ opts: VideoProcessOptions, limit: Int = 4096) async throws -> (URL, String) {
        let out = src.deletingLastPathComponent().appendingPathComponent("out-\(UUID().uuidString.prefix(4)).mp4")
        let note = try await VideoProcessing.process(
            source: src, output: out, options: opts, maxMemoryMB: limit,
            preferredUpscale: .coreImageLanczos, preferredInterpolation: .coreImageDissolve
        ) { _, _ in }
        return (out, note)
    }

    @Test func extractsFirstLastAndIndices() async throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let v = try await Self.makeVideo(in: dir)
        let first = try await VideoFrames.read(v, selection: .first)
        #expect(first.frames.count == 1 && first.frames[0].index == 0 && first.total == 12)
        let last = try await VideoFrames.read(v, selection: .last)
        #expect(last.frames.count == 1 && last.frames[0].index == 11)
        let some = try await VideoFrames.read(v, selection: .indices([5, 3]))
        #expect(some.frames.map(\.index) == [3, 5])
        let all = try await VideoFrames.read(v, selection: .all)
        #expect(all.frames.count == 12)
        #expect(all.frames[0].image.width == 128 && all.frames[0].image.height == 96)
    }

    @Test func outOfRangeFrameIsReported() async throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let v = try await Self.makeVideo(in: dir)
        await #expect(throws: VideoFramesError.self) { _ = try await VideoFrames.read(v, selection: .indices([99])) }
    }

    @Test func interpolationKeepsDurationAndAddsFrames() async throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let v = try await Self.makeVideo(in: dir)
        let (out, note) = try await Self.process(v, VideoProcessOptions(interpolate: 2))
        let after = try await VideoFrames.read(out, selection: .all)
        #expect(after.total == 23)  // (12 - 1) * 2 + 1
        let info = try await VideoFrames.info(of: out)
        #expect(abs(info.duration - 12.0 / 16.0) < 0.15)
        #expect(note.contains("interpolated 2x") && note.contains("coreImageDissolve"))
    }

    @Test func upscaleDoublesSize() async throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let v = try await Self.makeVideo(in: dir)
        let (out, note) = try await Self.process(v, VideoProcessOptions(upscale: 2))
        let info = try await VideoFrames.info(of: out)
        #expect(info.width == 256 && info.height == 192)
        #expect(note.contains("coreImageLanczos") && note.contains("256x192"))
    }

    @Test func retimingChangesSpeed() async throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let v = try await Self.makeVideo(in: dir)
        let (out, _) = try await Self.process(v, VideoProcessOptions(frameRate: 8))
        let info = try await VideoFrames.info(of: out)
        #expect(abs(info.duration - 12.0 / 8.0) < 0.2)
    }

    @Test func audioIsKeptUnlessSpeedChanges() async throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let v = try await Self.makeVideo(in: dir, audio: true)
        #expect(try await VideoFrames.info(of: v).hasAudio)
        let (kept, _) = try await Self.process(v, VideoProcessOptions(interpolate: 2))
        #expect(try await VideoFrames.info(of: kept).hasAudio)
        let (dropped, note) = try await Self.process(v, VideoProcessOptions(frameRate: 8))
        #expect(!(try await VideoFrames.info(of: dropped).hasAudio))
        #expect(note.contains("audio dropped"))
    }

    @Test func framesFolderRoundTrip() async throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let v = try await Self.makeVideo(in: dir)
        let all = try await VideoFrames.read(v, selection: .all)
        let folder = dir.appendingPathComponent("frames", isDirectory: true)
        try await VideoFrameCollection(
            cgImages: all.frames.map(\.image), metadata: VideoFrameMetadata(custom: ["frameRate": "16"])
        ).save(to: folder, format: .png)
        let (out, _) = try await Self.process(folder, VideoProcessOptions())
        let info = try await VideoFrames.info(of: out)
        #expect(abs(info.duration - 12.0 / 16.0) < 0.15 && info.width == 128)
        // A folder with no recorded rate needs frame_rate.
        let bare = dir.appendingPathComponent("bare", isDirectory: true)
        try await VideoFrameCollection(cgImages: all.frames.map(\.image)).save(to: bare, format: .png)
        await #expect(throws: VideoProcessError.self) { _ = try await Self.process(bare, VideoProcessOptions()) }
        _ = try await Self.process(bare, VideoProcessOptions(frameRate: 12))
    }

    @Test func rejectsBadRequests() async throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let v = try await Self.makeVideo(in: dir)
        await #expect(throws: VideoProcessError.self) { _ = try await Self.process(v, VideoProcessOptions()) }  // nothing to do
        await #expect(throws: VideoProcessError.self) { _ = try await Self.process(v, VideoProcessOptions(upscale: 5)) }
        await #expect(throws: VideoProcessError.self) { _ = try await Self.process(v, VideoProcessOptions(interpolate: 1)) }
        await #expect(throws: VideoProcessError.self) { _ = try await Self.process(v, VideoProcessOptions(upscale: 4), limit: 1) }
    }

    @Test func memoryEstimateGrowsWithFactors() {
        let base = VideoProcessing.estimateMemoryMB(frames: 100, width: 1024, height: 576, upscale: 1, interpolate: 1)
        let up = VideoProcessing.estimateMemoryMB(frames: 100, width: 1024, height: 576, upscale: 2, interpolate: 1)
        let both = VideoProcessing.estimateMemoryMB(frames: 100, width: 1024, height: 576, upscale: 2, interpolate: 2)
        #expect(base < up && up < both)
        #expect(base == 225)  // 100 frames x 1024 x 576 x 4 bytes
    }

    @Test func frameSelectionParsing() throws {
        #expect(try MCPToolbox.parseSelection(.string("last")) == .last)
        #expect(try MCPToolbox.parseSelection(.string("ALL")) == .all)
        #expect(try MCPToolbox.parseSelection(.int(4)) == .indices([4]))
        #expect(try MCPToolbox.parseSelection(.array([.int(1), .int(2)])) == .indices([1, 2]))
        #expect(throws: (any Error).self) { _ = try MCPToolbox.parseSelection(.string("middle")) }
        #expect(throws: (any Error).self) { _ = try MCPToolbox.parseSelection(nil) }
    }

    @Test func generateVideoOptionalOutputs() async throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let frames = (0..<8).map { i in
            ImageInputTests.image(128, 96, left: (UInt8(i * 30), 0, 0, 255), right: (0, 0, 0, 255))
        }
        let plain = try await VideoOutput.write(frames: frames, frameRate: 16, audio: nil, jobID: "job_a", into: dir)
        #expect(plain.lastFrame == nil && plain.framesFolder == nil)
        let full = try await VideoOutput.write(
            frames: frames, frameRate: 16, audio: nil, jobID: "job_b", into: dir, saveLastFrame: true, saveFrames: true)
        #expect(full.lastFrame.map { FileManager.default.fileExists(atPath: $0) } == true)
        #expect(full.lastFrame?.hasSuffix("_last.png") == true)
        let folder = try #require(full.framesFolder)
        #expect(VideoFrameCollection.exists(at: URL(fileURLWithPath: folder)))
        let info = try await VideoFrameCollection.info(from: URL(fileURLWithPath: folder))
        #expect(info.frameCount == 8 && info.metadata.custom["frameRate"] == "16")
    }

    @Test func oldGuardrailSettingsStillDecode() throws {
        let old = #"{"maxPixels":4194304,"maxSteps":80,"maxBatchCount":8,"maxFrames":129}"#
        let g = try JSONDecoder().decode(Guardrails.self, from: Data(old.utf8))
        #expect(g.maxFrames == 129 && g.maxProcessingMemoryMB == 6144)
    }
}
