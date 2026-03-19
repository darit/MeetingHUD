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

    /// Whether language has been auto-detected and locked for this session.
    private var languageLocked = false

    /// Debug log callback — wired to AppState.addDebug to show in overlay.
    var onDebugLog: ((String) -> Void)?

    private func log(_ msg: String) {
        print("[ParakeetEngine] \(msg)")
        onDebugLog?(msg)
    }

    // MARK: - Parakeet

    private var model: ParakeetASRModel?

    // MARK: - Audio Accumulation

    private(set) var accumulatedAudio: [Float] = []
    private let maxAccumulatedSamples = 16000 * 300 // 5 minutes rolling window

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

        var sawRealDownload = false
        let loadStart = ContinuousClock.now

        let parakeet = try await ParakeetASRModel.fromPretrained { [weak self] progress, status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadProgress = progress
                if status.contains("Downloading") {
                    let elapsed = ContinuousClock.now - loadStart
                    if elapsed > .seconds(1) && progress < 0.65 {
                        sawRealDownload = true
                    }
                    self.loadingStatus = sawRealDownload ? status : "Loading Parakeet TDT…"
                } else {
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
    /// Uses adaptive chunking: accumulates audio until enough speech energy is detected,
    /// so silent periods don't waste chunks or get trimmed as noise.
    func startTranscribing(from audioStream: AsyncStream<[Float]>) async {
        if !isModelLoaded {
            try? await loadModel()
        }
        guard isModelLoaded else { return }

        isTranscribing = true
        accumulatedAudio = []
        languageLocked = language != nil
        chunkCount = 0

        var sampleAccumulator: [Float] = []
        let sampleRate = Constants.Audio.sampleRate
        let minChunkSamples = sampleRate * 5   // 5s min — don't send tiny chunks
        let targetChunkSamples = sampleRate * 15 // 15s target — more context = better accuracy + language detection
        let maxChunkSamples = sampleRate * 30   // 30s max — safety cap
        var chunkIndex = 0
        var bufferCount = 0
        /// Running count of "speech" samples in the accumulator (RMS above threshold).
        var speechSamplesInAccumulator = 0
        /// Threshold to distinguish real speech from background noise in system audio.
        /// System audio RMS during speech is ~0.03-0.07, during silence ~0.001-0.005.
        let speechRMSThreshold: Float = 0.01
        /// Minimum speech before flushing (4s of actual speech)
        let minSpeechSamples = sampleRate * 4

        for await samples in audioStream {
            guard isTranscribing else { break }
            bufferCount += 1
            sampleAccumulator.append(contentsOf: samples)
            accumulatedAudio.append(contentsOf: samples)

            // Trim accumulated audio to rolling window
            if accumulatedAudio.count > maxAccumulatedSamples {
                accumulatedAudio.removeFirst(accumulatedAudio.count - maxAccumulatedSamples)
            }

            // Count speech energy in the new samples
            let rms = Self.computeRMS(samples)
            if rms > speechRMSThreshold {
                speechSamplesInAccumulator += samples.count
            }

            let accumSecs = Double(sampleAccumulator.count) / Double(sampleRate)
            let speechSecs = Double(speechSamplesInAccumulator) / Double(sampleRate)

            // Adaptive flush decision:
            // 1. Hit max size → always flush (prevents unbounded accumulation)
            // 2. Hit target size AND have enough speech → flush (normal case)
            // 3. Below target → keep accumulating (wait for more speech)
            let shouldFlush: Bool
            let flushReason: String
            if sampleAccumulator.count >= maxChunkSamples {
                shouldFlush = true
                flushReason = "max-cap"
            } else if sampleAccumulator.count >= targetChunkSamples
                        && speechSamplesInAccumulator >= minSpeechSamples {
                shouldFlush = true
                flushReason = "target+speech"
            } else if sampleAccumulator.count >= minChunkSamples
                        && speechSamplesInAccumulator >= targetChunkSamples {
                shouldFlush = true
                flushReason = "speech-heavy"
            } else {
                shouldFlush = false
                flushReason = ""
            }

            if shouldFlush {
                let chunk = sampleAccumulator
                let chunkOffset = TimeInterval(accumulatedAudio.count - chunk.count) / TimeInterval(sampleRate)
                let peakAmp = chunk.reduce(Float(0)) { max($0, abs($1)) }
                let chunkRMS = Self.computeRMS(chunk)
                log("Flush [\(flushReason)]: \(String(format: "%.1f", accumSecs))s chunk, \(String(format: "%.1f", speechSecs))s speech, peak=\(String(format: "%.4f", peakAmp)), rms=\(String(format: "%.5f", chunkRMS))")

                sampleAccumulator = []
                speechSamplesInAccumulator = 0

                processChunk(chunk, offset: chunkOffset)
                chunkIndex += 1
            }
        }

        // Process remaining audio
        if !sampleAccumulator.isEmpty && isTranscribing {
            let chunkOffset = TimeInterval(accumulatedAudio.count - sampleAccumulator.count) / TimeInterval(sampleRate)
            processChunk(sampleAccumulator, offset: chunkOffset)
        }

        log("Session ended: \(bufferCount) buffers received, \(chunkIndex) chunks processed, \(accumulatedAudio.count / 16000)s total audio")

        isTranscribing = false
    }

    /// Compute RMS energy of an audio buffer.
    private static func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(samples.count))
    }

    /// Peak-normalize audio to target amplitude.
    /// Boosts quiet system audio so Parakeet gets a strong signal.
    private static func normalizeAudio(_ samples: [Float], targetPeak: Float = 0.9) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        // Don't amplify if already loud enough, or if it's basically silence
        guard peak > 0.0001 && peak < targetPeak else { return samples }
        let gain = targetPeak / peak
        // Cap gain to avoid amplifying noise too much (max 20x / +26dB)
        let clampedGain = min(gain, 20.0)
        return samples.map { $0 * clampedGain }
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

    private var chunkCount = 0

    private func processChunk(_ samples: [Float], offset: TimeInterval) {
        guard let model else { return }
        chunkCount += 1

        // Normalize audio volume — system capture is often much quieter than mic.
        // Peak-normalize to ~0.9 so Parakeet gets a strong signal.
        let normalized = Self.normalizeAudio(samples)
        let preNormPeak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let postNormPeak = normalized.reduce(Float(0)) { max($0, abs($1)) }
        let gain = preNormPeak > 0 ? postNormPeak / preNormPeak : 1.0

        let result = model.transcribeWithLanguage(audio: normalized, sampleRate: 16000, language: language)

        let fullText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = String(fullText.prefix(80))
        let durationSecs = String(format: "%.1f", Double(samples.count) / 16000.0)
        log("Chunk #\(chunkCount): \(durationSecs)s conf=\(String(format: "%.2f", result.confidence)) lang=\(result.language ?? "?") gain=\(String(format: "%.1f", gain))x \"\(preview)\"")

        // Log auto-detected language on first confident chunk
        if language == nil && !languageLocked {
            if result.confidence > 0.5, let lang = result.language, !lang.isEmpty {
                let langCode = Self.languageNameToCode[lang.lowercased()] ?? lang
                languageLocked = true
                log("Detected language: \(lang) → \(langCode)")
            }
        }

        // Skip low-confidence chunks (noise/silence)
        guard result.confidence > 0.1 else {
            log("DROPPED: conf \(String(format: "%.2f", result.confidence)) < 0.1")
            return
        }

        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log("DROPPED: empty text after trim")
            return
        }

        let chunkDuration = TimeInterval(samples.count) / TimeInterval(Constants.Audio.sampleRate)

        // Split into sentences for finer-grained diarization alignment.
        // An 8s chunk may contain multiple speakers — sentence-level segments
        // let the diarizer assign different speakers to each sentence.
        let sentences = splitIntoSentences(trimmed)

        if sentences.count <= 1 {
            let segment = TranscriptSegment(
                text: trimmed,
                speakerLabel: defaultSpeakerName,
                startTime: offset,
                endTime: offset + chunkDuration
            )
            segmentContinuation?.yield(segment)
        } else {
            // Distribute time proportionally by character count
            let totalChars = sentences.reduce(0) { $0 + $1.count }
            var currentTime = offset
            for sentence in sentences {
                let fraction = Double(sentence.count) / Double(max(totalChars, 1))
                let segDuration = chunkDuration * fraction
                let segment = TranscriptSegment(
                    text: sentence,
                    speakerLabel: defaultSpeakerName,
                    startTime: currentTime,
                    endTime: currentTime + segDuration
                )
                segmentContinuation?.yield(segment)
                currentTime += segDuration
            }
        }
    }

    /// Split text into sentences using punctuation boundaries.
    /// Parakeet auto-punctuates, so we can split on . ? ! and keep the punctuation.
    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        for char in text {
            current.append(char)
            if char == "." || char == "?" || char == "!" || char == "¿" || char == "¡" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && trimmed.count > 5 { // skip very short fragments
                    sentences.append(trimmed)
                    current = ""
                }
            }
        }
        // Remaining text
        let remaining = current.trimmingCharacters(in: .whitespaces)
        if !remaining.isEmpty {
            if remaining.count > 5 {
                sentences.append(remaining)
            } else if let last = sentences.last {
                sentences[sentences.count - 1] = last + " " + remaining
            } else {
                sentences.append(remaining)
            }
        }

        return sentences
    }

    private static let languageNameToCode: [String: String] = [
        "english": "en", "spanish": "es", "french": "fr", "german": "de",
        "italian": "it", "portuguese": "pt", "dutch": "nl", "russian": "ru",
        "chinese": "zh", "japanese": "ja", "korean": "ko", "arabic": "ar",
        "hindi": "hi", "turkish": "tr", "polish": "pl", "swedish": "sv",
        "norwegian": "no", "danish": "da", "finnish": "fi", "greek": "el",
        "czech": "cs", "romanian": "ro", "hungarian": "hu", "catalan": "ca",
    ]
}
