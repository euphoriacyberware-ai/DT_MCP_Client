import Foundation

public enum JobStatus: String, Codable, Sendable {
    case queued, running, completed, failed, cancelled

    public var isFinished: Bool { self == .completed || self == .failed || self == .cancelled }
}

public struct Job: Codable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var status: JobStatus
    public var stage: String?
    public var step: Int?
    public var totalSteps: Int?
    public var outputs: [String]
    public var error: String?
    /// Extra facts about the inputs, e.g. canvas size, strength and mask coverage.
    public var note: String?
    public var prompt: String
    public var model: String
    public var seed: UInt32?
    public var createdAt: Date
    public var finishedAt: Date?
    public var durationSeconds: Double?
}

/// In-memory record of jobs for agents to poll, plus the tasks needed to cancel them.
public actor JobStore {
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private let maxJobs: Int

    /// Called on every change so the UI can refresh.
    public var onChange: (@Sendable (Job) -> Void)?

    public init(maxJobs: Int = 200) { self.maxJobs = maxJobs }

    public func setOnChange(_ f: (@Sendable (Job) -> Void)?) { onChange = f }

    public func create(kind: String, prompt: String, model: String) -> Job {
        let id = "job_" + UUID().uuidString.prefix(8).lowercased()
        let job = Job(
            id: id, kind: kind, status: .queued, stage: nil, step: nil, totalSteps: nil,
            outputs: [], error: nil, note: nil, prompt: prompt, model: model, seed: nil,
            createdAt: Date(), finishedAt: nil, durationSeconds: nil)
        jobs[id] = job
        order.append(id)
        trim()
        onChange?(job)
        return job
    }

    public func attach(task: Task<Void, Never>, to id: String) { tasks[id] = task }

    public func get(_ id: String) -> Job? { jobs[id] }

    public func list(limit: Int = 20) -> [Job] {
        order.suffix(limit).reversed().compactMap { jobs[$0] }
    }

    public func update(_ id: String, _ change: (inout Job) -> Void) {
        guard var job = jobs[id] else { return }
        // A finished job never goes back to running (e.g. a late progress event after cancel).
        let wasFinished = job.status.isFinished
        change(&job)
        if wasFinished { return }
        if job.status.isFinished {
            job.finishedAt = Date()
            job.durationSeconds = job.finishedAt!.timeIntervalSince(job.createdAt)
        }
        jobs[id] = job
        onChange?(job)
        if job.status.isFinished {
            tasks[id] = nil
            for w in waiters.removeValue(forKey: id) ?? [] { w.resume() }
        }
    }

    /// Cancels a queued or running job. Returns false if unknown or already finished.
    @discardableResult
    public func cancel(_ id: String) -> Bool {
        guard let job = jobs[id], !job.status.isFinished else { return false }
        tasks[id]?.cancel()
        update(id) { $0.status = .cancelled }
        return true
    }

    /// Waits until the job finishes or `timeout` elapses; returns the latest state.
    public func wait(_ id: String, timeout: Duration) async -> Job? {
        guard let job = jobs[id] else { return nil }
        if job.status.isFinished { return job }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.wake(id)
        }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
        timer.cancel()
        return jobs[id]
    }

    private func wake(_ id: String) {
        for w in waiters.removeValue(forKey: id) ?? [] { w.resume() }
    }

    private func trim() {
        while order.count > maxJobs, let oldest = order.first {
            guard jobs[oldest]?.status.isFinished ?? true else { break }
            order.removeFirst()
            jobs[oldest] = nil
        }
    }
}
