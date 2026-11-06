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
