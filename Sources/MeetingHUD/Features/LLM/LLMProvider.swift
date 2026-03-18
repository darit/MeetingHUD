import Foundation

/// Protocol for transcription backends (WhisperKit, Parakeet, etc.).
protocol TranscriptionProvider: AnyObject {
    var isModelLoaded: Bool { get }
    var isModelLoading: Bool { get }
    var loadingStatus: String { get }
    var downloadProgress: Double { get }
    var accumulatedAudio: [Float] { get }
    var defaultSpeakerName: String { get set }
    var language: String? { get set }
    /// When true, incoming audio is ignored (not transcribed or accumulated).
    var isMuted: Bool { get set }
    func loadModel() async throws
    func transcribeAudio(_ samples: [Float]) async throws -> String
    func clearAccumulatedAudio()
}

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
