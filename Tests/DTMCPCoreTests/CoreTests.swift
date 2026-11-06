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
