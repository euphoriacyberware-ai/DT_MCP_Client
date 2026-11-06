import Foundation
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
