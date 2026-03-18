import Foundation

/// Serial executor for LLM analysis tasks.
/// MLX is single-GPU, so we must serialize all inference calls.
/// Runs off MainActor so LLM inference (1-5s) doesn't block UI.
actor AnalysisQueue {
    private var pending: [WorkItem] = []
    private var isRunning = false

    /// Maximum backlog before new items are dropped.
    private let maxBacklog = 6

    struct WorkItem {
        let work: @Sendable () async -> Void
    }

    /// Enqueue work to run serially. Drops if backlog exceeds threshold.
    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        guard pending.count < maxBacklog else {
            return
        }
        pending.append(WorkItem(work: work))
        if !isRunning {
            isRunning = true
            Task { await drain() }
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let item = pending.removeFirst()
            await item.work()
        }
        isRunning = false
    }
}
