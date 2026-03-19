import Foundation
import WhisperKit

/// Drives real-time transcription by feeding audio buffers to WhisperKit
/// and emitting TranscriptSegment objects.
///
/// Uses chunked processing: accumulates audio samples for a configurable interval,
/// then runs WhisperKit transcription on each chunk. Includes basic speaker turn
/// detection via silence gaps between segments.
@Observable
final class TranscriptionEngine: @unchecked Sendable, TranscriptionProvider {
    // MARK: - State

    var isModelLoaded = false
    var isModelLoading = false
    var isTranscribing = false
    var currentPartialText: String = ""

    /// Human-readable loading status: "Downloading…", "Loading…", etc.
    var loadingStatus: String = ""

    /// Download progress 0.0–1.0. Only valid while downloading.
    var downloadProgress: Double = 0

    // MARK: - Configuration

    /// Which Whisper model to use. "large-v3-turbo" is multilingual, near-large-v3 accuracy, 6x faster.
    var modelName = "large-v3-turbo"

    /// Default speaker name for new segments (e.g. "Danny" for mic, "Speaker 1" for system audio).
    var defaultSpeakerName: String = "Speaker 1"

    /// Language code for transcription (e.g. "es", "en").
    /// - "auto": detect from first 30s of audio, then lock in for the session.
    /// - nil or specific code: use that language for all chunks.
    var language: String? = nil


    /// Whether language has been auto-detected for this session.
    private var languageDetected = false

    // MARK: - WhisperKit

    private var whisperKit: WhisperKit?

    // MARK: - Audio Accumulation

    /// Rolling audio buffer for live diarization (last 5 minutes max).
    /// Older audio is discarded to prevent unbounded memory growth.
    private(set) var accumulatedAudio: [Float] = []

    /// Maximum audio to keep in memory (5 minutes at 16kHz = ~19 MB).
    private let maxAccumulatedSamples = 16000 * 300 // 5 minutes

    // MARK: - Speaker Turn Detection

    /// Tracks current speaker index for silence-gap turn detection.
    private var currentSpeakerIndex = 0

    /// End time of the last transcribed segment, for detecting silence gaps.
    private var lastSegmentEndTime: TimeInterval = 0

    // MARK: - Output Stream

    private var segmentContinuation: AsyncStream<TranscriptSegment>.Continuation?

    /// Stream of finalized transcript segments. Access ONCE before calling `startTranscribing`.
    var transcriptStream: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.segmentContinuation = continuation
        }
    }

    // MARK: - Lifecycle

    /// Load the Whisper model. Downloads from HuggingFace Hub on first run (~75MB for base).
    func loadModel() async throws {
        guard !isModelLoaded else { return }
        isModelLoading = true
        loadingStatus = "Initializing…"
        downloadProgress = 0
        defer {
            isModelLoading = false
            loadingStatus = ""
            downloadProgress = 0
        }

        let config = WhisperKitConfig(model: modelName)
        let wk = try await WhisperKit(config)

        // Wire model state changes to our status text
        wk.modelStateCallback = { [weak self] _, newState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch newState {
                case .downloading:
                    self.loadingStatus = "Downloading model…"
                case .downloaded:
                    self.loadingStatus = "Downloaded. Loading into memory…"
                    self.downloadProgress = 1.0
                case .loading:
                    self.loadingStatus = "Loading model…"
                case .prewarming:
                    self.loadingStatus = "Warming up Neural Engine…"
                case .loaded:
                    self.loadingStatus = "Ready"
                default:
                    break
                }
            }
        }

        // Observe download progress via KVO on the Progress object
        let progressObserver = wk.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let frac = progress.fractionCompleted
                if frac > 0 && frac < 1.0 {
                    self.downloadProgress = frac
                    let pct = Int(frac * 100)
                    self.loadingStatus = "Downloading model… \(pct)%"
                }
            }
        }

        whisperKit = wk
        isModelLoaded = true
        _ = progressObserver // keep alive until done
    }

    /// Begin consuming audio sample arrays and producing transcript segments.
    ///
    /// - Parameter audioStream: Async stream of Float32 sample arrays from AudioCaptureManager.
    func startTranscribing(from audioStream: AsyncStream<[Float]>) async {
        if !isModelLoaded {
            try? await loadModel()
        }
        guard isModelLoaded else { return }

        isTranscribing = true
        currentSpeakerIndex = 0
        lastSegmentEndTime = 0
        accumulatedAudio = []
        languageDetected = false

        // Accumulate audio samples for chunked processing
        var sampleAccumulator: [Float] = []
        let chunkSampleCount = Constants.Audio.sampleRate * Int(Constants.Timing.transcriptionChunkInterval)
        var chunkIndex = 0

        for await samples in audioStream {
            guard isTranscribing else { break }
            sampleAccumulator.append(contentsOf: samples)
            accumulatedAudio.append(contentsOf: samples)

            // Trim to rolling window to prevent unbounded memory growth
            if accumulatedAudio.count > maxAccumulatedSamples {
                accumulatedAudio.removeFirst(accumulatedAudio.count - maxAccumulatedSamples)
            }

            // Process when we have enough samples for a chunk
            while sampleAccumulator.count >= chunkSampleCount {
                let chunk = Array(sampleAccumulator.prefix(chunkSampleCount))
                sampleAccumulator.removeFirst(chunkSampleCount)

                let backlogSecs = Double(sampleAccumulator.count) / Double(Constants.Audio.sampleRate)
                if backlogSecs > 5 {
                    print("[Whisper] ⚠ Backlog: \(String(format: "%.0f", backlogSecs))s of audio waiting")
                }

                let chunkOffset = TimeInterval(chunkIndex) * Constants.Timing.transcriptionChunkInterval
                await processChunk(chunk, offset: chunkOffset)
                chunkIndex += 1
            }
        }

        // Process any remaining audio
        if !sampleAccumulator.isEmpty && isTranscribing {
            let chunkOffset = TimeInterval(chunkIndex) * Constants.Timing.transcriptionChunkInterval
            await processChunk(sampleAccumulator, offset: chunkOffset)
        }

        isTranscribing = false
    }

    /// Stop transcription.
    func stopTranscribing() {
        isTranscribing = false
        segmentContinuation?.finish()
        segmentContinuation = nil
    }

    /// Transcribe a standalone audio buffer (e.g. from voice input).
    /// Returns the concatenated text from all recognized segments.
    func transcribeAudio(_ samples: [Float]) async throws -> String {
        guard let whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }
        let results = try await whisperKit.transcribe(audioArray: samples)
        return results
            .flatMap(\.segments)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Free accumulated audio memory after diarization is complete.
    func clearAccumulatedAudio() {
        accumulatedAudio = []
    }

    // MARK: - Errors

    enum TranscriptionError: Error, LocalizedError {
        case modelNotLoaded

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: "Whisper model is not loaded"
            }
        }
    }

    // MARK: - Private

    /// Regex to strip any remaining Whisper control tokens from output text.
    private static let controlTokenPattern = try! Regex(#"<\|[^|]+\|>"#)
    private static let bracketTagPattern = try! Regex(#"(?i)\[(BLANK_AUDIO|silence|music|música|musica|applause|laughter|risas|inaudible)\]"#)

    /// Clean Whisper output text by removing control tokens, bracket tags, and hallucinated repetition.
    private func cleanText(_ raw: String) -> String? {
        var text = raw
        text = text.replacing(Self.controlTokenPattern, with: "")
        text = text.replacing(Self.bracketTagPattern, with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text
    }

    private func processChunk(_ samples: [Float], offset: TimeInterval) async {
        guard let whisperKit else { return }

        // Auto-detect language from first chunk, then lock it in
        if language == nil && !languageDetected {
            languageDetected = true
            do {
                let detection = try await whisperKit.detectLangauge(audioArray: samples)
                language = detection.language
                print("[Whisper] Auto-detected language: \(detection.language)")
            } catch {
                print("[Whisper] Language detection failed, defaulting to es: \(error)")
                language = "es"
            }
        }

        let options = DecodingOptions(
            language: language,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: false
        )

        let chunkDuration = Double(samples.count) / Double(Constants.Audio.sampleRate)
        let start = CFAbsoluteTimeGetCurrent()

        do {
            let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let ratio = elapsed / chunkDuration

            var segCount = 0
            for result in results {
                for segment in result.segments {
                    guard let text = cleanText(segment.text) else { continue }

                    let segmentStart = offset + TimeInterval(segment.start)
                    let segmentEnd = offset + TimeInterval(segment.end)

                    lastSegmentEndTime = segmentEnd

                    // Use default speaker name. For mic input this is typically the user.
                    // Live diarization will re-label with real speaker IDs later.
                    let speakerLabel = defaultSpeakerName

                    let transcriptSegment = TranscriptSegment(
                        text: text,
                        speakerLabel: speakerLabel,
                        startTime: segmentStart,
                        endTime: segmentEnd
                    )
                    segmentContinuation?.yield(transcriptSegment)
                    segCount += 1
                }
            }

            if ratio > 1.0 {
                print("[Whisper] SLOW chunk \(String(format: "%.1f", chunkDuration))s audio took \(String(format: "%.1f", elapsed))s (\(String(format: "%.1fx", ratio))) → \(segCount) segs")
            }
        } catch {
            print("[Whisper] Transcription error: \(error)")
        }
    }
}
