import Foundation

/// Protocol for LLM backends. MLX is the primary implementation for MeetingHUD.
protocol LLMProvider: Sendable {
    /// Stream a response from the LLM given a conversation history.
    func stream(messages: [ChatMessage]) async throws -> AsyncStream<String>

    /// Human-readable name for this provider.
    var displayName: String { get }

    /// Whether this provider is currently available (model loaded).
    var isAvailable: Bool { get async }

    /// Maximum context window size in tokens, or nil if unknown.
    var contextWindowSize: Int? { get }
}

extension LLMProvider {
    var contextWindowSize: Int? { nil }

    /// Collect a full streamed response into a single string.
    func collectResponse(messages: [ChatMessage]) async throws -> String {
        var chunks: [String] = []
        let stream = try await self.stream(messages: messages)
        for await chunk in stream {
            chunks.append(chunk)
        }
        return chunks.joined()
    }
}
