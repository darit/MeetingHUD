import Foundation
import ParakeetASR

/// Transcription engine using Parakeet TDT v3 (CoreML on ANE).
/// Drop-in replacement for TranscriptionEngine with better accuracy,
/// auto-punctuation, and auto-language detection.
@Observable
final class ParakeetTranscriptionEngine: @unchecked Sendable, TranscriptionProvider {
    // MARK: - State

    var isModelLoaded = false
    var isModelLoading = false
    var isTranscribing = false
    var currentPartialText: String = ""

    var loadingStatus: String = ""
    var downloadProgress: Double = 0

    // MARK: - Configuration

    var defaultSpeakerName: String = "Speaker 1"

    /// Language code for transcription. nil = auto-detect (Parakeet handles 25 languages).
    var language: String? = nil

    /// When true, incoming audio is ignored (not transcribed or accumulated).
    var isMuted = false

    // MARK: - Parakeet

    private var model: ParakeetASRModel?

    // MARK: - Audio Accumulation

    private(set) var accumulatedAudio: [Float] = []

    // MARK: - Output Stream

    private var segmentContinuation: AsyncStream<TranscriptSegment>.Continuation?

    var transcriptStream: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.segmentContinuation = continuation
        }
    }

    // MARK: - Lifecycle

    func loadModel() async throws {
        guard !isModelLoaded else { return }
        isModelLoading = true
        loadingStatus = "Loading Parakeet TDT…"
        downloadProgress = 0
        defer {
            isModelLoading = false
            loadingStatus = ""
            downloadProgress = 0
        }

        // Track whether we actually need to download (progress stays at 0% briefly then jumps)
        var sawRealDownload = false
        let loadStart = ContinuousClock.now

        let parakeet = try await ParakeetASRModel.fromPretrained { [weak self] progress, status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadProgress = progress

                // The library always says "Downloading model..." even when cached.
                // If we're still in the "download" phase (progress < 0.7), check timing:
                // a real download takes >1s, a cache hit is instant.
                if status.contains("Downloading") {
                    let elapsed = ContinuousClock.now - loadStart
                    if elapsed > .seconds(1) && progress < 0.65 {
                        sawRealDownload = true
                    }
                    if sawRealDownload {
                        self.loadingStatus = status
                    } else {
                        self.loadingStatus = "Loading Parakeet TDT…"
                    }
                } else {
                    // "Loading CoreML models...", "Loading decoder...", etc.
                    self.loadingStatus = status
                }
            }
        }

        loadingStatus = "Warming up Neural Engine…"
        try parakeet.warmUp()

        model = parakeet
        isModelLoaded = true
    }

    /// Begin consuming audio sample arrays and producing transcript segments.
    func startTranscribing(from audioStream: AsyncStream<[Float]>) async {
        if !isModelLoaded {
            try? await loadModel()
        }
        guard isModelLoaded else { return }

        isTranscribing = true
        accumulatedAudio = []

        // Parakeet benefits from longer chunks for better punctuation context
        var sampleAccumulator: [Float] = []
        let chunkSampleCount = Constants.Audio.sampleRate * 5 // 5s chunks
        var chunkIndex = 0

        for await samples in audioStream {
            guard isTranscribing else { break }
            guard !isMuted else { continue }

            sampleAccumulator.append(contentsOf: samples)
            accumulatedAudio.append(contentsOf: samples)

            if sampleAccumulator.count >= chunkSampleCount {
                let chunk = Array(sampleAccumulator.prefix(chunkSampleCount))
                sampleAccumulator.removeFirst(chunkSampleCount)

                let chunkOffset = TimeInterval(chunkIndex) * 5.0
                processChunk(chunk, offset: chunkOffset)
                chunkIndex += 1
            }
        }

        // Process remaining audio
        if !sampleAccumulator.isEmpty && isTranscribing {
            let chunkOffset = TimeInterval(chunkIndex) * 5.0
            processChunk(sampleAccumulator, offset: chunkOffset)
        }

        isTranscribing = false
    }

    func stopTranscribing() {
        isTranscribing = false
        segmentContinuation?.finish()
        segmentContinuation = nil
    }

    func transcribeAudio(_ samples: [Float]) async throws -> String {
        guard let model else {
            throw TranscriptionError.modelNotLoaded
        }
        return try model.transcribeAudio(samples, sampleRate: 16000, language: language)
    }

    func clearAccumulatedAudio() {
        accumulatedAudio = []
    }

    // MARK: - Errors

    enum TranscriptionError: Error, LocalizedError {
        case modelNotLoaded

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: "Parakeet model is not loaded"
            }
        }
    }

    // MARK: - Private

    private func processChunk(_ samples: [Float], offset: TimeInterval) {
        guard let model else { return }

        do {
            let text = try model.transcribeAudio(samples, sampleRate: 16000, language: language)

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let chunkDuration = TimeInterval(samples.count) / TimeInterval(Constants.Audio.sampleRate)

            let segment = TranscriptSegment(
                text: trimmed,
                speakerLabel: defaultSpeakerName,
                startTime: offset,
                endTime: offset + chunkDuration
            )
            segmentContinuation?.yield(segment)
        } catch {
            print("[ParakeetEngine] Transcription error: \(error)")
        }
    }
}
