import AVFoundation
import Foundation

/// App-wide constants for timing, token budgets, and audio configuration.
enum Constants {
    // MARK: - Timing

    enum Timing {
        /// Seconds of audio accumulated before sending to WhisperKit for transcription.
        static let transcriptionChunkInterval: TimeInterval = 3.0

        /// Seconds between LLM recommendation generation passes.
        static let recommendationTriggerInterval: TimeInterval = 30.0

        /// Seconds between memory compression sweeps (hot -> warm tier).
        static let memoryCompressionInterval: TimeInterval = 120.0

        /// Seconds of silence before considering a speaker turn ended.
        static let silenceThreshold: TimeInterval = 3.0
    }

    // MARK: - Token Budgets

    enum TokenBudgets {
        /// Maximum tokens in the hot tier (full-fidelity recent transcript).
        static let hotTierMax = 4_000

        /// Maximum tokens in the warm tier (summarized older transcript).
        static let warmTierMax = 8_000

        /// Total context budget for LLM inference, including system prompt.
        static let totalContextBudget = 16_000

        /// Reserved tokens for the system prompt and instructions.
        static let systemPromptReserve = 1_500
    }

    // MARK: - Audio

    enum Audio {
        /// Sample rate for audio processing (WhisperKit expects 16kHz).
        static let sampleRate = 16_000

        /// Buffer size in frames per audio callback.
        static let bufferSize = 4_096

        /// Number of audio channels (mono for speech).
        static let channels: UInt32 = 1

        /// Standard audio format for processing: 16kHz mono Float32.
        static let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: channels,
            interleaved: false
        )!
    }

    // MARK: - Voice Activity Detection

    enum VAD {
        /// RMS threshold to trigger speech detection.
        static let rmsThreshold: Float = 0.01

        /// Duration of sustained RMS above threshold before confirming speech onset (seconds).
        static let onsetDuration: TimeInterval = 0.5

        /// Duration of silence before ending a conversation (seconds).
        static let silenceTimeout: TimeInterval = 120.0

        /// Conversation gap threshold for visual grouping in transcript (seconds).
        static let conversationGapThreshold: TimeInterval = 120.0
    }

    // MARK: - Speaker Labels

    /// Generate a speaker label like "Speaker A", "Speaker B", ..., "Speaker Z", "Speaker 27", etc.
    static func speakerLabel(index: Int) -> String {
        if index < 26 {
            return "Speaker \(String(UnicodeScalar(UInt8(65 + index))))"
        }
        return "Speaker \(index + 1)"
    }

    // MARK: - App Identity

    enum App {
        static let name = "MeetingHUD"
        static let bundleIdentifier = "com.meetinghud.app"
    }
}
