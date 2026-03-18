import Accelerate
import AVFoundation
import Foundation

/// Captures microphone audio for push-to-talk voice input.
/// Accumulates samples while recording, then transcribes via the shared TranscriptionEngine.
@Observable @MainActor
final class VoiceInputManager {
    // MARK: - State

    var isRecording = false
    var isTranscribing = false
    var audioLevel: Float = 0.0

    // MARK: - Dependencies

    private let transcriptionEngine: TranscriptionEngine

    // MARK: - Audio

    private var audioEngine: AVAudioEngine?
    private var sampleBuffer: [Float] = []
    private var levelTimer: Task<Void, Never>?

    /// Maximum recording duration in seconds to prevent unbounded memory growth.
    private let maxRecordingDuration = 60

    init(transcriptionEngine: TranscriptionEngine) {
        self.transcriptionEngine = transcriptionEngine
    }

    // MARK: - Recording

    /// Start recording from the default microphone.
    func startRecording() {
        guard !isRecording else { return }

        let engine = AVAudioEngine()
        sampleBuffer = []
        sampleBuffer.reserveCapacity(Constants.Audio.sampleRate * maxRecordingDuration)

        let sharedBuffer = AudioSampleBuffer()

        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: UInt32(Constants.Audio.bufferSize),
            format: Constants.Audio.processingFormat
        ) { pcmBuffer, _ in
            guard let channelData = pcmBuffer.floatChannelData else { return }
            let frameCount = Int(pcmBuffer.frameLength)
            let ptr = channelData[0]

            // RMS level metering directly from pointer (no copy needed)
            var meanSquare: Float = 0
            vDSP_measqv(ptr, 1, &meanSquare, vDSP_Length(frameCount))
            sharedBuffer.level = sqrtf(meanSquare)

            // Copy samples for accumulation
            let samples = Array(UnsafeBufferPointer(start: ptr, count: frameCount))
            sharedBuffer.append(samples)
        }

        do {
            try engine.start()
        } catch {
            print("[VoiceInputManager] Failed to start mic capture: \(error)")
            return
        }

        audioEngine = engine
        isRecording = true

        // Periodically drain accumulated samples to main actor and update level
        let maxSamples = Constants.Audio.sampleRate * maxRecordingDuration
        levelTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { break }
                self.audioLevel = sharedBuffer.level

                let drained = sharedBuffer.drain()
                if !drained.isEmpty {
                    self.sampleBuffer.append(contentsOf: drained)
                }

                // Auto-stop at max duration
                if self.sampleBuffer.count >= maxSamples {
                    break
                }
            }
        }
    }

    /// Stop recording and transcribe the captured audio.
    /// Returns the transcribed text, or nil if nothing was captured or transcription failed.
    func stopAndTranscribe() async -> String? {
        guard isRecording else { return nil }

        // Stop capture
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        isRecording = false
        audioLevel = 0.0

        levelTimer?.cancel()
        levelTimer = nil

        let samples = sampleBuffer
        sampleBuffer = []

        guard !samples.isEmpty else { return nil }

        // Require at least 0.5s of audio to avoid transcribing noise
        let minSamples = Constants.Audio.sampleRate / 2
        guard samples.count >= minSamples else { return nil }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let text = try await transcriptionEngine.transcribeAudio(samples)
            return text.isEmpty ? nil : text
        } catch {
            print("[VoiceInputManager] Transcription failed: \(error)")
            return nil
        }
    }
}

// MARK: - Thread-Safe Sample Buffer

/// Sendable buffer for bridging audio render thread data to the main actor.
private final class AudioSampleBuffer: @unchecked Sendable {
    private var storage: [Float] = []
    private let lock = NSLock()

    /// Current RMS audio level (written from audio thread, read from main actor).
    var level: Float = 0

    func append(_ samples: [Float]) {
        lock.lock()
        storage.append(contentsOf: samples)
        lock.unlock()
    }

    func drain() -> [Float] {
        lock.lock()
        let result = storage
        storage = []
        lock.unlock()
        return result
    }
}
