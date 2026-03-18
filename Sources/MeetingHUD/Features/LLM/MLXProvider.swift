import Foundation
import MLXLLM
import MLXLMCommon

/// MLX-based local LLM provider for on-device inference.
final class MLXProvider: LLMProvider, @unchecked Sendable {

    var displayName: String {
        "MLX Local"
    }

    var contextWindowSize: Int? { 8192 }

    var isAvailable: Bool {
        get async {
            await MainActor.run { MLXModelManager.shared.loadState == .loaded }
        }
    }

    func stream(messages: [ChatMessage]) async throws -> AsyncStream<String> {
        let container = await MainActor.run { MLXModelManager.shared.modelContainer }

        guard let container else {
            return AsyncStream { continuation in
                continuation.yield("[Error: No model loaded. Download and load a model first.]")
                continuation.finish()
            }
        }

        let mlxMessages: [[String: String]] = messages.map { msg in
            ["role": msg.role.rawValue, "content": msg.content]
        }

        let userInput = UserInput(messages: mlxMessages)
        let input = try await container.prepare(input: userInput)

        let params = GenerateParameters(
            maxTokens: 2048,
            temperature: 0.7,
            topP: 0.9,
            repetitionPenalty: 1.1
        )

        let generationStream = try await container.generate(input: input, parameters: params)

        return AsyncStream { continuation in
            let generateTask = Task {
                for await generation in generationStream {
                    if Task.isCancelled { break }
                    switch generation {
                    case .chunk(let text):
                        continuation.yield(text)
                    case .info, .toolCall:
                        break
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                generateTask.cancel()
            }
        }
    }
}
