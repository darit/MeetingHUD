import Foundation

/// Claude Code CLI-based LLM provider.
/// Spawns the `claude` CLI as a subprocess, writes the prompt to stdin, reads streaming output.
/// Uses your existing ~/.claude/ credentials — no API key management needed.
/// Haiku is ideal for short analysis prompts (sentiment, topics, signals) — fast and cheap.
/// Sonnet for richer insights (recommendations, summaries).
final class ClaudeCLIProvider: LLMProvider, @unchecked Sendable {

    enum Model: String, Sendable, CaseIterable {
        case haiku
        case sonnet
        case opus
    }

    let model: Model
    /// Callback to record API usage metrics.
    var onCallComplete: ((Int, Int) -> Void)?

    init(model: Model = .haiku) {
        self.model = model
    }

    var displayName: String {
        "Claude \(model.rawValue.capitalized)"
    }

    var contextWindowSize: Int? {
        switch model {
        case .haiku: 200_000
        case .sonnet: 200_000
        case .opus: 200_000
        }
    }

    /// Common install locations for the claude binary.
    private static let searchPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
    }()

    /// Resolve the full path to the claude binary.
    private static func resolvedClaudePath() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isAvailable: Bool {
        get async {
            Self.resolvedClaudePath() != nil
        }
    }

    func stream(messages: [ChatMessage]) async throws -> AsyncStream<String> {
        let (systemPrompt, userPrompt) = Self.splitPrompt(messages: messages)
        let inputChars = systemPrompt.count + userPrompt.count
        let onCall = self.onCallComplete

        guard let claudePath = Self.resolvedClaudePath() else {
            return AsyncStream { continuation in
                continuation.yield("[Error: Claude CLI not found. Install: npm install -g @anthropic-ai/claude-code]")
                continuation.finish()
            }
        }

        return AsyncStream { continuation in
            Task.detached {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: claudePath)
                    var args = ["-p", "--model", self.model.rawValue]
                    if !systemPrompt.isEmpty {
                        args += ["--system-prompt", systemPrompt]
                    }
                    process.arguments = args

                    let inputPipe = Pipe()
                    let outputPipe = Pipe()
                    let errorPipe = Pipe()

                    process.standardInput = inputPipe
                    process.standardOutput = outputPipe
                    process.standardError = errorPipe

                    continuation.onTermination = { _ in
                        if process.isRunning {
                            process.terminate()
                        }
                    }

                    try process.run()

                    // Write user prompt to stdin and close
                    let promptData = userPrompt.data(using: .utf8) ?? Data()
                    inputPipe.fileHandleForWriting.write(promptData)
                    inputPipe.fileHandleForWriting.closeFile()

                    // Read stdout in chunks
                    let handle = outputPipe.fileHandleForReading
                    var data = handle.readData(ofLength: 4096)
                    var outputChars = 0
                    while !data.isEmpty {
                        if let chunk = String(data: data, encoding: .utf8) {
                            continuation.yield(chunk)
                            outputChars += chunk.count
                        }
                        data = handle.readData(ofLength: 4096)
                    }

                    process.waitUntilExit()

                    // Record usage metrics
                    await MainActor.run {
                        onCall?(inputChars, outputChars)
                    }

                    if process.terminationStatus != 0 && process.terminationStatus != 15 {
                        let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
                        continuation.yield("\n[Error: Claude CLI exited \(process.terminationStatus): \(errMsg)]")
                    }

                    continuation.finish()
                } catch {
                    continuation.yield("\n[Error: \(error.localizedDescription)]")
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Message Formatting

    /// Split messages into system prompt (passed via --system-prompt flag)
    /// and user prompt (passed via stdin). This ensures Claude CLI correctly
    /// applies the system prompt instead of treating it as conversation text.
    static func splitPrompt(messages: [ChatMessage]) -> (system: String, user: String) {
        var systemParts: [String] = []
        var userParts: [String] = []

        for message in messages {
            switch message.role {
            case .system:
                systemParts.append(message.content)
            case .user:
                userParts.append(message.content)
            case .assistant:
                userParts.append("[Previous response]\n\(message.content)")
            }
        }

        return (
            system: systemParts.joined(separator: "\n\n"),
            user: userParts.joined(separator: "\n\n")
        )
    }
}
