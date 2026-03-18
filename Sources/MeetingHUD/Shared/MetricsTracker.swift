import Foundation

/// Tracks app resource usage for display in the HUD.
@Observable @MainActor
final class MetricsTracker {
    /// Current app memory usage in bytes.
    private(set) var memoryUsage: UInt64 = 0

    /// Formatted memory string.
    var memoryString: String {
        formatBytes(memoryUsage)
    }

    /// Total tokens sent to Claude CLI (estimated from character count).
    private(set) var claudeTokensEstimate: Int = 0

    /// Number of Claude API calls made this session.
    private(set) var claudeCallCount: Int = 0

    /// Number of local MLX inference calls this session.
    private(set) var mlxCallCount: Int = 0

    private var timer: Task<Void, Never>?

    func start() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateMemory()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func recordClaudeCall(inputChars: Int, outputChars: Int) {
        claudeCallCount += 1
        // Rough estimate: ~4 chars per token
        claudeTokensEstimate += (inputChars + outputChars) / 4
    }

    func recordMLXCall() {
        mlxCallCount += 1
    }

    func reset() {
        claudeTokensEstimate = 0
        claudeCallCount = 0
        mlxCallCount = 0
    }

    private func updateMemory() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            memoryUsage = info.resident_size
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}
