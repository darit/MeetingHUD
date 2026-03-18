import Foundation
import SpeechVAD

/// Stereo-aware speaker diarizer that leverages L/R channel differences
/// for better speaker separation on system audio.
///
/// Unlike PyannoteDiarizationPipeline (which relies on spectral segmentation
/// and struggles with mono system audio), this diarizer:
/// 1. Uses VAD to find speech segments
/// 2. Extracts WeSpeaker embeddings from L, R, and mono channels
/// 3. Combines them into stereo-aware embeddings
/// 4. Clusters with agglomerative clustering
actor StereoSpeakerDiarizer {

    private var weSpeaker: WeSpeakerModel?
    private var vadModel: PyannoteVADModel?

    /// Minimum segment duration (seconds) for embedding extraction.
    private let minSegmentDuration: Float = 1.5

    /// Window size for sliding-window embedding extraction (seconds).
    private let windowDuration: Float = 3.0

    /// Step size between windows (seconds).
    private let windowStep: Float = 1.5

    /// Cosine similarity threshold: below this = different speakers.
    private let splitThreshold: Float = 0.65

    // MARK: - Lifecycle

    func loadModels() async throws {
        if weSpeaker == nil {
            weSpeaker = try await WeSpeakerModel.fromPretrained(engine: .coreml)
        }
        if vadModel == nil {
            vadModel = try await PyannoteVADModel.fromPretrained()
        }
    }

    // MARK: - Diarization

    struct StereoSegment: Sendable {
        let startTime: Float
        let endTime: Float
        let speakerId: Int
    }

    struct StereoResult: Sendable {
        let segments: [StereoSegment]
        let numSpeakers: Int
    }

    /// Run stereo-aware diarization on interleaved stereo audio.
    ///
    /// - Parameters:
    ///   - stereoAudio: Interleaved L/R Float32 samples at 16kHz
    ///   - sampleRate: Sample rate (16000)
    /// - Returns: Diarization result with speaker-labeled segments
    func diarize(stereoAudio: [Float], sampleRate: Int) -> StereoResult {
        guard let weSpeaker, let vadModel else {
            return StereoResult(segments: [], numSpeakers: 0)
        }

        let frameCount = stereoAudio.count / 2

        // Deinterleave stereo to L/R/mono channels
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        var mono = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            left[i] = stereoAudio[i * 2]
            right[i] = stereoAudio[i * 2 + 1]
            mono[i] = (left[i] + right[i]) * 0.5
        }

        // Step 1: VAD on mono to find speech regions
        let speechSegments = vadModel.detectSpeech(audio: mono, sampleRate: sampleRate)
        guard !speechSegments.isEmpty else {
            return StereoResult(segments: [], numSpeakers: 0)
        }

        // Step 2: Sliding-window embedding extraction
        // Use mono embedding + L-R energy ratio as spatial feature (1 embedding per window, not 3)
        struct WindowEmbedding {
            let startTime: Float
            let endTime: Float
            let monoEmb: [Float]
            /// L-R energy ratio: >0.5 = louder on left, <0.5 = louder on right
            let stereoBalance: Float

            /// Combined embedding: mono + stereo balance repeated as spatial features
            var combined: [Float] {
                var c = monoEmb
                // Append stereo balance as a spatial feature (scaled and repeated for weight)
                let balanceFeature = (stereoBalance - 0.5) * 4.0 // center=0, range [-2, 2]
                for _ in 0..<16 { c.append(balanceFeature) }
                return c
            }
        }

        var windows: [WindowEmbedding] = []
        let windowSamples = Int(windowDuration * Float(sampleRate))
        let stepSamples = Int(windowStep * Float(sampleRate))

        var pos = 0
        while pos + windowSamples <= frameCount {
            let windowStart = Float(pos) / Float(sampleRate)
            let windowEnd = Float(pos + windowSamples) / Float(sampleRate)

            let hasSpeech = speechSegments.contains { seg in
                seg.startTime < windowEnd && seg.endTime > windowStart
            }

            if hasSpeech {
                let monoSlice = Array(mono[pos..<(pos + windowSamples)])
                let monoEmb = weSpeaker.embed(audio: monoSlice, sampleRate: sampleRate)

                // Compute L-R energy balance (cheap, no model needed)
                var leftEnergy: Float = 0, rightEnergy: Float = 0
                for i in pos..<(pos + windowSamples) {
                    leftEnergy += left[i] * left[i]
                    rightEnergy += right[i] * right[i]
                }
                let totalEnergy = leftEnergy + rightEnergy
                let balance = totalEnergy > 0 ? leftEnergy / totalEnergy : 0.5

                windows.append(WindowEmbedding(
                    startTime: windowStart,
                    endTime: windowEnd,
                    monoEmb: monoEmb,
                    stereoBalance: balance
                ))
            }

            pos += stepSamples
        }

        guard !windows.isEmpty else {
            return StereoResult(segments: [], numSpeakers: 0)
        }

        // Step 3: Agglomerative clustering on combined embeddings
        let labels = cluster(windows.map(\.combined), threshold: splitThreshold)

        // Step 4: Build output segments, merging adjacent same-speaker windows
        var rawSegments: [StereoSegment] = []
        for (i, window) in windows.enumerated() {
            rawSegments.append(StereoSegment(
                startTime: window.startTime,
                endTime: window.endTime,
                speakerId: labels[i]
            ))
        }

        // Merge adjacent segments with same speaker
        let merged = mergeSegments(rawSegments)
        let numSpeakers = Set(merged.map(\.speakerId)).count

        return StereoResult(segments: merged, numSpeakers: numSpeakers)
    }

    // MARK: - Clustering

    /// Agglomerative clustering: each window starts as its own cluster,
    /// iteratively merge most similar pair until below threshold.
    private func cluster(_ embeddings: [[Float]], threshold: Float) -> [Int] {
        let n = embeddings.count
        guard n > 0 else { return [] }

        // Start: each point is its own cluster
        var labels = Array(0..<n)
        var centroids = embeddings
        var active = Set(0..<n)

        while active.count > 1 {
            var bestSim: Float = -1
            var bestI = -1, bestJ = -1

            let sorted = active.sorted()
            for ai in 0..<sorted.count {
                for aj in (ai + 1)..<sorted.count {
                    let sim = cosineSimilarity(centroids[sorted[ai]], centroids[sorted[aj]])
                    if sim > bestSim {
                        bestSim = sim
                        bestI = sorted[ai]
                        bestJ = sorted[aj]
                    }
                }
            }

            guard bestSim >= threshold else { break }

            // Merge bestJ into bestI
            for d in 0..<centroids[bestI].count {
                centroids[bestI][d] = (centroids[bestI][d] + centroids[bestJ][d]) / 2.0
            }
            for i in 0..<n {
                if labels[i] == bestJ { labels[i] = bestI }
            }
            active.remove(bestJ)
        }

        // Compact labels to 0, 1, 2...
        let unique = Array(Set(labels)).sorted()
        let remap = Dictionary(uniqueKeysWithValues: unique.enumerated().map { ($1, $0) })
        return labels.map { remap[$0]! }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrtf(normA) * sqrtf(normB)
        return denom > 0 ? dot / denom : 0
    }

    /// Merge adjacent segments with the same speaker ID.
    private func mergeSegments(_ segments: [StereoSegment]) -> [StereoSegment] {
        guard !segments.isEmpty else { return [] }
        var merged: [StereoSegment] = [segments[0]]
        for seg in segments.dropFirst() {
            if seg.speakerId == merged.last!.speakerId {
                let last = merged.removeLast()
                merged.append(StereoSegment(
                    startTime: last.startTime,
                    endTime: seg.endTime,
                    speakerId: seg.speakerId
                ))
            } else {
                merged.append(seg)
            }
        }
        return merged
    }
}
