import Foundation
import SpeechVAD

/// Real-time speaker detection using Silero VAD + WeSpeaker embeddings.
///
/// Processes audio in two stages:
/// 1. **VAD** (32ms chunks): detects when someone starts/stops speaking
/// 2. **Embedding** (on speech end): extracts 256-dim voice embedding from the speech segment
///
/// The embedding is then matched against known speakers via `SpeakerIdentifier`.
/// This gives per-segment speaker identification in near real-time (~1-5s latency)
/// instead of waiting 15-60s for batch SpeakerKit diarization.
actor RealTimeSpeakerDetector {

    // MARK: - State

    private var vadModel: SileroVADModel?
    private var vadProcessor: StreamingVADProcessor?
    private var speakerModel: WeSpeakerModel?
    private var isLoaded = false

    /// Audio accumulator for the current speech segment.
    private var speechBuffer: [Float] = []

    /// Whether we're currently in a speech segment.
    private var isSpeaking = false

    /// Minimum speech duration (seconds) to extract embedding from.
    private let minSpeechDuration: TimeInterval = 1.5

    /// Maximum speech buffer (seconds) — take only the last N seconds for embedding.
    private let maxEmbeddingDuration: TimeInterval = 5.0

    // MARK: - Callbacks

    /// Called when a speaker is identified for a speech segment.
    /// Parameters: (speakerLabel, embedding)
    private var onSpeakerIdentified: ((String, [Float]) -> Void)?

    /// Called for debug logging.
    private var onDebugLog: ((String) -> Void)?

    /// Configure callbacks (call from outside the actor).
    func configure(
        onSpeakerIdentified: ((String, [Float]) -> Void)? = nil,
        onDebugLog: ((String) -> Void)? = nil
    ) {
        self.onSpeakerIdentified = onSpeakerIdentified
        self.onDebugLog = onDebugLog
    }

    // MARK: - Lifecycle

    /// Load VAD and speaker embedding models. Call once before processing.
    func loadModels() async throws {
        guard !isLoaded else { return }

        onDebugLog?("Loading Silero VAD...")
        vadModel = try await SileroVADModel.fromPretrained(engine: .coreml)

        if let vad = vadModel {
            vadProcessor = StreamingVADProcessor(model: vad)
        }

        onDebugLog?("Loading WeSpeaker embedding model...")
        speakerModel = try await WeSpeakerModel.fromPretrained(engine: .coreml)

        isLoaded = true
        onDebugLog?("Speaker detection models loaded")
    }

    /// Reset state between recordings.
    func reset() {
        vadProcessor?.reset()
        speechBuffer = []
        isSpeaking = false
    }

    // MARK: - Audio Processing

    /// Process a chunk of audio samples (16kHz mono Float32).
    /// Call this from the audio pipeline with each buffer.
    ///
    /// Returns the speaker label if a speaker was identified at a speech boundary,
    /// or nil if still accumulating / no speech detected.
    func processAudio(_ samples: [Float]) -> String? {
        guard let vadProcessor, let speakerModel else { return nil }

        var identifiedSpeaker: String?

        // Feed to VAD — processes internally in 512-sample (32ms) chunks
        let events = vadProcessor.process(samples: samples)

        // Always accumulate audio when speaking
        if isSpeaking {
            speechBuffer.append(contentsOf: samples)
            // Cap buffer to maxEmbeddingDuration
            let maxSamples = Int(maxEmbeddingDuration * 16000)
            if speechBuffer.count > maxSamples {
                speechBuffer = Array(speechBuffer.suffix(maxSamples))
            }
        }

        for event in events {
            switch event {
            case .speechStarted:
                isSpeaking = true
                speechBuffer = []

            case .speechEnded(let segment):
                isSpeaking = false
                let duration = segment.endTime - segment.startTime

                if Double(duration) >= minSpeechDuration && !speechBuffer.isEmpty {
                    let embedding = speakerModel.embed(audio: speechBuffer, sampleRate: 16000)
                    if !embedding.isEmpty {
                        let label = identifySpeaker(embedding: embedding)
                        onSpeakerIdentified?(label, embedding)
                        identifiedSpeaker = label
                    }
                }
                speechBuffer = []
            }
        }

        return identifiedSpeaker
    }

    /// Extract an embedding for a given audio buffer (e.g., for saving voice profiles).
    func extractEmbedding(from audio: [Float]) -> [Float]? {
        guard let speakerModel, !audio.isEmpty else { return nil }
        let embedding = speakerModel.embed(audio: audio, sampleRate: 16000)
        return embedding.isEmpty ? nil : embedding
    }

    // MARK: - Speaker Matching (with channel compensation)

    /// Active speakers: label → centroid embedding + raw embeddings for refinement.
    private var activeSpeakers: [(label: String, centroid: [Float], embeddings: [[Float]])] = []
    private var nextSpeakerIndex = 0

    /// All embeddings seen this session — used to compute session mean for channel removal.
    private var allSessionEmbeddings: [[Float]] = []

    /// Session mean embedding (channel fingerprint) — subtracted from all comparisons.
    private var sessionMean: [Float] = []

    /// Match threshold AFTER channel compensation (much lower than raw cosine).
    /// Low threshold for system audio where all voices go through the same codec/channel.
    private let matchThreshold: Float = 0.20

    /// Minimum embeddings before we trust the session mean for compensation.
    private let minEmbeddingsForCompensation = 3

    /// EMA alpha for centroid updates (0.3 = new embedding gets 30% weight).
    private let centroidAlpha: Float = 0.3

    /// Match an embedding against active speakers, or create a new one.
    func identifySpeaker(embedding: [Float]) -> String {
        // Add to session pool and update session mean
        allSessionEmbeddings.append(embedding)
        updateSessionMean()

        // Channel-compensate the input embedding
        let compensated = compensate(embedding)

        var bestScore: Float = -1
        var bestIndex: Int?

        for (i, speaker) in activeSpeakers.enumerated() {
            let refCompensated = compensate(speaker.centroid)
            let score = cosineSim(compensated, refCompensated)
            if score > bestScore {
                bestScore = score
                bestIndex = i
            }
        }

        if let idx = bestIndex, bestScore >= matchThreshold {
            // Update centroid with EMA
            activeSpeakers[idx].centroid = ema(old: activeSpeakers[idx].centroid, new: embedding)
            if activeSpeakers[idx].embeddings.count < 10 {
                activeSpeakers[idx].embeddings.append(embedding)
            }
            onDebugLog?("Match: \(activeSpeakers[idx].label) (csim=\(String(format: "%.2f", bestScore)))")
            return activeSpeakers[idx].label
        }

        // New speaker — require minimum audio data to avoid false splits
        let label = Constants.speakerLabel(index: nextSpeakerIndex)
        nextSpeakerIndex += 1
        activeSpeakers.append((label: label, centroid: embedding, embeddings: [embedding]))
        onDebugLog?("New speaker: \(label) (csim=\(String(format: "%.2f", bestScore)))")
        return label
    }

    /// Load known speaker profiles for auto-identification.
    func loadKnownProfiles(_ profiles: [(name: String, embeddings: [[Float]])]) {
        for profile in profiles {
            let centroid = averageEmbedding(profile.embeddings) ?? profile.embeddings[0]
            activeSpeakers.append((label: profile.name, centroid: centroid, embeddings: profile.embeddings))
        }
        nextSpeakerIndex = activeSpeakers.count
        onDebugLog?("Loaded \(profiles.count) known speaker profiles")
    }

    // MARK: - Channel Compensation

    /// Subtract session mean (channel signature) and L2-normalize.
    private func compensate(_ embedding: [Float]) -> [Float] {
        guard !sessionMean.isEmpty, allSessionEmbeddings.count >= minEmbeddingsForCompensation else {
            return l2Normalize(embedding)
        }
        var result = [Float](repeating: 0, count: embedding.count)
        for i in 0..<embedding.count {
            result[i] = embedding[i] - sessionMean[i]
        }
        return l2Normalize(result)
    }

    /// Recompute session mean from all embeddings seen so far.
    private func updateSessionMean() {
        let count = allSessionEmbeddings.count
        guard count > 0 else { return }
        let dim = allSessionEmbeddings[0].count
        var mean = [Float](repeating: 0, count: dim)
        for emb in allSessionEmbeddings {
            for i in 0..<dim { mean[i] += emb[i] }
        }
        let fCount = Float(count)
        for i in 0..<dim { mean[i] /= fCount }
        sessionMean = mean
    }

    /// L2-normalize a vector to unit length.
    private func l2Normalize(_ v: [Float]) -> [Float] {
        var sumSq: Float = 0
        for x in v { sumSq += x * x }
        let norm = sqrtf(sumSq)
        guard norm > 1e-8 else { return v }
        return v.map { $0 / norm }
    }

    /// Exponential moving average of two embedding vectors.
    private func ema(old: [Float], new: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: old.count)
        for i in 0..<old.count {
            result[i] = centroidAlpha * new[i] + (1 - centroidAlpha) * old[i]
        }
        return result
    }

    /// Average multiple embeddings into a centroid.
    private func averageEmbedding(_ embeddings: [[Float]]) -> [Float]? {
        guard let first = embeddings.first else { return nil }
        let dim = first.count
        var sum = [Float](repeating: 0, count: dim)
        for emb in embeddings {
            for i in 0..<dim { sum[i] += emb[i] }
        }
        let fCount = Float(embeddings.count)
        return sum.map { $0 / fCount }
    }

    /// Cosine similarity between two vectors.
    private func cosineSim(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrtf(normA) * sqrtf(normB)
        return denom > 1e-8 ? dot / denom : 0
    }
}
