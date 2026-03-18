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
        let prompt = Self.formatPrompt(messages: messages)

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
                    process.arguments = ["-p", "--model", self.model.rawValue]

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

                    // Write prompt to stdin and close
                    let promptData = prompt.data(using: .utf8) ?? Data()
                    inputPipe.fileHandleForWriting.write(promptData)
                    inputPipe.fileHandleForWriting.closeFile()

                    // Read stdout in chunks
                    let handle = outputPipe.fileHandleForReading
                    var data = handle.readData(ofLength: 4096)
                    while !data.isEmpty {
                        if let chunk = String(data: data, encoding: .utf8) {
                            continuation.yield(chunk)
                        }
                        data = handle.readData(ofLength: 4096)
                    }

                    process.waitUntilExit()

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

    static func formatPrompt(messages: [ChatMessage]) -> String {
        var parts: [String] = []
        for message in messages {
            switch message.role {
            case .system:
                parts.append("[System Instructions]\n\(message.content)")
            case .user:
                parts.append("[User]\n\(message.content)")
            case .assistant:
                parts.append("[Assistant]\n\(message.content)")
            }
        }
        return parts.joined(separator: "\n\n---\n\n")
    }
}
