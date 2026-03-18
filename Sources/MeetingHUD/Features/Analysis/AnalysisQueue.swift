import Foundation

/// Serial executor for LLM analysis tasks.
/// MLX is single-GPU, so we must serialize all inference calls.
/// Runs off MainActor so LLM inference (1-5s) doesn't block UI.
actor AnalysisQueue {
    private var pending: [WorkItem] = []
    private var isRunning = false

    /// Maximum backlog before oldest items are evicted.
    private let maxBacklog = 8

    /// Timeout for individual work items (prevents stuck LLM calls from blocking the queue).
    private let itemTimeout: Duration = .seconds(30)

    struct WorkItem {
        let work: @Sendable () async -> Void
    }

    /// Enqueue work to run serially. If backlog is full, drops the oldest pending item.
    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        if pending.count >= maxBacklog {
            pending.removeFirst()
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
            // Timeout guard: don't let a single stuck LLM call block everything
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await item.work() }
                group.addTask {
                    try? await Task.sleep(for: self.itemTimeout)
                }
                // Whichever finishes first — cancel the other
                await group.next()
                group.cancelAll()
            }
        }
        isRunning = false
    }
}
